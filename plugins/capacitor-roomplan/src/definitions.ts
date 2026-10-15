export interface RoomPlanPlugin {
  /** True on iOS 16+ devices with LiDAR (`RoomCaptureSession.isSupported`). */
  isSupported(): Promise<{ supported: boolean }>;

  /**
   * Present Apple's RoomPlan scanner full-screen for one room and resolve with
   * the furniture it found. Cancelling resolves with `cancelled: true` and no
   * objects rather than rejecting; a failed scan (camera denied, processing
   * error) rejects.
   */
  scanRoom(options: { roomName: string }): Promise<RoomScanResult>;
}

export interface RoomScanResult {
  cancelled: boolean;
  objects: ScannedObject[];
  /** The room's walls as [[x, z], [x, z]] end points in metres — the floor plan's outline. */
  walls?: [number, number][][];
  /** What the leftover measurement saw (point source, counts) — for debugging. */
  diagnostics?: Record<string, unknown>;
}

export interface ScannedObject {
  /**
   * RoomPlan's `CapturedRoom.Object.Category` case name, e.g. "sofa",
   * "washerDryer", or "unknown" for a case this plugin predates. "other" is
   * something RoomPlan has no category for, measured by the plugin itself from
   * the geometry RoomPlan left over.
   */
  category: string;
  /**
   * Bounding box fitted to the scanned geometry, [length, width, height] in
   * metres — length is the longer footprint side. A measurement, not a
   * per-category default.
   */
  dimsM: [number, number, number];
  /** RoomPlan's confidence mapped to 0.3 (low) / 0.6 (medium) / 0.9 (high); 0.3 for "other". */
  confidence: number;
  /** "other" only: base64 JPEG of the object, cropped from the scan. */
  imageBase64?: string;
  /** Footprint corners [[x, z] × 4] in metres, same frame as `walls`. */
  footprint?: [number, number][];
}
