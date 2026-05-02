export default {
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
  }
};
