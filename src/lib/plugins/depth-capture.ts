export interface DepthCapturePlugin {
  checkSupport(): Promise<{ supported: boolean; hasLidar: boolean; hasDepth: boolean }>;
  startSession(): Promise<void>;
  captureFrame(): Promise<CapturedFrameResult>;
  stopSession(): Promise<void>;
}

export interface CapturedFrameResult {
  imageBase64: string;
  depthMapBase64: string;
  width: number;
  height: number;
  timestamp: number;
  intrinsics: {
    fx: number;
    fy: number;
    cx: number;
    cy: number;
  };
}

/**
 * Web fallback: uses getUserMedia for camera, no depth data.
 */
export class WebDepthCapture implements DepthCapturePlugin {
  stream: MediaStream | null = null;
  private video: HTMLVideoElement | null = null;

  async checkSupport() {
    const hasCamera = !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
    return { supported: hasCamera, hasLidar: false, hasDepth: false };
  }

  async startSession() {
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } }
    });
    this.video = document.createElement('video');
    this.video.srcObject = this.stream;
    this.video.setAttribute('playsinline', '');
    await this.video.play();
  }

  async captureFrame(): Promise<CapturedFrameResult> {
    if (!this.video || !this.stream) throw new Error('Session not started');

    const canvas = document.createElement('canvas');
    canvas.width = this.video.videoWidth;
    canvas.height = this.video.videoHeight;
    const ctx = canvas.getContext('2d')!;
    ctx.drawImage(this.video, 0, 0);

    const imageBase64 = canvas.toDataURL('image/jpeg', 0.85).split(',')[1];

    return {
      imageBase64,
      depthMapBase64: '',
      width: canvas.width,
      height: canvas.height,
      timestamp: Date.now(),
      intrinsics: { fx: 0, fy: 0, cx: canvas.width / 2, cy: canvas.height / 2 },
    };
  }

  async stopSession() {
    if (this.stream) {
      this.stream.getTracks().forEach(t => t.stop());
      this.stream = null;
    }
    this.video = null;
  }
}
