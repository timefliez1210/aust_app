export interface DepthCapturePlugin {
  /** Check if AR/depth capture is available on this device. */
  checkSupport(): Promise<DepthSupportResult>;

  /** Start an AR session. Call once before capturing frames. */
  startSession(): Promise<void>;

  /** Capture one frame: RGB image + depth map + camera intrinsics. */
  captureFrame(): Promise<CapturedFrame>;

  /** Stop the AR session and release resources. */
  stopSession(): Promise<void>;
}

export interface DepthSupportResult {
  /** Whether any form of capture is supported. */
  supported: boolean;
  /** True if device has LiDAR (iPhone Pro/iPad Pro). */
  hasLidar: boolean;
  /** True if device supports depth estimation (ARCore Depth API / ARKit). */
  hasDepth: boolean;
}

export interface CapturedFrame {
  /** JPEG-encoded RGB image as base64 string. */
  imageBase64: string;
  /** 16-bit PNG depth map as base64 string (mm precision). Empty if no depth. */
  depthMapBase64: string;
  /** Image width in pixels. */
  width: number;
  /** Image height in pixels. */
  height: number;
  /** Capture timestamp (milliseconds since epoch). */
  timestamp: number;
  /** Camera intrinsic parameters. */
  intrinsics: CameraIntrinsics;
}

export interface CameraIntrinsics {
  /** Focal length X in pixels. */
  fx: number;
  /** Focal length Y in pixels. */
  fy: number;
  /** Principal point X in pixels. */
  cx: number;
  /** Principal point Y in pixels. */
  cy: number;
}
