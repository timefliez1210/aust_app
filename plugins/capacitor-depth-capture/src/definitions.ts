import type { PluginListenerHandle } from '@capacitor/core';

export interface DepthCapturePlugin {
  /** Check if AR/depth capture is available on this device. */
  checkSupport(): Promise<DepthSupportResult>;

  /**
   * Start an AR session with fully native UI.
   * On iOS: hides the WebView, sets up ARSCNView + native overlay controls,
   * starts YOLO inference loop. All user interaction (measure button, detection
   * taps, arc sweep, review + naming, item management) is handled natively.
   *
   * The flow is measurement-first: the user measures whatever is in the reticle
   * and names it afterwards — or not at all.
   *
   * Emits sessionComplete when user taps "Fertig", sessionCancelled on close.
   */
  startSession(): Promise<void>;

  /** Stop the AR session, release resources, and restore WebView visibility. */
  stopSession(): Promise<void>;

  /** Return camera intrinsics captured from the current ARFrame. */
  getIntrinsics(): Promise<CameraIntrinsics>;

  /** Return all saved ItemScans collected since the last clearItems(). */
  getAllItems(): Promise<{ items: ItemScan[] }>;

  /** Clear all saved ItemScans. */
  clearItems(): Promise<void>;

  // ── Event listeners ──────────────────────────────────────────────────────

  /** Fired when the user saves a measured item from the review card. */
  addListener(
    event: 'itemSaved',
    handler: (data: ItemSavedEvent) => void,
  ): Promise<PluginListenerHandle>;

  /** Fired when the user taps "Fertig" in the native overlay. */
  addListener(
    event: 'sessionComplete',
    handler: (data: { itemCount: number }) => void,
  ): Promise<PluginListenerHandle>;

  /** Fired when the user taps the close button in the native overlay. */
  addListener(
    event: 'sessionCancelled',
    handler: (data: Record<string, never>) => void,
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

export interface Detection {
  /** YOLO English class name, e.g. "couch". */
  label: string;
  /**
   * German name from furniture_labels.json, e.g. "Sofa". Empty string if unmapped.
   * Only used to pre-fill the (optional) name field after a measurement.
   */
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
  /** May be empty — naming is optional and happens server-side. */
  label: string;
  frameCount: number;
  arcDegrees: number;
  hasDepth: boolean;
  /** On-device volume estimate in m³ (LiDAR devices only). */
  volumeM3?: number;
}

/** A complete item scan: one arc sweep around one piece of furniture. */
export interface ItemScan {
  /**
   * Customer-supplied name, **possibly empty**. Volume is what the capture is
   * about; the backend names unlabelled items from their photo, so an empty
   * label must never stop an item from being submitted.
   */
  label: string;
  frames: ItemFrame[];
  arcDegrees: number;
  hasDepth: boolean;
  /**
   * On-device volume estimate in m³, computed from LiDAR depth back-projection
   * + gravity-aligned OBB (includes packing factor). Absent on non-LiDAR
   * devices or when depth segmentation failed — the backend then estimates
   * server-side.
   */
  volumeM3?: number;
  /** Gravity-aligned OBB dimensions [length, width, height] in metres. */
  dimsM?: number[];
  /** Heuristic confidence [0, 1] for the on-device measurement. */
  deviceConfidence?: number;
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
