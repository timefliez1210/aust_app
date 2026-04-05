import { registerPlugin } from '@capacitor/core';
import type { DepthCapturePlugin } from 'capacitor-depth-capture';

// Re-export types for convenience
export type {
  DepthCapturePlugin,
  DepthSupportResult,
  BoundingBox,
  Detection,
  ArcProgress,
  ItemSavedEvent,
  ItemScan,
  ItemFrame,
  CameraIntrinsics,
} from 'capacitor-depth-capture';

export const DepthCapture = registerPlugin<DepthCapturePlugin>('DepthCapture', {
  web: () => import('capacitor-depth-capture').then(m => new m.DepthCaptureWeb()),
});
