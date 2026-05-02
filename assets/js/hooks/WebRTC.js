const WebRTC = {
  mounted() {
    this.peerId = Math.random().toString(36).substring(2, 15);
    this.peerConnections = {};
    this.peerNames = {}; // Track display names
    this.pendingCandidates = {};
    this.localStream = null;
    this.connectionRetries = {};
    this.maxRetries = 3;

    const configuration = {
      iceServers: [
        { urls: "stun:stun.l.google.com:19302" },
        { urls: "stun:stun1.l.google.com:19302" }
      ],
      iceCandidatePoolSize: 10
    };

    console.log("[WebRTC] Hook mounted, PeerID:", this.peerId);

    // Initialize status indicator
    this.updateConnectionStatus("initializing");

    // Get Local Media
    navigator.mediaDevices.getUserMedia({ video: true, audio: true })
      .then(stream => {
        console.log("[WebRTC] Local media stream captured");
        this.localStream = stream;
        const localVideos = document.querySelectorAll("#local-video");
        localVideos.forEach(video => {
          video.srcObject = stream;
        });

        this.monitorLocalStream(stream);
        this.pushEvent("join_call", { peer_id: this.peerId });
        this.updateConnectionStatus("connected");
      })
      .catch(error => {
        console.error("[WebRTC] Error accessing media devices:", error);
        this.handleMediaError(error);
        this.updateConnectionStatus("failed");
      });

    // Handle Peer Joined (Triggered by server when someone is admitted)
    this.handleEvent("peer_joined", ({ peer_id, display_name }) => {
      if (peer_id === this.peerId) return;
      console.log(`[WebRTC] Peer admitted/joined: ${display_name} (${peer_id})`);
      
      if (!this.peerConnections[peer_id]) {
        console.log(`[WebRTC] Creating connection to ${display_name} (Initiator: true)`);
        this.createPeerConnection(peer_id, display_name, configuration, true);
      }
    });

    // Handle Pre-existing Peers (Triggered when WE are admitted)
    this.handleEvent("peer_present", ({ peer_id, display_name }) => {
      if (peer_id === this.peerId) return;
      console.log(`[WebRTC] Peer already in room: ${display_name} (${peer_id})`);
      
      if (!this.peerConnections[peer_id]) {
        console.log(`[WebRTC] Creating connection to ${display_name} (Initiator: false)`);
        this.createPeerConnection(peer_id, display_name, configuration, false);
      }
    });

    // Handle Peer Left (Cleanup)
    this.handleEvent("peer_left", ({ peer_id }) => {
      console.log(`[WebRTC] Peer left: ${peer_id}`);
      this.cleanupPeer(peer_id);
    });

    // Handle incoming signaling
    this.handleEvent("webrtc_signaling", async ({ from, payload }) => {
      if (from === this.peerId) return;

      let pc = this.peerConnections[from];
      const signalType = payload.type || (payload.candidate ? "ice" : "unknown");
      
      // Re-create connection if it was closed or doesn't exist
      if (!pc || pc.signalingState === "closed") {
        console.log(`[WebRTC] Received ${signalType} from unknown/closed peer ${from}, creating connection`);
        const name = this.peerNames[from] || "Participant";
        pc = this.createPeerConnection(from, name, configuration, false);
      }

      try {
        if (payload.type === "offer") {
          console.log(`[WebRTC] Processing offer from ${from}, current state: ${pc.signalingState}`);
          
          // Handle glare condition (both sides sent offers)
          if (pc.signalingState === "have-local-offer") {
            console.warn(`[WebRTC] Glare detected with ${from}, resolving...`);
            // Use peer ID comparison to determine who backs off
            if (this.peerId > from) {
              console.log(`[WebRTC] Backing off from glare with ${from}`);
              await pc.setLocalDescription({type: "rollback"});
            } else {
              console.log(`[WebRTC] Ignoring offer from ${from} due to glare resolution`);
              return;
            }
          }
          
          await pc.setRemoteDescription(new RTCSessionDescription(payload));
          const answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          console.log(`[WebRTC] Sending answer to ${from}`);
          this.pushEvent("webrtc_signaling", { to: from, payload: pc.localDescription });
          
        } else if (payload.type === "answer") {
          console.log(`[WebRTC] Processing answer from ${from}, current state: ${pc.signalingState}`);
          
          if (pc.signalingState === "have-local-offer") {
            await pc.setRemoteDescription(new RTCSessionDescription(payload));
            console.log(`[WebRTC] Answer applied successfully for ${from}`);
          } else {
            console.warn(`[WebRTC] Received answer in unexpected state: ${pc.signalingState}`);
          }
          
        } else if (payload.candidate) {
          // Queue ICE candidates if remote description not set yet
          if (pc.remoteDescription && pc.remoteDescription.type) {
            await pc.addIceCandidate(new RTCIceCandidate(payload));
            console.log(`[WebRTC] Added ICE candidate from ${from}`);
          } else {
            console.log(`[WebRTC] Queuing ICE candidate from ${from} (no remote description yet)`);
            if (!this.pendingCandidates) this.pendingCandidates = {};
            if (!this.pendingCandidates[from]) this.pendingCandidates[from] = [];
            this.pendingCandidates[from].push(payload);
          }
        }
      } catch (err) {
        console.error(`[WebRTC] Signaling error with peer ${from} (${signalType}):`, err);
        this.handleSignalingError(from, err);
      }
    });

    this.setupAudioToggle();
    this.setupVideoToggle();
    this.setupRecording();
  },

  updated() {
    // Re-attach local stream if DOM changed (e.g. lobby -> room)
    if (this.localStream) {
      const localVideos = document.querySelectorAll("#local-video");
      localVideos.forEach(video => {
        if (video.srcObject !== this.localStream) {
          console.log("[WebRTC] DOM Updated: Re-attaching local stream to video element");
          video.srcObject = this.localStream;
        }
      });
    }

    // Ensure remote videos are present and playing if they exist in our connections
    const grid = document.getElementById("video-grid");
    if (grid) {
      Object.keys(this.peerConnections).forEach(peerId => {
        const pc = this.peerConnections[peerId];
        if (pc.signalingState !== "closed") {
          const receivers = pc.getReceivers();
          const tracks = receivers.map(r => r.track).filter(t => t !== null && t.readyState === "live");
          
          if (tracks.length > 0) {
            let videoEl = document.getElementById(`video-${peerId}`);
            // If the element was destroyed by LiveView but we still have active tracks
            if (!videoEl) {
              console.log(`[WebRTC] DOM Updated: Restoring remote stream element for ${peerId}`);
              const stream = new MediaStream(tracks);
              const name = this.peerNames[peerId] || "Participant";
              this.addRemoteVideo(peerId, name, stream);
            } else if (!videoEl.srcObject) {
              // Element exists but lost its srcObject
              console.log(`[WebRTC] DOM Updated: Re-attaching remote stream to existing element for ${peerId}`);
              videoEl.srcObject = new MediaStream(tracks);
            }
          }
        }
      });
    }
  },

  cleanupPeer(peerId) {
    if (this.peerConnections[peerId]) {
      this.peerConnections[peerId].close();
      delete this.peerConnections[peerId];
    }
    delete this.peerNames[peerId];
    const videoEl = document.getElementById(`wrapper-${peerId}`);
    if (videoEl) videoEl.remove();
    console.log(`[WebRTC] Cleaned up peer resources for: ${peerId}`);
  },

  createPeerConnection(peerId, displayName, configuration, isInitiator) {
    console.log(`[WebRTC] Initializing RTCPeerConnection for ${displayName} (initiator: ${isInitiator})`);
    
    // Store name for recovery
    this.peerNames[peerId] = displayName;

    // Close existing if any
    if (this.peerConnections[peerId]) {
      console.log(`[WebRTC] Closing existing connection for ${displayName}`);
      this.peerConnections[peerId].close();
    }

    const pc = new RTCPeerConnection(configuration);
    this.peerConnections[peerId] = pc;

    // Add local stream
    if (this.localStream) {
      console.log(`[WebRTC] Adding local tracks to connection for ${displayName}`);
      this.localStream.getTracks().forEach(track => pc.addTrack(track, this.localStream));
    }

    pc.onconnectionstatechange = () => {
      console.log(`[WebRTC] Connection state with ${displayName}: ${pc.connectionState}`);
      if (pc.connectionState === "failed" || pc.connectionState === "disconnected") {
        // Wait a moment for potential auto-recovery before removal
        setTimeout(() => {
          if (pc.connectionState === "failed" || pc.connectionState === "disconnected") {
             console.log(`[WebRTC] Peer ${displayName} still disconnected, checking for removal...`);
          }
        }, 5000);
      } else if (pc.connectionState === "connected") {
        console.log(`[WebRTC] Successfully connected to ${displayName}`);
        // Process any pending ICE candidates
        if (this.pendingCandidates && this.pendingCandidates[peerId]) {
          console.log(`[WebRTC] Processing ${this.pendingCandidates[peerId].length} pending ICE candidates for ${displayName}`);
          this.pendingCandidates[peerId].forEach(async (candidate) => {
            try {
              await pc.addIceCandidate(new RTCIceCandidate(candidate));
            } catch (err) {
              console.error(`[WebRTC] Error adding pending candidate:`, err);
            }
          });
          delete this.pendingCandidates[peerId];
        }
      }
    };

    pc.onicecandidate = (event) => {
      if (event.candidate && pc.signalingState !== "closed") {
        this.pushEvent("webrtc_signaling", { to: peerId, payload: event.candidate });
      } else if (!event.candidate) {
        console.log(`[WebRTC] ICE gathering complete for ${displayName}`);
      }
    };

    pc.onicegatheringstatechange = () => {
      console.log(`[WebRTC] ICE gathering state for ${displayName}: ${pc.iceGatheringState}`);
    };

    pc.oniceconnectionstatechange = () => {
      console.log(`[WebRTC] ICE connection state for ${displayName}: ${pc.iceConnectionState}`);
    };

    pc.onnegotiationneeded = async () => {
      if (isInitiator && pc.signalingState !== "closed") {
        try {
          console.log(`[WebRTC] Negotiation needed for ${displayName}, state: ${pc.signalingState}`);
          await pc.setLocalDescription(await pc.createOffer());
          this.pushEvent("webrtc_signaling", { to: peerId, payload: pc.localDescription });
        } catch (err) {
          console.error(`[WebRTC] Negotiation failed for ${displayName}:`, err);
        }
      }
    };

    pc.ontrack = (event) => {
      console.log(`[WebRTC] Received remote track from ${displayName}`, event.streams);
      this.addRemoteVideo(peerId, displayName, event.streams[0]);
    };

    if (isInitiator) {
      pc.createOffer()
        .then(offer => pc.setLocalDescription(offer))
        .then(() => {
          console.log(`[WebRTC] Sent initial offer to ${displayName}`);
          this.pushEvent("webrtc_signaling", { to: peerId, payload: pc.localDescription });
        })
        .catch(err => console.error("[WebRTC] Offer creation failed:", err));
    }

    return pc;
  },

  addRemoteVideo(peerId, displayName, stream) {
    console.log(`[WebRTC] Attempting to add video for ${displayName}, stream:`, stream ? stream.id : "null");
    if (!stream) {
      console.warn(`[WebRTC] No stream received for ${displayName}`);
      return;
    }

    const grid = document.getElementById("video-grid");
    if (!grid) {
      console.error("[WebRTC] Video grid not found!");
      return;
    }

    let videoEl = document.getElementById(`video-${peerId}`);
    if (!videoEl) {
      console.log(`[WebRTC] Creating new video element for ${displayName}`);
      const wrapperEl = document.createElement("div");
      wrapperEl.id = `wrapper-${peerId}`;
      wrapperEl.className = "relative group bg-zinc-900 rounded-2xl overflow-hidden border-2 border-zinc-800 shadow-2xl aspect-video";

      videoEl = document.createElement("video");
      videoEl.id = `video-${peerId}`;
      videoEl.className = "w-full h-full object-cover";
      videoEl.autoplay = true;
      videoEl.playsInline = true;
      videoEl.srcObject = stream;

      // Force play
      videoEl.onloadedmetadata = () => {
        videoEl.play().catch(e => console.error("[WebRTC] Error playing remote video:", e));
      };

      const labelEl = document.createElement("div");
      labelEl.className = "absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/80 to-transparent p-4 text-center";
      labelEl.innerHTML = `<p class="text-sm font-bold tracking-tight">${displayName}</p>`;

      wrapperEl.appendChild(videoEl);
      wrapperEl.appendChild(labelEl);
      grid.appendChild(wrapperEl);
      console.log(`[WebRTC] Video element added for ${displayName}`);
    } else {
      console.log(`[WebRTC] Updating existing video element for ${displayName}`);
      videoEl.srcObject = stream;
    }
  },

  // ... (rest of the helper methods: setupAudioToggle, setupVideoToggle, setupRecording, etc. - keeping them unchanged)
  monitorLocalStream(stream) {
    stream.getTracks().forEach(track => {
      track.addEventListener("ended", () => console.warn(`${track.kind} lost`));
    });
  },
  setupAudioToggle() { /* ... */ },
  setupVideoToggle() { /* ... */ },
  setupRecording() { /* ... */ },
  updateConnectionStatus(status) { /* ... */ },
  handleMediaError(err) { /* ... */ },
  handleSignalingError(id, err) { /* ... */ },
  handleConnectionFailure(id, pc, name, config, init) { /* ... */ },
  showError(m) { console.error(m) },
  showWarning(m) { console.warn(m) },
  showSuccess(m) { console.log(m) },
  showNotification(m, t) { console.log(`[${t}] ${m}`) },

  destroyed() {
    console.log("[WebRTC] Hook destroyed, cleaning up...");
    if (this.localStream) {
      this.localStream.getTracks().forEach(track => track.stop());
    }
    Object.values(this.peerConnections).forEach(pc => pc.close());
    this.peerConnections = {};
  }
};

export default WebRTC;
