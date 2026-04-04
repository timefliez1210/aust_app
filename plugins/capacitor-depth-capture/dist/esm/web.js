import { WebPlugin } from '@capacitor/core';
/**
 * Web fallback. Uses getUserMedia — no AR, no YOLO, no depth.
 * Simulates the event-based API so the scan page can run in a browser for dev.
 */
export class DepthCaptureWeb extends WebPlugin {
    constructor() {
        super(...arguments);
        this.stream = null;
        this.video = null;
        this.items = [];
        this.sessionIntrinsics = null;
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
    async startItemScan(options) {
        // Web fallback: capture a single frame immediately and fake a completed arc.
        if (!this.video)
            return;
        const frame = await this._captureWebFrame();
        const item = {
            label: options.label,
            frames: [frame],
            arcDegrees: 28,
            hasDepth: false,
        };
        this.items.push(item);
        const evt = {
            label: options.label,
            frameCount: 1,
            arcDegrees: 28,
            hasDepth: false,
        };
        this.notifyListeners('itemSaved', evt);
    }
    async cancelItemScan() {
        // no-op on web
    }
    async setDrawMode(_options) {
        // no-op on web — draw mode is a native-only feature
    }
    async getIntrinsics() {
        if (this.sessionIntrinsics)
            return this.sessionIntrinsics;
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
    // ── Private helpers ───────────────────────────────────────────────────────
    async _captureWebFrame() {
        const canvas = document.createElement('canvas');
        canvas.width = this.video.videoWidth;
        canvas.height = this.video.videoHeight;
        canvas.getContext('2d').drawImage(this.video, 0, 0);
        const imageBase64 = canvas.toDataURL('image/jpeg', 0.85).split(',')[1];
        return { imageBase64, depthMapBase64: null, pose: null };
    }
}
//# sourceMappingURL=web.js.map