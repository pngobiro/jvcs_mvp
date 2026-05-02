export default {
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
  }
};
