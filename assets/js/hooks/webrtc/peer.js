export default {
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

  reconnect() {
    console.log("[WebRTC-SFU] Reconnecting (server requested)...");
    this.showNotification("Media connection syncing...", "info");
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
      const wrapper = document.getElementById(`wrapper-${streamId}`);
      if (wrapper) wrapper.remove();
    });
    this.remoteStreams.clear();
    this.pendingCandidates = [];

    // Re-create connection with existing local stream
    if (this.localStream) {
      this.createPeerConnection();
      this.pushEvent("join_call", { peer_id: this.peerId });
    }
  }
};
