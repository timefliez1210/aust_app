import type { PluginListenerHandle } from '@capacitor/core';

export interface DepthCapturePlugin {
  /** Check if AR/depth capture is available on this device. */
  checkSupport(): Promise<DepthSupportResult>;

  /**
   * Start an AR session with fully native UI.
   * On iOS: hides the WebView, sets up ARSCNView + native overlay controls.
   * All user interaction (measure button, guided sweep, review + naming, manual
   * entry, item management) is handled natively.
   *
   * The flow is measurement-first and guided: the user puts the object in the
   * reticle, the plugin draws the measured box with its L/B/H in place and tells
   * them where to move next, and the sweep ends by itself once the box has been
   * seen from enough angles and stopped changing. Naming happens afterwards and
   * is optional. YOLO runs silently and only pre-fills the name field.
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
   * Only used to pre-fill the (optional) name field after a measurement — the
   * native UI never draws detections.
   */
  germanLabel: string;
  /** Confidence score 0–1. */
  confidence: number;
  /** Bounding box in normalized screen coordinates. */
  bbox: BoundingBox;
}

export interface ItemSavedEvent {
  /** May be empty — naming is optional and happens server-side. */
  label: string;
  frameCount: number;
  /** Orbit span covered while measuring, in degrees. Reporting only. */
  arcDegrees: number;
  hasDepth: boolean;
  /** Volume in m³ — measured on device, or entered manually by the customer. */
  volumeM3?: number;
}

/** A complete item scan: one guided sweep around one piece of furniture. */
export interface ItemScan {
  /**
   * Customer-supplied name, **possibly empty**. Volume is what the capture is
   * about; the backend names unlabelled items from their photo, so an empty
   * label must never stop an item from being submitted.
   */
  label: string;
  frames: ItemFrame[];
  /** Orbit span covered while measuring, in degrees. Reporting only. */
  arcDegrees: number;
  hasDepth: boolean;
  /**
   * Volume in m³ including packing factor. Either measured on device (LiDAR
   * depth back-projection + gravity-aligned OBB) or entered by the customer via
   * manual entry. Absent when neither happened — the backend then estimates
   * server-side from the photos.
   */
  volumeM3?: number;
  /**
   * Dimensions [length, width, height] in metres — the gravity-aligned OBB, or
   * the customer's typed measurements. Absent when only a volume is known.
   */
  dimsM?: number[];
  /** Heuristic confidence [0, 1] for the volume. */
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
