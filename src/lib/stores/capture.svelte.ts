import type { CameraIntrinsics, ItemScan } from '$lib/plugins/depth-capture';

export interface StoredItem {
  id: string;
  label: string;
  frames: {
    imageBase64: string;
    depthMapBase64: string | null;
    pose: number[] | null;
  }[];
  arcDegrees: number;
  hasDepth: boolean;
  /**
   * Volume in m³ incl. packing factor — measured on device or entered by hand.
   * null when neither happened and the backend has to estimate from photos.
   */
  volumeM3: number | null;
  /** Dims [length, width, height] in metres: the OBB, or typed measurements. */
  dimsM: number[] | null;
  deviceConfidence: number | null;
}

class CaptureStore {
  items: StoredItem[] = $state([]);
  intrinsics: CameraIntrinsics | null = $state(null);

  addItem(raw: ItemScan) {
    this.items.push({
      id: crypto.randomUUID(),
      label: raw.label,
      frames: raw.frames.map(f => ({
        imageBase64: f.imageBase64,
        depthMapBase64: f.depthMapBase64 ?? null,
        pose: f.pose ?? null,
      })),
      arcDegrees: raw.arcDegrees,
      hasDepth: raw.hasDepth,
      volumeM3: raw.volumeM3 ?? null,
      dimsM: raw.dimsM ?? null,
      deviceConfidence: raw.deviceConfidence ?? null,
    });
  }

  removeItem(id: string) {
    this.items = this.items.filter(i => i.id !== id);
  }

  clear() {
    this.items = [];
    this.intrinsics = null;
  }

  // No-ops kept so scan page compiles without changes
  waitReady(): Promise<void> { return Promise.resolve(); }
  persistIntrinsics() {}

  get itemCount() { return this.items.length; }
  get totalFrames() { return this.items.reduce((n, i) => n + i.frames.length, 0); }
  get hasAnyDepth() { return this.items.some(i => i.hasDepth); }
  /** Sum of on-device volumes, or null unless every item has one. */
  get deviceVolumeM3(): number | null {
    if (this.items.length === 0 || this.items.some(i => i.volumeM3 == null)) return null;
    return this.items.reduce((sum, i) => sum + (i.volumeM3 ?? 0), 0);
  }
}

export const capture = new CaptureStore();
