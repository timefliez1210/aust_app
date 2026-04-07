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
    // Fallback: if canvas/image loading hangs (e.g. WebView not yet fully active),
    // resolve with the original base64 after 4 seconds so the caller is never stuck.
    const timeout = setTimeout(() => resolve(base64), 4000);

    const img = new Image();
    img.onload = () => {
      clearTimeout(timeout);
      try {
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
      } catch {
        resolve(base64); // canvas failed — keep original
      }
    };
    img.onerror = () => { clearTimeout(timeout); resolve(base64); };
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

  addItem(raw: ItemScan): void {
    // Push raw frames into memory immediately — this is synchronous so navigation
    // (goto) is never blocked. Compression + IDB persist happen in the background.
    const item: StoredItem = {
      id: crypto.randomUUID(),
      label: raw.label,
      frames: raw.frames.map(f => ({
        imageBase64: f.imageBase64,
        depthMapBase64: f.depthMapBase64 ?? null,
        pose: f.pose ?? null,
      })),
      arcDegrees: raw.arcDegrees,
      hasDepth: raw.hasDepth,
    };

    this.items.push(item);

    // Background: compress then persist to IDB. Does not block the caller.
    this._compressAndPersist(item);
  }

  private async _compressAndPersist(item: StoredItem): Promise<void> {
    try {
      const compressed: StoredItem = {
        ...item,
        frames: await Promise.all(
          item.frames.map(async f => ({
            ...f,
            imageBase64: await compressFrame(f.imageBase64, 'image/jpeg'),
            depthMapBase64: f.depthMapBase64
              ? await compressFrame(f.depthMapBase64, 'image/png')
              : null,
          }))
        ),
      };
      // Also update in-memory frames with compressed versions to reduce RAM.
      const idx = this.items.findIndex(i => i.id === item.id);
      if (idx !== -1) this.items[idx] = compressed;

      await dbPut(STORE_ITEMS, compressed);
    } catch {
      // Compression or IDB failed — item remains in memory with raw frames.
      dbPut(STORE_ITEMS, item).catch(() => {});
    }
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

  /** Persist the current intrinsics value to IDB (fire-and-forget). */
  persistIntrinsics() {
    if (this.intrinsics) {
      dbPut(STORE_META, this.intrinsics, 'intrinsics').catch(() => {});
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
