const WebRTC = {
  mounted() {
    this.peerId = Math.random().toString(36).substring(2, 15);
    this.peerConnections = {};
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
        const localVideo = document.getElementById("local-video");
        if (localVideo) localVideo.srcObject = stream;

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

    // Handle incoming signaling
    this.handleEvent("webrtc_signaling", async ({ from, payload }) => {
      if (from === this.peerId) return;

      if (!this.peerConnections[from]) {
        console.log(`[WebRTC] Received signal from unknown peer ${from}, creating connection (Initiator: false)`);
        this.createPeerConnection(from, "Participant", configuration, false);
      }

      const pc = this.peerConnections[from];

      try {
        if (payload.type === "offer") {
          console.log(`[WebRTC] Received offer from ${from}`);
          await pc.setRemoteDescription(new RTCSessionDescription(payload));
          const answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          this.pushEvent("webrtc_signaling", { to: from, payload: pc.localDescription });
        } else if (payload.type === "answer") {
          console.log(`[WebRTC] Received answer from ${from}`);
          await pc.setRemoteDescription(new RTCSessionDescription(payload));
        } else if (payload.candidate) {
          console.log(`[WebRTC] Received ICE candidate from ${from}`);
          await pc.addIceCandidate(new RTCIceCandidate(payload));
        }
      } catch (err) {
        console.error(`[WebRTC] Signaling error with peer ${from}:`, err);
        this.handleSignalingError(from, err);
      }
    });

    this.setupAudioToggle();
    this.setupVideoToggle();
    this.setupRecording();
  },

  createPeerConnection(peerId, displayName, configuration, isInitiator) {
    console.log(`[WebRTC] Initializing RTCPeerConnection for ${displayName}`);
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
        this.handleConnectionFailure(peerId, pc, displayName, configuration, isInitiator);
      }
    };

    pc.onicecandidate = (event) => {
      if (event.candidate) {
        this.pushEvent("webrtc_signaling", { to: peerId, payload: event.candidate });
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
          console.log(`[WebRTC] Sent offer to ${displayName}`);
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
