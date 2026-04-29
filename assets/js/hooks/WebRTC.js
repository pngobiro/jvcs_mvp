const WebRTC = {
  mounted() {
    this.peerId = Math.random().toString(36).substring(2, 15);
    this.peerConnections = {};
    this.localStream = null;

    const configuration = {
      iceServers: [
        { urls: "stun:stun.l.google.com:19302" }
      ]
    };

    // Get Local Media
    navigator.mediaDevices.getUserMedia({ video: true, audio: true })
      .then(stream => {
        this.localStream = stream;
        document.getElementById("local-video").srcObject = stream;
        
        // Notify server we joined
        this.pushEvent("join_call", { peer_id: this.peerId });
      })
      .catch(error => {
        console.error("Error accessing media devices:", error);
        let msg = "Could not access camera or microphone.\n\n";
        
        if (error.name === "NotAllowedError") {
          msg += "Permission denied. Please allow camera/mic access in your browser settings.";
        } else if (error.name === "NotFoundError") {
          msg += "No camera or microphone found on this device.";
        } else if (error.name === "NotReadableError") {
          msg += "The hardware is already in use by another application.";
        } else if (window.location.protocol !== "https:" && window.location.hostname !== "localhost") {
          msg += "WebRTC requires HTTPS or localhost to function.";
        } else {
          msg += "Error: " + error.message;
        }
        
        alert(msg);
      });

    // Handle Peer Joined
    this.handleEvent("peer_joined", ({ peer_id, display_name }) => {
      if (peer_id === this.peerId) return;
      if (!this.peerConnections[peer_id]) {
        this.createPeerConnection(peer_id, display_name, configuration, true);
      }
    });

    // Handle incoming signaling
    this.handleEvent("webrtc_signaling", async ({ from, payload }) => {
      if (from === this.peerId) return;

      if (!this.peerConnections[from]) {
        this.createPeerConnection(from, "Participant", configuration, false);
      }

      const pc = this.peerConnections[from];

      try {
        if (payload.type === "offer") {
          await pc.setRemoteDescription(new RTCSessionDescription(payload));
          const answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          this.pushEvent("webrtc_signaling", { to: from, payload: pc.localDescription });
        } else if (payload.type === "answer") {
          await pc.setRemoteDescription(new RTCSessionDescription(payload));
        } else if (payload.candidate) {
          await pc.addIceCandidate(new RTCIceCandidate(payload));
        }
      } catch (err) {
        console.error("Error handling signaling data", err);
      }
    });

    // Setup UI Controls
    document.getElementById("toggle-audio").addEventListener("click", () => {
      if (!this.localStream) return;
      const audioTrack = this.localStream.getAudioTracks()[0];
      if (audioTrack) {
        audioTrack.enabled = !audioTrack.enabled;
        document.getElementById("toggle-audio").classList.toggle("bg-red-600");
        document.getElementById("toggle-audio").classList.toggle("bg-zinc-700");
      }
    });

    document.getElementById("toggle-video").addEventListener("click", () => {
      if (!this.localStream) return;
      const videoTrack = this.localStream.getVideoTracks()[0];
      if (videoTrack) {
        videoTrack.enabled = !videoTrack.enabled;
        document.getElementById("toggle-video").classList.toggle("bg-red-600");
        document.getElementById("toggle-video").classList.toggle("bg-zinc-700");
      }
    });
  },

  createPeerConnection(peerId, displayName, configuration, isInitiator) {
    const pc = new RTCPeerConnection(configuration);
    this.peerConnections[peerId] = pc;

    // Add local stream to connection
    if (this.localStream) {
      this.localStream.getTracks().forEach(track => pc.addTrack(track, this.localStream));
    }

    // Handle ICE candidates
    pc.onicecandidate = (event) => {
      if (event.candidate) {
        this.pushEvent("webrtc_signaling", { to: peerId, payload: event.candidate });
      }
    };

    // Handle incoming streams
    pc.ontrack = (event) => {
      let videoEl = document.getElementById(`video-${peerId}`);
      if (!videoEl) {
        const wrapperEl = document.createElement("div");
        wrapperEl.className = "relative bg-black rounded-lg overflow-hidden border border-zinc-700 shadow-lg";
        wrapperEl.id = `wrapper-${peerId}`;

        videoEl = document.createElement("video");
        videoEl.id = `video-${peerId}`;
        videoEl.className = "w-full h-full object-cover";
        videoEl.autoplay = true;
        videoEl.playsInline = true;
        videoEl.srcObject = event.streams[0];

        const labelEl = document.createElement("div");
        labelEl.className = "absolute bottom-2 left-2 bg-black/50 px-2 py-1 rounded text-xs";
        labelEl.innerText = displayName;

        wrapperEl.appendChild(videoEl);
        wrapperEl.appendChild(labelEl);
        document.getElementById("video-grid").appendChild(wrapperEl);
      }
    };

    pc.oniceconnectionstatechange = () => {
      if (pc.iceConnectionState === "disconnected" || pc.iceConnectionState === "failed" || pc.iceConnectionState === "closed") {
        const wrapperEl = document.getElementById(`wrapper-${peerId}`);
        if (wrapperEl) wrapperEl.remove();
        delete this.peerConnections[peerId];
      }
    };

    // Create offer if initiator
    if (isInitiator) {
      pc.createOffer()
        .then(offer => pc.setLocalDescription(offer))
        .then(() => {
          this.pushEvent("webrtc_signaling", { to: peerId, payload: pc.localDescription });
        })
        .catch(err => console.error("Error creating offer", err));
    }

    return pc;
  },

  destroyed() {
    if (this.localStream) {
      this.localStream.getTracks().forEach(track => track.stop());
    }
    Object.values(this.peerConnections).forEach(pc => pc.close());
    this.peerConnections = {};
  }
};

export default WebRTC;
