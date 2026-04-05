import { WebPlugin } from '@capacitor/core';
/**
 * Web fallback. Uses getUserMedia — no AR, no YOLO, no depth.
 * Simulates the native session flow so the scan page runs in a browser for dev.
 */
export class DepthCaptureWeb extends WebPlugin {
    constructor() {
        super(...arguments);
        this.stream = null;
        this.video = null;
        this.items = [];
    }
    async checkSupport() {
        const hasCamera = !!(navigator.mediaDevices?.getUserMedia);
        return { supported: hasCamera, hasLidar: false };
    }
    async startSession() {
        this.stream = await navigator.mediaDevices.getUserMedia({
            video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } },
        });
        this.video = document.createElement('video');
        this.video.srcObject = this.stream;
        this.video.setAttribute('playsinline', '');
        await this.video.play();
        this.items = [];
    }
    async stopSession() {
        if (this.stream) {
            this.stream.getTracks().forEach(t => t.stop());
            this.stream = null;
        }
        this.video = null;
    }
    async getIntrinsics() {
        const w = this.video?.videoWidth ?? 1920;
        const h = this.video?.videoHeight ?? 1080;
        return { fx: 0, fy: 0, cx: w / 2, cy: h / 2, width: w, height: h };
    }
    async getAllItems() {
        return { items: this.items };
    }
    async clearItems() {
        this.items = [];
    }
    addListener(event, handler) {
        return super.addListener(event, handler);
    }
    // ── Web-only helpers (for dev testing) ───────────────────────────────────
    /** Simulate capturing one item (call from browser devtools for testing). */
    async simulateCapture(label) {
        const frame = await this._captureFrame();
        const item = { label, frames: [frame], arcDegrees: 28, hasDepth: false };
        this.items.push(item);
        this.notifyListeners('itemSaved', { label, frameCount: 1, arcDegrees: 28, hasDepth: false });
    }
    async _captureFrame() {
        const canvas = document.createElement('canvas');
        canvas.width = this.video?.videoWidth ?? 640;
        canvas.height = this.video?.videoHeight ?? 480;
        canvas.getContext('2d')?.drawImage(this.video, 0, 0);
        const imageBase64 = canvas.toDataURL('image/jpeg', 0.85).split(',')[1];
        return { imageBase64, depthMapBase64: null, pose: null };
    }
}
//# sourceMappingURL=web.js.map