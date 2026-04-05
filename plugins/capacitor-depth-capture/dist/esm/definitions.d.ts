import type { PluginListenerHandle } from '@capacitor/core';
export interface DepthCapturePlugin {
    /** Check if AR/depth capture is available on this device. */
    checkSupport(): Promise<DepthSupportResult>;
    /**
     * Start an AR session with fully native UI.
     * On iOS: hides the WebView, sets up ARSCNView + native overlay controls,
     * starts YOLO inference loop. All user interaction (detection taps, draw mode,
     * arc sweep, item management) is handled natively.
     *
     * Emits sessionComplete when user taps "Fertig", sessionCancelled on close.
     */
    startSession(): Promise<void>;
    /** Stop the AR session, release resources, and restore WebView visibility. */
    stopSession(): Promise<void>;
    /** Return camera intrinsics captured from the current ARFrame. */
    getIntrinsics(): Promise<CameraIntrinsics>;
    /** Return all saved ItemScans collected since the last clearItems(). */
    getAllItems(): Promise<{
        items: ItemScan[];
    }>;
    /** Clear all saved ItemScans. */
    clearItems(): Promise<void>;
    /** Fired when an item scan auto-completes (≥28° accumulated, ≥4 frames). */
    addListener(event: 'itemSaved', handler: (data: ItemSavedEvent) => void): Promise<PluginListenerHandle>;
    /** Fired when the user taps "Fertig" in the native overlay. */
    addListener(event: 'sessionComplete', handler: (data: {
        itemCount: number;
    }) => void): Promise<PluginListenerHandle>;
    /** Fired when the user taps the close button in the native overlay. */
    addListener(event: 'sessionCancelled', handler: (data: Record<string, never>) => void): Promise<PluginListenerHandle>;
    removeAllListeners(): Promise<void>;
}
export interface DepthSupportResult {
    /** Whether any form of capture is supported. */
    supported: boolean;
    /** True if device has LiDAR (iPhone 12 Pro+ / iPad Pro). */
    hasLidar: boolean;
}
/** Normalized bounding box: all values in [0, 1] relative to screen size. */
export interface BoundingBox {
    x: number;
    y: number;
    w: number;
    h: number;
}
export interface Detection {
    /** YOLO English class name, e.g. "couch". */
    label: string;
    /** German name from furniture_labels.json, e.g. "Sofa". Empty string if unmapped. */
    germanLabel: string;
    /** Confidence score 0–1. */
    confidence: number;
    /** Bounding box in normalized screen coordinates. */
    bbox: BoundingBox;
}
export interface ArcProgress {
    /** Degrees of camera rotation accumulated since scan start. */
    degrees: number;
    /** Dominant rotation direction this frame. */
    direction: 'left' | 'right' | 'up' | 'down';
}
export interface ItemSavedEvent {
    label: string;
    frameCount: number;
    arcDegrees: number;
    hasDepth: boolean;
}
/** A complete item scan: one arc sweep around one piece of furniture. */
export interface ItemScan {
    label: string;
    frames: ItemFrame[];
    arcDegrees: number;
    hasDepth: boolean;
}
export interface ItemFrame {
    /** JPEG image as base64. */
    imageBase64: string;
    /** 16-bit depth PNG as base64, or null on non-LiDAR devices. */
    depthMapBase64: string | null;
    /** 4×4 column-major camera transform from ARKit, as 16 floats. */
    pose: number[] | null;
}
export interface CameraIntrinsics {
    fx: number;
    fy: number;
    cx: number;
    cy: number;
    width: number;
    height: number;
}
