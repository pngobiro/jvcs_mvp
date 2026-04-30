const WebRTC = {
  mounted() {
    this.peerId = Math.random().toString(36).substring(2, 15);
    this.peerConnections = {};
    this.localStream = null;
    this.connectionRetries = {};
    this.maxRetries = 3;

    const configuration = {
      iceServers: [
        { urls: "stun:stun.l.google.com:19302" }
      ]
    };

    // Initialize status indicator
    this.updateConnectionStatus("initializing");

    // Get Local Media with comprehensive error handling
    navigator.mediaDevices.getUserMedia({ video: true, audio: true })
      .then(stream => {
        this.localStream = stream;
        document.getElementById("local-video").srcObject = stream;

        // Monitor local stream for device disconnection
        this.monitorLocalStream(stream);
        
        // Notify server we joined
        this.pushEvent("join_call", { peer_id: this.peerId });
        this.updateConnectionStatus("connected");
      })
      .catch(error => {
        this.handleMediaError(error);
        this.updateConnectionStatus("failed");
      });

    // Handle Peer Joined
    this.handleEvent("peer_joined", ({ peer_id, display_name }) => {
      if (peer_id === this.peerId) return;
      if (!this.peerConnections[peer_id]) {
        this.createPeerConnection(peer_id, display_name, configuration, true);
      }
    });

    // Handle incoming signaling with error recovery
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
        this.handleSignalingError(from, err);
      }
    });

    // Handle connection errors from server
    this.handleEvent("connection_error", ({ error }) => {
      this.showError(error);
      this.updateConnectionStatus("warning");
    });

    // Setup UI Controls
    this.setupAudioToggle();
    this.setupVideoToggle();
    this.setupRecording();
  },

  monitorLocalStream(stream) {
    const onTrackEnded = (track) => {
      const trackType = track.kind;
      console.warn(`${trackType} track ended unexpectedly`);
      this.showWarning(`${trackType.toUpperCase()} track lost. Please check your device.`);
      this.updateConnectionStatus("warning");
    };

    stream.getTracks().forEach(track => {
      track.addEventListener("ended", () => onTrackEnded(track));
    });
  },

  setupAudioToggle() {
    const toggleAudio = document.getElementById("toggle-audio");
    if (!toggleAudio) return;

    toggleAudio.addEventListener("click", () => {
      if (!this.localStream) return;
      const audioTrack = this.localStream.getAudioTracks()[0];
      if (audioTrack) {
        audioTrack.enabled = !audioTrack.enabled;
        toggleAudio.classList.toggle("bg-red-600");
        toggleAudio.classList.toggle("bg-zinc-700");
      }
    });
  },

  setupVideoToggle() {
    const toggleVideo = document.getElementById("toggle-video");
    if (!toggleVideo) return;

    toggleVideo.addEventListener("click", () => {
      if (!this.localStream) return;
      const videoTrack = this.localStream.getVideoTracks()[0];
      if (videoTrack) {
        videoTrack.enabled = !videoTrack.enabled;
        toggleVideo.classList.toggle("bg-red-600");
        toggleVideo.classList.toggle("bg-zinc-700");
      }
    });
  },

  setupRecording() {
    const recordBtn = document.getElementById("toggle-record");
    if (!recordBtn) return;

    let mediaRecorder;
    let audioRecorder;
    let recordedChunks = [];
    let recordedAudioChunks = [];
    let audioContext;
    let audioSource;
    let audioProcessor;

    recordBtn.addEventListener("click", async () => {
      if (mediaRecorder && mediaRecorder.state === "recording") {
        this.stopRecording(mediaRecorder, audioRecorder, audioProcessor, recordBtn);
      } else {
        try {
          if (!this.localStream) {
            this.showError("Camera is not available. Please enable your camera first.");
            return;
          }

          // Record video + audio as webm
          try {
            mediaRecorder = new MediaRecorder(this.localStream, { mimeType: "video/webm; codecs=vp9" });
          } catch (e) {
            console.warn("VP9 codec not supported, falling back to default");
            mediaRecorder = new MediaRecorder(this.localStream);
          }

          mediaRecorder.onerror = (e) => {
            console.error("Recording error:", e.error);
            this.showError(`Recording failed: ${e.error}`);
            this.stopRecording(mediaRecorder, audioRecorder, audioProcessor, recordBtn);
          };

          mediaRecorder.ondataavailable = (e) => {
            if (e.data.size > 0) {
              recordedChunks.push(e.data);
            }
          };

          mediaRecorder.onstop = () => {
            this.saveRecording(recordedChunks, "webm", "court-session");
            recordedChunks = [];
          };

          // Record audio separately
          if (!audioContext) {
            audioContext = new (window.AudioContext || window.webkitAudioContext)();
          }

          if (!audioSource) {
            audioSource = audioContext.createMediaStreamSource(this.localStream);
          }

          const audioTrack = this.localStream.getAudioTracks()[0];
          if (audioTrack) {
            const audioStream = new MediaStream();
            audioStream.addTrack(audioTrack);

            try {
              audioRecorder = new MediaRecorder(audioStream, { mimeType: "audio/webm" });
            } catch (e) {
              audioRecorder = new MediaRecorder(audioStream);
            }

            audioRecorder.onerror = (e) => {
              console.error("Audio recording error:", e.error);
            };

            audioRecorder.ondataavailable = (e) => {
              if (e.data.size > 0) {
                recordedAudioChunks.push(e.data);
              }
            };

            audioRecorder.onstop = () => {
              this.saveRecording(recordedAudioChunks, "webm", "court-session-audio");
              recordedAudioChunks = [];
            };

            audioRecorder.start();
          }

          mediaRecorder.start();
          recordBtn.classList.remove("bg-zinc-800");
          recordBtn.classList.add("bg-red-600", "animate-pulse");
          recordBtn.querySelector("svg").classList.remove("text-zinc-400");
          recordBtn.querySelector("svg").classList.add("text-white");
          this.showSuccess("Recording started");
          
        } catch (err) {
          console.error("Error starting recording:", err);
          this.showError(`Could not start recording: ${err.message}`);
        }
      }
    });
  },

  stopRecording(mediaRecorder, audioRecorder, audioProcessor, recordBtn) {
    if (mediaRecorder) mediaRecorder.stop();
    if (audioRecorder) audioRecorder.stop();
    if (audioProcessor) {
      audioProcessor.disconnect();
    }
    
    recordBtn.classList.remove("bg-red-600", "animate-pulse");
    recordBtn.classList.add("bg-zinc-800");
    recordBtn.querySelector("svg").classList.remove("text-white");
    recordBtn.querySelector("svg").classList.add("text-zinc-400");
    this.showSuccess("Recording stopped and saved");
  },

  saveRecording(chunks, ext, filename) {
    const blob = new Blob(chunks, { type: `${ext === "webm" ? "video" : "audio"}/webm` });
    const url = URL.createObjectURL(blob);
    
    // Download locally
    const a = document.createElement("a");
    document.body.appendChild(a);
    a.style = "display: none";
    a.href = url;
    const dateStr = new Date().toISOString().replace(/[:.]/g, "-");
    const fullFilename = `${filename}-${dateStr}.${ext}`;
    a.download = fullFilename;
    a.click();
    window.URL.revokeObjectURL(url);
    document.body.removeChild(a);

    // Upload to R2 via server
    this.uploadRecording(blob, fullFilename);
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
        console.log("Recording uploaded:", result.url);
      } else {
        throw new Error(result.message || "Upload failed");
      }
    } catch (err) {
      console.error("Upload error:", err);
      this.showError("Failed to archive recording. Please keep your local copy.");
    }
  },

  createPeerConnection(peerId, displayName, configuration, isInitiator) {
    const pc = new RTCPeerConnection(configuration);
    this.peerConnections[peerId] = pc;
    this.connectionRetries[peerId] = 0;

    // Add local stream to connection
    if (this.localStream) {
      this.localStream.getTracks().forEach(track => pc.addTrack(track, this.localStream));
    }

    // Handle connection state changes
    pc.onconnectionstatechange = () => {
      console.log(`Peer ${peerId} connection state: ${pc.connectionState}`);
      if (pc.connectionState === "failed") {
        this.handleConnectionFailure(peerId, pc, displayName, configuration, isInitiator);
      } else if (pc.connectionState === "disconnected") {
        this.showWarning(`Peer ${displayName} disconnected`);
      }
    };

    // Handle ICE connections
    pc.oniceconnectionstatechange = () => {
      console.log(`Peer ${peerId} ICE state: ${pc.iceConnectionState}`);
      if (pc.iceConnectionState === "failed") {
        this.handleICEFailure(peerId);
      }
    };

    // Handle ICE candidates
    pc.onicecandidate = (event) => {
      if (event.candidate) {
        this.pushEvent("webrtc_signaling", { to: peerId, payload: event.candidate });
      }
    };

    // Handle incoming streams
    pc.ontrack = (event) => {
      this.addRemoteVideo(peerId, displayName, event.streams[0]);
    };

    // Create offer if initiator
    if (isInitiator) {
      this.createOfferWithRetry(peerId, pc);
    }

    return pc;
  },

  createOfferWithRetry(peerId, pc) {
    pc.createOffer()
      .then(offer => pc.setLocalDescription(offer))
      .then(() => {
        this.pushEvent("webrtc_signaling", { to: peerId, payload: pc.localDescription });
      })
      .catch(err => {
        this.handleSignalingError(peerId, err);
      });
  },

  handleConnectionFailure(peerId, pc, displayName, configuration, isInitiator) {
    console.error(`Connection failed for peer ${peerId}`);
    
    if (this.connectionRetries[peerId] < this.maxRetries) {
      this.connectionRetries[peerId]++;
      console.log(`Attempting reconnection for ${peerId}, attempt ${this.connectionRetries[peerId]}/${this.maxRetries}`);
      
      // Clean up old connection
      pc.close();
      delete this.peerConnections[peerId];
      
      // Exponential backoff
      const backoffMs = Math.min(1000 * Math.pow(2, this.connectionRetries[peerId] - 1), 30000);
      setTimeout(() => {
        this.createPeerConnection(peerId, displayName, configuration, isInitiator);
      }, backoffMs);
      
      this.showWarning(`Reconnecting to ${displayName}...`);
    } else {
      console.error(`Max retries reached for peer ${peerId}`);
      this.showError(`Failed to connect to ${displayName}`);
      const wrapperEl = document.getElementById(`wrapper-${peerId}`);
      if (wrapperEl) wrapperEl.remove();
      delete this.peerConnections[peerId];
      delete this.connectionRetries[peerId];
    }
  },

  handleICEFailure(peerId) {
    console.warn(`ICE connection failed for ${peerId}`);
    this.showWarning("Network connectivity issue detected");
  },

  handleSignalingError(peerId, error) {
    console.error(`Signaling error with peer ${peerId}:`, error);
    this.showWarning(`Connection error with peer ${peerId}`);
  },

  handleMediaError(error) {
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
    
    this.showError(msg);
    console.error("Media access error:", error);
  },

  addRemoteVideo(peerId, displayName, stream) {
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
      videoEl.srcObject = stream;

      const labelEl = document.createElement("div");
      labelEl.className = "absolute bottom-2 left-2 bg-black/50 px-2 py-1 rounded text-xs";
      labelEl.innerText = displayName;

      wrapperEl.appendChild(videoEl);
      wrapperEl.appendChild(labelEl);
      document.getElementById("video-grid").appendChild(wrapperEl);
    }
  },

  updateConnectionStatus(status) {
    const statusEl = document.getElementById("connection-status");
    if (!statusEl) return;

    statusEl.classList.remove("bg-yellow-500", "bg-green-500", "bg-red-500");
    
    switch (status) {
      case "connected":
        statusEl.classList.add("bg-green-500");
        statusEl.title = "Connected";
        break;
      case "initializing":
        statusEl.classList.add("bg-yellow-500");
        statusEl.title = "Initializing...";
        break;
      case "failed":
        statusEl.classList.add("bg-red-500");
        statusEl.title = "Connection failed";
        break;
      case "warning":
        statusEl.classList.add("bg-yellow-500");
        statusEl.title = "Connection warning";
        break;
      default:
        statusEl.classList.add("bg-yellow-500");
    }
  },

  showError(message) {
    this.showNotification(message, "error");
  },

  showWarning(message) {
    this.showNotification(message, "warning");
  },

  showSuccess(message) {
    this.showNotification(message, "success");
  },

  showNotification(message, type) {
    const container = document.getElementById("notification-container") || this.createNotificationContainer();
    
    const notification = document.createElement("div");
    notification.className = `notification-${type} p-3 rounded-lg mb-2 text-sm animate-in fade-in`;
    
    const colors = {
      error: "bg-red-500/20 border border-red-500 text-red-200",
      warning: "bg-yellow-500/20 border border-yellow-500 text-yellow-200",
      success: "bg-green-500/20 border border-green-500 text-green-200",
      info: "bg-blue-500/20 border border-blue-500 text-blue-200"
    };
    
    notification.className = `p-3 rounded-lg mb-2 text-sm animate-in fade-in ${colors[type]}`;
    notification.textContent = message;
    
    container.appendChild(notification);
    
    // Auto-remove after 5 seconds
    setTimeout(() => notification.remove(), 5000);
  },

  createNotificationContainer() {
    const container = document.createElement("div");
    container.id = "notification-container";
    container.className = "fixed top-4 right-4 z-50 max-w-xs";
    document.body.appendChild(container);
    return container;
  },

  destroyed() {
    if (this.localStream) {
      this.localStream.getTracks().forEach(track => track.stop());
    }
    Object.values(this.peerConnections).forEach(pc => pc.close());
    this.peerConnections = {};
    this.connectionRetries = {};
  }
};

export default WebRTC;
