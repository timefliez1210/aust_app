import { WebPlugin } from '@capacitor/core';
import type { DepthCapturePlugin, CapturedFrame, DepthSupportResult } from './definitions';

/**
 * Web fallback implementation.
 * Uses standard getUserMedia for camera access. No depth data available.
 * The backend handles missing depth gracefully (falls back to LLM vision).
 */
export class DepthCaptureWeb extends WebPlugin implements DepthCapturePlugin {
  private stream: MediaStream | null = null;
  private video: HTMLVideoElement | null = null;

  async checkSupport(): Promise<DepthSupportResult> {
    const hasCamera = !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
    return { supported: hasCamera, hasLidar: false, hasDepth: false };
  }

  async startSession(): Promise<void> {
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: {
        facingMode: 'environment',
        width: { ideal: 1920 },
        height: { ideal: 1080 },
      },
    });
    this.video = document.createElement('video');
    this.video.srcObject = this.stream;
    this.video.setAttribute('playsinline', '');
    await this.video.play();
  }

  async captureFrame(): Promise<CapturedFrame> {
    if (!this.video || !this.stream) {
      throw new Error('Session not started. Call startSession() first.');
    }

    const canvas = document.createElement('canvas');
    canvas.width = this.video.videoWidth;
    canvas.height = this.video.videoHeight;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('Could not get canvas context');
    ctx.drawImage(this.video, 0, 0);

    const dataUrl = canvas.toDataURL('image/jpeg', 0.85);
    const imageBase64 = dataUrl.split(',')[1];

    return {
      imageBase64,
      depthMapBase64: '', // No depth on web
      width: canvas.width,
      height: canvas.height,
      timestamp: Date.now(),
      intrinsics: {
        fx: 0,
        fy: 0,
        cx: canvas.width / 2,
        cy: canvas.height / 2,
      },
    };
  }

  async stopSession(): Promise<void> {
    if (this.stream) {
      this.stream.getTracks().forEach((track) => track.stop());
      this.stream = null;
    }
    this.video = null;
  }
}
