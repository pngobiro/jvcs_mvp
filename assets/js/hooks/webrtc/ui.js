export default {
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
