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
}

export interface ScannedObject {
  /**
   * RoomPlan's `CapturedRoom.Object.Category` case name, e.g. "sofa",
   * "washerDryer", or "unknown" for a case this plugin predates.
   */
  category: string;
  /**
   * Bounding box fitted to the scanned geometry, [length, width, height] in
   * metres — length is the longer footprint side. A measurement, not a
   * per-category default.
   */
  dimsM: [number, number, number];
  /** RoomPlan's confidence mapped to 0.3 (low) / 0.6 (medium) / 0.9 (high). */
  confidence: number;
}
