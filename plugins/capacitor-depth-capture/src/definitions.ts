import type { PluginListenerHandle } from '@capacitor/core';

export interface DepthCapturePlugin {
  /** Check if AR/depth capture is available on this device. */
  checkSupport(): Promise<DepthSupportResult>;

  /**
   * Start an AR session. On iOS: sets up ARSCNView behind the WebView (which becomes
   * transparent) and starts YOLO inference loop. On web: starts getUserMedia.
   */
  startSession(): Promise<void>;

  /** Stop the AR session and release resources. Restores WebView opacity on iOS. */
  stopSession(): Promise<void>;

  /**
   * Begin capturing frames for one item (arc sweep mode).
   * Records ARKit poses + JPEG + depth per frame until 28° of rotation is accumulated
   * or until cancelItemScan() is called.
   * Emits arcProgress events during sweep, itemSaved when complete.
   */
  startItemScan(options: { label: string; bbox: BoundingBox }): Promise<void>;

  /** Cancel the current item scan without saving. Re-enables detection. */
  cancelItemScan(): Promise<void>;

  /**
   * Enable or disable draw mode.
   * true:  native layer captures drag gesture, emits boxDrawn event, then disables.
   * false: restore normal WebView touch handling.
   */
  setDrawMode(options: { enabled: boolean }): Promise<void>;

  /** Return camera intrinsics captured from the current ARFrame. */
  getIntrinsics(): Promise<CameraIntrinsics>;

  /** Return all saved ItemScans collected since the last clearItems(). */
  getAllItems(): Promise<{ items: ItemScan[] }>;

  /** Clear all saved ItemScans. */
  clearItems(): Promise<void>;

  // ── Event listeners ──────────────────────────────────────────────────────

  /** Fired every ~10 ARFrames with current YOLO detections. */
  addListener(
    event: 'detections',
    handler: (data: { detections: Detection[] }) => void,
  ): Promise<PluginListenerHandle>;

  /** Fired each ARFrame during an active arc sweep. */
  addListener(
    event: 'arcProgress',
    handler: (data: ArcProgress) => void,
  ): Promise<PluginListenerHandle>;

  /** Fired when an item scan auto-completes (≥28° accumulated, ≥4 frames). */
  addListener(
    event: 'itemSaved',
    handler: (data: ItemSavedEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Fired after the user completes a drag in draw mode.
   * Coordinates are normalized 0–1 relative to screen dimensions.
   */
  addListener(
    event: 'boxDrawn',
    handler: (data: DrawnBox) => void,
  ): Promise<PluginListenerHandle>;

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

/** A bounding box returned from draw mode, includes absolute screen dimensions. */
export interface DrawnBox extends BoundingBox {
  screenW: number;
  screenH: number;
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
