export interface CapturedFrame {
  imageBase64: string;
  depthMapBase64: string | null;
  width: number;
  height: number;
  timestamp: number;
  intrinsics: CameraIntrinsics | null;
}

export interface CameraIntrinsics {
  fx: number;
  fy: number;
  cx: number;
  cy: number;
}

class CaptureStore {
  frames: CapturedFrame[] = $state([]);
  isCapturing = $state(false);

  addFrame(frame: CapturedFrame) {
    this.frames.push(frame);
  }

  removeFrame(index: number) {
    this.frames.splice(index, 1);
  }

  clear() {
    this.frames = [];
    this.isCapturing = false;
  }

  get frameCount() {
    return this.frames.length;
  }

  get hasDepth() {
    return this.frames.some(f => f.depthMapBase64 !== null);
  }
}

export const capture = new CaptureStore();
