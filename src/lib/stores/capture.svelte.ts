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
    });
  }

  removeItem(id: string) {
    this.items = this.items.filter(i => i.id !== id);
  }

  clear() {
    this.items = [];
    this.intrinsics = null;
  }

  get itemCount() {
    return this.items.length;
  }

  get totalFrames() {
    return this.items.reduce((n, i) => n + i.frames.length, 0);
  }

  get hasAnyDepth() {
    return this.items.some(i => i.hasDepth);
  }
}

export const capture = new CaptureStore();
