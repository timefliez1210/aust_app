import { registerPlugin, WebPlugin } from '@capacitor/core';
import type { PluginListenerHandle } from '@capacitor/core';

// ── Types ─────────────────────────────────────────────────────────────────────

export interface DepthSupportResult {
  supported: boolean;
  hasLidar: boolean;
}

/** Normalized bounding box: values in [0, 1] relative to screen size. */
export interface BoundingBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface DrawnBox extends BoundingBox {
  screenW: number;
  screenH: number;
}

export interface Detection {
  label: string;
  germanLabel: string;
  confidence: number;
  bbox: BoundingBox;
}

export interface ArcProgress {
  degrees: number;
  direction: 'left' | 'right' | 'up' | 'down';
}

export interface ItemSavedEvent {
  label: string;
  frameCount: number;
  arcDegrees: number;
  hasDepth: boolean;
}

export interface ItemFrame {
  imageBase64: string;
  depthMapBase64: string | null;
  pose: number[] | null;
}

export interface ItemScan {
  label: string;
  frames: ItemFrame[];
  arcDegrees: number;
  hasDepth: boolean;
}

export interface CameraIntrinsics {
  fx: number;
  fy: number;
  cx: number;
  cy: number;
  width: number;
  height: number;
}

export interface DepthCapturePlugin {
  checkSupport(): Promise<DepthSupportResult>;
  startSession(): Promise<void>;
  stopSession(): Promise<void>;
  startItemScan(options: { label: string; bbox: BoundingBox }): Promise<void>;
  cancelItemScan(): Promise<void>;
  setDrawMode(options: { enabled: boolean }): Promise<void>;
  getIntrinsics(): Promise<CameraIntrinsics>;
  getAllItems(): Promise<{ items: ItemScan[] }>;
  clearItems(): Promise<void>;

  addListener(event: 'detections',  handler: (data: { detections: Detection[] }) => void): Promise<PluginListenerHandle>;
  addListener(event: 'arcProgress', handler: (data: ArcProgress) => void): Promise<PluginListenerHandle>;
  addListener(event: 'itemSaved',   handler: (data: ItemSavedEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: 'boxDrawn',    handler: (data: DrawnBox) => void): Promise<PluginListenerHandle>;
  removeAllListeners(): Promise<void>;
}

// ── Web fallback ──────────────────────────────────────────────────────────────

/**
 * Browser fallback: getUserMedia camera, no AR/YOLO/depth.
 * Simulates the event API so the scan page compiles and runs in a browser during dev.
 */
class DepthCaptureWeb extends WebPlugin implements DepthCapturePlugin {
  private stream: MediaStream | null = null;
  private video: HTMLVideoElement | null = null;
  private items: ItemScan[] = [];

  async checkSupport(): Promise<DepthSupportResult> {
    return { supported: !!(navigator.mediaDevices?.getUserMedia), hasLidar: false };
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
    this.stream?.getTracks().forEach(t => t.stop());
    this.stream = null;
    this.video = null;
  }

  async startItemScan(options: { label: string }): Promise<void> {
    const frame = await this._captureFrame();
    const item: ItemScan = { label: options.label, frames: [frame], arcDegrees: 28, hasDepth: false };
    this.items.push(item);
    this.notifyListeners('itemSaved', { label: options.label, frameCount: 1, arcDegrees: 28, hasDepth: false });
  }

  async cancelItemScan(): Promise<void> {}

  async setDrawMode(_opts: { enabled: boolean }): Promise<void> {}

  async getIntrinsics(): Promise<CameraIntrinsics> {
    const w = this.video?.videoWidth ?? 1920;
    const h = this.video?.videoHeight ?? 1080;
    return { fx: 0, fy: 0, cx: w / 2, cy: h / 2, width: w, height: h };
  }

  async getAllItems(): Promise<{ items: ItemScan[] }> {
    return { items: this.items };
  }

  async clearItems(): Promise<void> { this.items = []; }

  // Satisfy overloaded addListener
  addListener(event: 'detections',  handler: (d: { detections: Detection[] }) => void): Promise<PluginListenerHandle>;
  addListener(event: 'arcProgress', handler: (d: ArcProgress) => void): Promise<PluginListenerHandle>;
  addListener(event: 'itemSaved',   handler: (d: ItemSavedEvent) => void): Promise<PluginListenerHandle>;
  addListener(event: 'boxDrawn',    handler: (d: DrawnBox) => void): Promise<PluginListenerHandle>;
  addListener(event: string, handler: (data: any) => void): Promise<PluginListenerHandle> {
    return super.addListener(event, handler);
  }

  private async _captureFrame(): Promise<ItemFrame> {
    const canvas = document.createElement('canvas');
    canvas.width  = this.video?.videoWidth  ?? 640;
    canvas.height = this.video?.videoHeight ?? 480;
    canvas.getContext('2d')?.drawImage(this.video!, 0, 0);
    const imageBase64 = canvas.toDataURL('image/jpeg', 0.85).split(',')[1];
    return { imageBase64, depthMapBase64: null, pose: null };
  }
}

// ── Registered plugin instance ────────────────────────────────────────────────

export const DepthCapture = registerPlugin<DepthCapturePlugin>('DepthCapture', {
  web: () => Promise.resolve(new DepthCaptureWeb()),
});
