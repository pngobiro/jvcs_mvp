import peer from "./webrtc/peer";
import ui from "./webrtc/ui";
import media from "./webrtc/media";
import recording from "./webrtc/recording";

/**
 * WebRTC Hook for Server-Side SFU
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
        { urls: "stun:stun1.l.google.com:19302" },
        { urls: "stun:stun2.l.google.com:19302" }
      ],
      iceCandidatePoolSize: 20
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

  ...peer,
  ...ui,
  ...media,
  ...recording
};

export default WebRTCSimple;
