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

// ── IndexedDB helpers ────────────────────────────────────────────────────────

const DB_NAME = 'aust_capture_v1';
const STORE_ITEMS = 'items';
const STORE_META = 'meta';

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      req.result.createObjectStore(STORE_ITEMS, { keyPath: 'id' });
      req.result.createObjectStore(STORE_META);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function dbPut(storeName: string, value: unknown, key?: IDBValidKey): Promise<void> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(storeName, 'readwrite');
    const store = tx.objectStore(storeName);
    const req = key !== undefined ? store.put(value, key) : store.put(value);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

async function dbDelete(storeName: string, key: IDBValidKey): Promise<void> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(storeName, 'readwrite');
    const req = tx.objectStore(storeName).delete(key);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

async function dbGetAll<T>(storeName: string): Promise<T[]> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const req = db.transaction(storeName, 'readonly').objectStore(storeName).getAll();
    req.onsuccess = () => resolve(req.result as T[]);
    req.onerror = () => reject(req.error);
  });
}

async function dbGet<T>(storeName: string, key: IDBValidKey): Promise<T | undefined> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const req = db.transaction(storeName, 'readonly').objectStore(storeName).get(key);
    req.onsuccess = () => resolve(req.result as T | undefined);
    req.onerror = () => reject(req.error);
  });
}

async function dbClearStore(storeName: string): Promise<void> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const req = db.transaction(storeName, 'readwrite').objectStore(storeName).clear();
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

// ── Image compression ────────────────────────────────────────────────────────

const MAX_WIDTH = 800;
const JPEG_QUALITY = 0.75;

function compressFrame(base64: string, mime: 'image/jpeg' | 'image/png'): Promise<string> {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, MAX_WIDTH / img.width);
      const w = Math.round(img.width * scale);
      const h = Math.round(img.height * scale);
      const canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      canvas.getContext('2d')!.drawImage(img, 0, 0, w, h);
      // Keep depth maps as PNG (lossless — JPEG would corrupt depth values).
      // RGB frames → JPEG for significant size reduction.
      const dataUrl = canvas.toDataURL(mime, mime === 'image/jpeg' ? JPEG_QUALITY : undefined);
      resolve(dataUrl.split(',')[1]); // strip data:…;base64, prefix
    };
    img.onerror = () => resolve(base64); // fallback: keep original
    img.src = `data:${mime};base64,${base64}`;
  });
}

// ── Store ────────────────────────────────────────────────────────────────────

class CaptureStore {
  items: StoredItem[] = $state([]);
  intrinsics: CameraIntrinsics | null = $state(null);
  /** True once the initial restore from IndexedDB has completed. */
  ready: boolean = $state(false);

  private _readyPromise: Promise<void>;
  private _resolveReady!: () => void;

  constructor() {
    this._readyPromise = new Promise(res => { this._resolveReady = res; });
    this._restore();
  }

  /** Resolves when IndexedDB restore is complete (use in onMount before checking items). */
  waitReady(): Promise<void> {
    return this._readyPromise;
  }

  private async _restore() {
    try {
      const stored = await dbGetAll<StoredItem>(STORE_ITEMS);
      const meta = await dbGet<CameraIntrinsics>(STORE_META, 'intrinsics');
      this.items = stored;
      this.intrinsics = meta ?? null;
    } catch {
      // First run or private browsing — silently ignore.
    }
    this.ready = true;
    this._resolveReady();
  }

  async addItem(raw: ItemScan): Promise<void> {
    const frames = await Promise.all(
      raw.frames.map(async f => ({
        imageBase64: await compressFrame(f.imageBase64, 'image/jpeg'),
        depthMapBase64: f.depthMapBase64
          ? await compressFrame(f.depthMapBase64, 'image/png')
          : null,
        pose: f.pose ?? null,
      }))
    );

    const item: StoredItem = {
      id: crypto.randomUUID(),
      label: raw.label,
      frames,
      arcDegrees: raw.arcDegrees,
      hasDepth: raw.hasDepth,
    };

    this.items.push(item);
    dbPut(STORE_ITEMS, item).catch(() => {}); // fire-and-forget
  }

  removeItem(id: string) {
    this.items = this.items.filter(i => i.id !== id);
    dbDelete(STORE_ITEMS, id).catch(() => {});
  }

  clear() {
    this.items = [];
    this.intrinsics = null;
    dbClearStore(STORE_ITEMS).catch(() => {});
    dbClearStore(STORE_META).catch(() => {});
  }

  async setIntrinsics(v: CameraIntrinsics | null) {
    this.intrinsics = v;
    if (v) {
      dbPut(STORE_META, v, 'intrinsics').catch(() => {});
    } else {
      dbDelete(STORE_META, 'intrinsics').catch(() => {});
    }
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
