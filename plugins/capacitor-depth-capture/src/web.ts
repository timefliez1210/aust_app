import { WebPlugin } from '@capacitor/core';
import type {
  DepthCapturePlugin,
  DepthSupportResult,
  CameraIntrinsics,
  ItemScan,
  ArcProgress,
  ItemSavedEvent,
  DrawnBox,
  Detection,
} from './definitions';

/**
 * Web fallback. Uses getUserMedia — no AR, no YOLO, no depth.
 * Simulates the event-based API so the scan page can run in a browser for dev.
 */
export class DepthCaptureWeb extends WebPlugin implements DepthCapturePlugin {
  private stream: MediaStream | null = null;
  private video: HTMLVideoElement | null = null;
  private items: ItemScan[] = [];
  private sessionIntrinsics: CameraIntrinsics | null = null;

  async checkSupport(): Promise<DepthSupportResult> {
    const hasCamera = !!(navigator.mediaDevices?.getUserMedia);
    return { supported: hasCamera, hasLidar: false };
  }

  async startSession(): Promise<void> {
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } },
    });
    this.video = document.createElement('video');
    this.video.srcObject = this.stream;
    this.video.setAttribute('playsinline', '');
    await this.video.play();
    this.items = [];
  }

  async stopSession(): Promise<void> {
    if (this.stream) {
      this.stream.getTracks().forEach(t => t.stop());
      this.stream = null;
    }
    this.video = null;
  }

  async startItemScan(options: { label: string }): Promise<void> {
    // Web fallback: capture a single frame immediately and fake a completed arc.
    if (!this.video) return;
    const frame = await this._captureWebFrame();
    const item: ItemScan = {
      label: options.label,
      frames: [frame],
      arcDegrees: 28,
      hasDepth: false,
    };
    this.items.push(item);
    const evt: ItemSavedEvent = {
      label: options.label,
      frameCount: 1,
      arcDegrees: 28,
      hasDepth: false,
    };
    this.notifyListeners('itemSaved', evt);
  }

  async cancelItemScan(): Promise<void> {
    // no-op on web
  }

  async setDrawMode(_options: { enabled: boolean }): Promise<void> {
    // no-op on web — draw mode is a native-only feature
  }

  async getIntrinsics(): Promise<CameraIntrinsics> {
    if (this.sessionIntrinsics) return this.sessionIntrinsics;
    const w = this.video?.videoWidth ?? 1920;
    const h = this.video?.videoHeight ?? 1080;
    return { fx: 0, fy: 0, cx: w / 2, cy: h / 2, width: w, height: h };
  }

  async getAllItems(): Promise<{ items: ItemScan[] }> {
    return { items: this.items };
  }

  async clearItems(): Promise<void> {
    this.items = [];
  }

  // ── Typed event stubs so the web class satisfies the interface ────────────

  addListener(event: 'detections', handler: (data: { detections: Detection[] }) => void): any;
  addListener(event: 'arcProgress', handler: (data: ArcProgress) => void): any;
  addListener(event: 'itemSaved', handler: (data: ItemSavedEvent) => void): any;
  addListener(event: 'boxDrawn', handler: (data: DrawnBox) => void): any;
  addListener(event: string, handler: (data: any) => void): any {
    return super.addListener(event, handler);
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  private async _captureWebFrame() {
    const canvas = document.createElement('canvas');
    canvas.width = this.video!.videoWidth;
    canvas.height = this.video!.videoHeight;
    canvas.getContext('2d')!.drawImage(this.video!, 0, 0);
    const imageBase64 = canvas.toDataURL('image/jpeg', 0.85).split(',')[1];
    return { imageBase64, depthMapBase64: null, pose: null };
  }
}
