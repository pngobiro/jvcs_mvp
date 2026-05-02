/**
 * WebRTC Hook for Server-Side SFU
 * 
 * This hook handles:
 * - Local media capture (camera/microphone)
 * - Single WebRTC connection to the server
 * - Server-initiated renegotiation (when server adds forwarded tracks)
 * - Displaying remote video streams from other peers
 * - UI controls (mute, video toggle)
 * 
 * Flow:
 * 1. Client captures local media
 * 2. Client sends offer to server (with sendrecv transceivers)
 * 3. Server responds with answer
 * 4. Connection establishes (client sends media to server)
 * 5. When another peer joins, server adds their tracks and sends NEW offer
 * 6. Client answers the renegotiation offer
 * 7. Remote tracks arrive via ontrack event
 */

const WebRTCSimple = {
  mounted() {
    this.peerId = this.el.dataset.peerId;
    this.displayName = this.el.dataset.displayName || "You";
    this.peerConnection = null;
    this.localStream = null;
    this.pendingCandidates = [];
    this.remoteStreams = new Map(); // streamId -> { stream, videoEl }
    this.peerNames = new Map(); // peerId -> displayName
    
    // Store own name
    this.peerNames.set(this.peerId, this.displayName);
    
    // Perfect Negotiation state
    this.makingOffer = false;
    this.ignoreOffer = false;
    this.isSettingRemoteAnswerPending = false;

    this.configuration = {
      iceServers: [
        { urls: "stun:stun.l.google.com:19302" },
        { urls: "stun:stun1.l.google.com:19302" }
      ],
      iceCandidatePoolSize: 10
    };

    console.log("[WebRTC-SFU] Mounted, PeerID:", this.peerId, "Name:", this.displayName);
    console.log("[WebRTC-SFU] Origin:", window.location.origin);
    console.log("[WebRTC-SFU] Secure Context:", window.isSecureContext);

    // Step 1: Get local media
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      console.error("[WebRTC-SFU] getUserMedia not supported (likely insecure context)");
      this.showError("Video/Audio not supported on this connection. Please use HTTPS or localhost.");
      return;
    }

    navigator.mediaDevices.getUserMedia({ video: true, audio: true })
      .then(stream => {
        console.log("[WebRTC-SFU] Local media captured");
        this.localStream = stream;
        
        // Display local video
        const localVideo = document.getElementById("local-video");
        if (localVideo) {
          localVideo.srcObject = stream;
        }

        // Step 2: Create peer connection and send initial offer
        this.createPeerConnection();

        // Step 3: Join the call (notifies server)
        this.pushEvent("join_call", { peer_id: this.peerId });
      })
      .catch(error => {
        console.error("[WebRTC-SFU] Media error:", error);
        this.showError("Failed to access camera/microphone: " + error.message);
      });

    // Handle signals from the server
    this.handleEvent("webrtc_signal_to_client", async ({ peer_id, signal_type, payload }) => {
      if (peer_id !== this.peerId) return;

      console.log(`[WebRTC-SFU] Received ${signal_type} from server`);

      try {
        if (signal_type === "offer") {
          await this.handleServerOffer(payload);
        } else if (signal_type === "answer") {
          await this.handleServerAnswer(payload);
        } else if (signal_type === "ice") {
          await this.handleIceCandidate(payload);
        } else if (signal_type === "reconnect") {
          console.log("[WebRTC-SFU] Server requested forced reconnect");
          this.reconnect();
        }
      } catch (err) {
        console.error(`[WebRTC-SFU] Error handling ${signal_type}:`, err);
      }
    });

    // Handle initial peer names
    this.handleEvent("initial_peer_names", ({ names }) => {
      console.log("[WebRTC-SFU] Received initial peer names:", names);
      Object.entries(names).forEach(([pId, name]) => {
        this.peerNames.set(pId, name);
      });
      this.updateRemoteVideoLabels();
    });

    // Handle peer joined (for UI notification)
    this.handleEvent("peer_joined", ({ peer_id, display_name }) => {
      console.log(`[WebRTC-SFU] Peer joined: ${display_name} (${peer_id})`);
      this.peerNames.set(peer_id, display_name);
      this.updateRemoteVideoLabels();
      this.showNotification(`${display_name} joined the session`);
    });

    // Handle peer left (cleanup remote video)
    this.handleEvent("peer_left", ({ peer_id }) => {
      console.log(`[WebRTC-SFU] Peer left: ${peer_id}`);
      this.removeRemoteVideo(peer_id);
    });

    // Handle reconnect request from server (after admission or recovery)
    this.handleEvent("reconnect_webrtc", ({ peer_id }) => {
      console.log(`[WebRTC-SFU] Server requested reconnect for ${peer_id}`);
      if (peer_id === this.peerId) {
        // Tear down old connection and create fresh one
        this.reconnect();
      }
    });

    // Handle recording status updates
    this.handleEvent("recording_status_updated", ({ status }) => {
      console.log(`[WebRTC-SFU] Recording status updated: ${status}`);
      if (status === "recording") {
        this.showNotification("Session recording started", "info");
        this.startRecording();
      } else {
        this.showNotification("Session recording stopped", "success");
        this.stopRecording();
      }
    });

    // Persistent state for local media
    this.audioEnabled = true;
    this.videoEnabled = true;
    
    // Recording state
    this.mediaRecorder = null;
    this.recordedChunks = [];

    this.setupControls();
    
    // Heartbeat to keep server-side peer alive
    this.heartbeatInterval = setInterval(() => {
      this.pushEvent("heartbeat", { peer_id: this.peerId });
    }, 15000);
  },

  createPeerConnection() {
    console.log("[WebRTC-SFU] Creating RTCPeerConnection");

    const pc = new RTCPeerConnection(this.configuration);
    this.peerConnection = pc;

    // Add local tracks to the connection
    if (this.localStream) {
      this.localStream.getTracks().forEach(track => {
        // Apply persistent state
        if (track.kind === "audio") track.enabled = this.audioEnabled;
        if (track.kind === "video") track.enabled = this.videoEnabled;
        
        pc.addTrack(track, this.localStream);
        console.log(`[WebRTC-SFU] Added local ${track.kind} track (enabled: ${track.enabled})`);
      });
    }

    // Handle ICE candidates — send to server
    pc.onicecandidate = (event) => {
      if (event.candidate) {
        console.log("[WebRTC-SFU] Sending ICE candidate to server");
        this.pushEvent("webrtc_signaling", {
          to: this.peerId,
          payload: event.candidate
        });
      } else {
        console.log("[WebRTC-SFU] ICE gathering complete");
      }
    };

    // Handle connection state changes
    pc.onconnectionstatechange = () => {
      console.log(`[WebRTC-SFU] Connection state: ${pc.connectionState}`);
      this.updateConnectionIndicator(pc.connectionState);

      if (pc.connectionState === "connected") {
        this.showSuccess("Connected to court server");
      } else if (pc.connectionState === "failed") {
        this.showError("Connection to server failed");
        // Attempt reconnection after a delay
        setTimeout(() => this.attemptReconnection(), 3000);
      } else if (pc.connectionState === "disconnected") {
        this.showError("Connection lost, attempting to reconnect...");
      }
    };

    // Handle ICE connection state
    pc.oniceconnectionstatechange = () => {
      console.log(`[WebRTC-SFU] ICE connection state: ${pc.iceConnectionState}`);
    };

    // Handle signaling state (important for renegotiation)
    pc.onsignalingstatechange = () => {
      console.log(`[WebRTC-SFU] Signaling state: ${pc.signalingState}`);
      this.isNegotiating = (pc.signalingState !== "stable");
    };

    // Handle remote tracks — THIS IS WHERE OTHER PEERS' VIDEO APPEARS
    pc.ontrack = (event) => {
      console.log(`[WebRTC-SFU] Received remote ${event.track.kind} track from server. Streams:`, event.streams.length);
      
      if (event.streams && event.streams.length > 0) {
        event.streams.forEach(stream => {
          console.log(`[WebRTC-SFU] Stream details: ID=${stream.id}, Tracks=${stream.getTracks().length}`);
          this.addRemoteVideo(stream);
        });

        // Monitor the tracks
        event.track.onended = () => console.log(`[WebRTC-SFU] Remote ${event.track.kind} track ended (${event.track.id})`);
        event.track.onmute = () => console.log(`[WebRTC-SFU] Remote ${event.track.kind} track muted (${event.track.id})`);
        event.track.onunmute = () => console.log(`[WebRTC-SFU] Remote ${event.track.kind} track unmuted (${event.track.id})`);
      } else {
        console.log(`[WebRTC-SFU] No stream associated with track ${event.track.id}, creating virtual stream`);
        const stream = new MediaStream([event.track]);
        // Note: this virtual stream will have a random ID, which might break our peer mapping
        this.addRemoteVideo(stream);
      }
    };

    // Create and send initial offer to server
    this.createAndSendOffer();
  },

  async createAndSendOffer() {
    const pc = this.peerConnection;
    if (!pc || pc.signalingState === "closed") return;

    try {
      this.makingOffer = true;
      console.log(`[WebRTC-SFU] Creating offer (signaling state: ${pc.signalingState})`);
      const offer = await pc.createOffer();
      
      if (pc.signalingState !== "stable") return;
      
      await pc.setLocalDescription(offer);

      console.log("[WebRTC-SFU] Sending offer to server");
      this.pushEvent("webrtc_signaling", {
        to: this.peerId,
        payload: pc.localDescription
      });
    } catch (err) {
      console.error("[WebRTC-SFU] Failed to create offer:", err);
    } finally {
      this.makingOffer = false;
    }
  },

  /**
   * Handle an offer from the SERVER (renegotiation).
   * This happens when the server adds tracks from other peers
   * and needs to update the SDP.
   */
  async handleServerOffer(offer) {
    const pc = this.peerConnection;
    if (!pc) return;

    console.log(`[WebRTC-SFU] Processing server offer (current signaling: ${pc.signalingState})`);

    try {
      const isStable = pc.signalingState === "stable";
      const isGlare = !isStable || this.makingOffer;
      
      // Server is the "impolite" peer, client is the "polite" peer.
      // In glare, the polite peer (client) rolls back.
      this.ignoreOffer = isGlare && pc.signalingState !== "stable"; // Simple heuristic for glare

      if (this.ignoreOffer) {
        console.log("[WebRTC-SFU] Glare detected, rolling back local state to accept server offer");
        await pc.setLocalDescription({type: "rollback"});
      }

      // Set remote description (the server's offer)
      await pc.setRemoteDescription(new RTCSessionDescription(offer));

      // Create and send answer
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      console.log("[WebRTC-SFU] Sending answer to server (renegotiation)");
      this.pushEvent("webrtc_signaling", {
        to: this.peerId,
        payload: pc.localDescription
      });

      // Process any queued ICE candidates
      this.processPendingCandidates();
    } catch (err) {
      console.error("[WebRTC-SFU] Error handling server offer:", err);
    }
  },

  /**
   * Handle an answer from the SERVER (response to our initial offer).
   */
  async handleServerAnswer(answer) {
    const pc = this.peerConnection;
    if (!pc) return;

    console.log("[WebRTC-SFU] Applying server answer");

    try {
      this.isSettingRemoteAnswerPending = true;
      await pc.setRemoteDescription(new RTCSessionDescription(answer));
      this.processPendingCandidates();
    } catch (err) {
      console.error("[WebRTC-SFU] Error applying server answer:", err);
    } finally {
      this.isSettingRemoteAnswerPending = false;
    }
  },

  async handleIceCandidate(candidate) {
    const pc = this.peerConnection;
    if (!pc) {
      console.log("[WebRTC-SFU] Queuing ICE candidate (no peer connection)");
      this.pendingCandidates.push(candidate);
      return;
    }

    const canAddCandidate = pc.remoteDescription && pc.remoteDescription.type && !this.isSettingRemoteAnswerPending;

    if (canAddCandidate) {
      try {
        await pc.addIceCandidate(new RTCIceCandidate(candidate));
      } catch (err) {
        console.warn("[WebRTC-SFU] Error adding ICE candidate:", err);
      }
    } else {
      console.log("[WebRTC-SFU] Queuing ICE candidate (not ready)");
      this.pendingCandidates.push(candidate);
    }
  },

  async processPendingCandidates() {
    if (this.pendingCandidates.length === 0) return;

    const pc = this.peerConnection;
    if (!pc || !pc.remoteDescription) return;

    console.log(`[WebRTC-SFU] Processing ${this.pendingCandidates.length} pending ICE candidates`);

    for (const candidate of this.pendingCandidates) {
      try {
        await pc.addIceCandidate(new RTCIceCandidate(candidate));
      } catch (err) {
        console.warn("[WebRTC-SFU] Error adding pending candidate:", err);
      }
    }

    this.pendingCandidates = [];
  },

  addRemoteVideo(stream) {
    const grid = document.getElementById("video-grid");
    if (!grid) {
      console.error("[WebRTC-SFU] Video grid not found");
      return;
    }

    const streamId = stream.id;

    // Check if we already have a video element for this stream
    if (this.remoteStreams.has(streamId)) {
      const existing = this.remoteStreams.get(streamId);
      if (existing.videoEl) {
        console.log(`[WebRTC-SFU] Updating existing video for stream ${streamId}`);
        existing.videoEl.srcObject = stream;
        return;
      }
    }

    console.log(`[WebRTC-SFU] Creating new video element for stream ${streamId}`);

    const wrapper = document.createElement("div");
    wrapper.id = `wrapper-${streamId}`;
    wrapper.className = "relative group bg-zinc-900 rounded-2xl overflow-hidden border-2 border-zinc-800 shadow-2xl aspect-video";

    const videoEl = document.createElement("video");
    videoEl.id = `video-${streamId}`;
    videoEl.className = "w-full h-full object-cover";
    videoEl.autoplay = true;
    videoEl.playsInline = true;
    videoEl.srcObject = stream;

    // Force play (needed for some browsers)
    videoEl.onloadedmetadata = () => {
      videoEl.play().catch(e => console.warn("[WebRTC-SFU] Error auto-playing remote video:", e));
    };

    // Extract peerId from stream ID (format is stream_peerId)
    let displayName = "Participant";
    if (streamId.startsWith("stream_")) {
      const pId = streamId.replace("stream_", "");
      displayName = this.peerNames.get(pId) || "Participant";
      console.log(`[WebRTC-SFU] Resolved name for ${streamId}: ${displayName}`);
    }

    const label = document.createElement("div");
    label.className = "absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/80 to-transparent p-4 text-center";
    label.innerHTML = `<p class="text-sm font-bold tracking-tight">${displayName}</p>`;

    wrapper.appendChild(videoEl);
    wrapper.appendChild(label);
    grid.appendChild(wrapper);

    this.remoteStreams.set(streamId, { stream, videoEl });

    // Monitor stream for track removal
    stream.onremovetrack = (event) => {
      console.log(`[WebRTC-SFU] Track removed from stream ${streamId}`);
      if (stream.getTracks().length === 0) {
        this.removeRemoteVideoByStream(streamId);
      }
    };

    console.log(`[WebRTC-SFU] Remote video added. Total remote streams: ${this.remoteStreams.size}`);
  },

  removeRemoteVideo(peerId) {
    // Remove by peer ID — check for stream wrapper
    const streamId = `stream_${peerId}`;
    this.removeRemoteVideoByStream(streamId);
  },

  removeRemoteVideoByStream(streamId) {
    const wrapper = document.getElementById(`wrapper-${streamId}`);
    if (wrapper) {
      wrapper.remove();
    }
    this.remoteStreams.delete(streamId);
    console.log(`[WebRTC-SFU] Removed video for stream ${streamId}`);
  },

  updateRemoteVideoLabels() {
    this.remoteStreams.forEach((info, streamId) => {
      if (streamId.startsWith("stream_")) {
        const pId = streamId.replace("stream_", "");
        const displayName = this.peerNames.get(pId);
        if (displayName) {
          const wrapper = document.getElementById(`wrapper-${streamId}`);
          if (wrapper) {
            const labelP = wrapper.querySelector("p");
            if (labelP && labelP.textContent !== displayName) {
              console.log(`[WebRTC-SFU] Updating label for ${streamId} to ${displayName}`);
              labelP.textContent = displayName;
            }
          }
        }
      }
    });
  },

  reconnect() {
    console.log("[WebRTC-SFU] Reconnecting (server requested)...");
    // Small delay to let the DOM settle after admission status change
    setTimeout(() => this.attemptReconnection(), 500);
  },

  attemptReconnection() {
    console.log("[WebRTC-SFU] Attempting reconnection...");
    
    // Clean up old connection
    if (this.peerConnection) {
      this.peerConnection.close();
      this.peerConnection = null;
    }

    // Clear remote videos
    this.remoteStreams.forEach((info, streamId) => {
      this.removeRemoteVideoByStream(streamId);
    });
    this.remoteStreams.clear();
    this.pendingCandidates = [];

    // Re-create connection with existing local stream
    if (this.localStream) {
      this.createPeerConnection();
      this.pushEvent("join_call", { peer_id: this.peerId });
    }
  },

  toggleAudio() {
    if (this.localStream) {
      const track = this.localStream.getAudioTracks()[0];
      if (track) {
        this.audioEnabled = !this.audioEnabled;
        track.enabled = this.audioEnabled;
        this.updateControlUI();
        console.log(`[WebRTC-SFU] Audio ${this.audioEnabled ? "enabled" : "disabled"}`);
      }
    }
  },

  toggleVideo() {
    if (this.localStream) {
      const track = this.localStream.getVideoTracks()[0];
      if (track) {
        this.videoEnabled = !this.videoEnabled;
        track.enabled = this.videoEnabled;
        this.updateControlUI();
        console.log(`[WebRTC-SFU] Video ${this.videoEnabled ? "enabled" : "disabled"}`);
      }
    }
  },

  updateControlUI() {
    const audioBtn = document.getElementById("toggle-audio");
    if (audioBtn) {
      const svg = audioBtn.querySelector("svg");
      if (svg) svg.style.opacity = this.audioEnabled ? "1" : "0.3";
      if (!this.audioEnabled) audioBtn.classList.add("ring-2", "ring-red-500");
      else audioBtn.classList.remove("ring-2", "ring-red-500");
    }

    const videoBtn = document.getElementById("toggle-video");
    if (videoBtn) {
      const svg = videoBtn.querySelector("svg");
      if (svg) svg.style.opacity = this.videoEnabled ? "1" : "0.3";
      if (!this.videoEnabled) videoBtn.classList.add("ring-2", "ring-red-500");
      else videoBtn.classList.remove("ring-2", "ring-red-500");
    }
  },

  setupControls() {
    // Use event delegation on the hook element to handle clicks on controls
    // even after DOM updates/re-renders
    this.el.addEventListener("click", (e) => {
      const audioBtn = e.target.closest("#toggle-audio");
      if (audioBtn) {
        this.toggleAudio();
        return;
      }

      const videoBtn = e.target.closest("#toggle-video");
      if (videoBtn) {
        this.toggleVideo();
        return;
      }
    });
  },

  startRecording() {
    if (!this.localStream) return;
    
    this.recordedChunks = [];
    try {
      const options = { mimeType: "video/webm; codecs=vp8,opus" };
      if (!MediaRecorder.isTypeSupported(options.mimeType)) {
        console.warn(`${options.mimeType} not supported, using default`);
        this.mediaRecorder = new MediaRecorder(this.localStream);
      } else {
        this.mediaRecorder = new MediaRecorder(this.localStream, options);
      }

      this.mediaRecorder.ondataavailable = (e) => {
        if (e.data.size > 0) this.recordedChunks.push(e.data);
      };

      this.mediaRecorder.onstop = () => {
        this.saveRecording();
      };

      this.mediaRecorder.start();
      console.log("[WebRTC-SFU] MediaRecorder started");
    } catch (err) {
      console.error("[WebRTC-SFU] Failed to start recording:", err);
    }
  },

  stopRecording() {
    if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") {
      this.mediaRecorder.stop();
      console.log("[WebRTC-SFU] MediaRecorder stopped");
    }
  },

  saveRecording() {
    if (this.recordedChunks.length === 0) return;

    const blob = new Blob(this.recordedChunks, { type: "video/webm" });
    const dateStr = new Date().toISOString().replace(/[:.]/g, "-");
    const filename = `recording-${this.peerId}-${dateStr}.webm`;
    
    // 1. Download locally for backup
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.style.display = "none";
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => {
      document.body.removeChild(a);
      window.URL.revokeObjectURL(url);
    }, 100);

    // 2. Upload to Cloudflare R2 via server
    this.uploadRecording(blob, filename);
  },

  async uploadRecording(blob, filename) {
    this.showNotification("Uploading recording to secure vault...", "info");
    
    const activityId = this.el.dataset.activityId;
    const formData = new FormData();
    formData.append("file", blob);
    formData.append("filename", filename);
    if (activityId) {
      formData.append("activity_id", activityId);
    }

    const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

    try {
      const response = await fetch("/api/media/upload", {
        method: "POST",
        body: formData,
        headers: {
          "x-csrf-token": csrfToken
        }
      });

      const result = await response.json();
      if (result.status === "ok") {
        this.showSuccess("Recording safely archived in secure vault");
        console.log("[WebRTC-SFU] Recording uploaded to R2:", result.url);
      } else {
        throw new Error(result.message || "Upload failed");
      }
    } catch (err) {
      console.error("[WebRTC-SFU] Upload failed:", err);
      this.showError("Failed to archive recording: " + err.message);
    }
  },

  updateConnectionIndicator(state) {
    const indicator = document.getElementById("connection-status");
    if (!indicator) return;

    const dot = indicator.querySelector("span");
    if (!dot) return;

    switch (state) {
      case "connected":
        dot.className = "w-2 h-2 rounded-full bg-green-500 animate-pulse";
        break;
      case "connecting":
        dot.className = "w-2 h-2 rounded-full bg-yellow-500 animate-pulse";
        break;
      case "disconnected":
      case "failed":
        dot.className = "w-2 h-2 rounded-full bg-red-500 animate-pulse";
        break;
      default:
        dot.className = "w-2 h-2 rounded-full bg-zinc-500";
    }
  },

  updated() {
    // Re-sync UI state (e.g. mute indicators) after DOM update
    this.updateControlUI();

    // Re-attach local stream if DOM changed (e.g., lobby → room transition)
    if (this.localStream) {
      const localVideo = document.getElementById("local-video");
      if (localVideo && localVideo.srcObject !== this.localStream) {
        console.log("[WebRTC-SFU] Re-attaching local stream after DOM update");
        localVideo.srcObject = this.localStream;
      }
    }

    // Re-attach remote streams if grid appeared and they are missing
    const grid = document.getElementById("video-grid");
    if (grid) {
      this.remoteStreams.forEach((info, streamId) => {
        if (!document.getElementById(`wrapper-${streamId}`)) {
          console.log(`[WebRTC-SFU] Re-adding remote video for stream ${streamId} after DOM update`);
          this.addRemoteVideo(info.stream);
        }
      });
    }
  },

  destroyed() {
    console.log("[WebRTC-SFU] Cleaning up");

    if (this.heartbeatInterval) {
      clearInterval(this.heartbeatInterval);
    }

    if (this.localStream) {
      this.localStream.getTracks().forEach(track => track.stop());
    }

    if (this.peerConnection) {
      this.peerConnection.close();
    }

    this.remoteStreams.clear();
  },

  showError(msg) {
    console.error(`[WebRTC-SFU] ${msg}`);
  },

  showSuccess(msg) {
    console.log(`[WebRTC-SFU] ✓ ${msg}`);
  },

  showNotification(msg) {
    console.log(`[WebRTC-SFU] ${msg}`);
  }
};

export default WebRTCSimple;
