import { BOX_VOLUME_M3, MAX_ITEM_M3, MIN_ITEM_M3 } from '$lib/plugins/roomplan';

export interface CameraIntrinsics {
  fx: number;
  fy: number;
  cx: number;
  cy: number;
  width: number;
  height: number;
}

export interface StoredItem {
  id: string;
  /** Possibly empty — the backend names unlabelled items from their photo. */
  label: string;
  /** 'scan' items come from RoomPlan and are replaced by a rescan; 'manual' ones never are. */
  source: 'scan' | 'manual';
  frames: {
    imageBase64: string;
    depthMapBase64: string | null;
    pose: number[] | null;
  }[];
  hasDepth: boolean;
  /**
   * Volume in m³ incl. packing factor — measured by RoomPlan or entered by hand.
   * null when neither happened and the backend has to estimate from photos.
   */
  volumeM3: number | null;
  /** Dims [length, width, height] in metres: RoomPlan's box, or typed measurements. */
  dimsM: number[] | null;
  deviceConfidence: number | null;
  /**
   * Where the item stands, for the room's floor plan: footprint corners [[x, z] × 4]
   * in the scan's frame. One for a scanned object, several for a "Kleinteile"
   * line, absent for anything added by hand.
   */
  footprints?: number[][][];
}

export type NewItem = Omit<StoredItem, 'id'>;

export interface Room {
  id: string;
  name: string;
  items: StoredItem[];
  /** Whether a RoomPlan scan has run for this room. */
  scanned: boolean;
  /** Floor plan from the last scan: walls as end-point pairs, fixtures as footprints. */
  plan?: RoomSketchPlan;
  /** What the last scan's leftover measurement saw — shown while testing. */
  diagnostics?: Record<string, unknown>;
}

export interface RoomSketchPlan {
  walls: number[][][];
  fixtures: number[][][];
}

/** Most boxes the backend accepts as one item (12 m³ per-item limit). */
export const MAX_BOXES = Math.floor(MAX_ITEM_M3 / BOX_VOLUME_M3);

class CaptureStore {
  rooms: Room[] = $state([]);
  /** Umzugskartons for the whole home — sent as one item. */
  boxes = $state(0);
  intrinsics: CameraIntrinsics | null = $state(null);

  addRoom(name: string): Room {
    this.rooms.push({ id: crypto.randomUUID(), name: this.uniqueName(name), items: [], scanned: false });
    return this.rooms[this.rooms.length - 1];
  }

  renameRoom(roomId: string, name: string) {
    const room = this.room(roomId);
    if (room) room.name = this.uniqueName(name, roomId);
  }

  removeRoom(roomId: string) {
    this.rooms = this.rooms.filter(r => r.id !== roomId);
  }

  /** A (re)scan replaces the room's scanned items and keeps everything added by hand. */
  applyScan(roomId: string, items: NewItem[], plan?: RoomSketchPlan, diagnostics?: Record<string, unknown>) {
    const room = this.room(roomId);
    if (!room) return;
    room.plan = plan;
    room.diagnostics = diagnostics;
    room.items = [
      ...items.map(i => ({ id: crypto.randomUUID(), ...i })),
      ...room.items.filter(i => i.source === 'manual'),
    ];
    room.scanned = true;
  }

  addItem(roomId: string, item: NewItem) {
    this.room(roomId)?.items.push({ id: crypto.randomUUID(), ...item });
  }

  updateItem(roomId: string, itemId: string, patch: Partial<NewItem>) {
    const item = this.room(roomId)?.items.find(i => i.id === itemId);
    if (item) Object.assign(item, patch);
  }

  removeItem(roomId: string, itemId: string) {
    const room = this.room(roomId);
    if (room) room.items = room.items.filter(i => i.id !== itemId);
  }

  clear() {
    this.rooms = [];
    this.boxes = 0;
    this.intrinsics = null;
  }

  /** Kept for the home screen; capture state is in memory only. */
  waitReady(): Promise<void> { return Promise.resolve(); }

  /** Everything to submit, flattened across rooms, with the boxes as one last item. */
  get items(): StoredItem[] {
    const items = this.rooms.flatMap(r => r.items);
    if (this.boxes > 0) {
      items.push({
        id: 'boxes',
        label: `${this.boxes} Umzugskartons`,
        source: 'manual',
        frames: [],
        hasDepth: false,
        volumeM3: this.boxes * BOX_VOLUME_M3,
        dimsM: null,
        deviceConfidence: null,
      });
    }
    return items;
  }

  get itemCount() { return this.items.length; }

  /** Sum of known volumes — what the review screen shows as the running total. */
  get knownVolumeM3() {
    return this.items.reduce((sum, i) => sum + (i.volumeM3 ?? 0), 0);
  }

  /** Sum of on-device volumes, or null unless every item has one. */
  get deviceVolumeM3(): number | null {
    const items = this.items;
    if (items.length === 0 || items.some(i => i.volumeM3 == null)) return null;
    return items.reduce((sum, i) => sum + (i.volumeM3 ?? 0), 0);
  }

  /** Items the backend would reject: a volume outside its range, or neither volume nor photo. */
  get invalidItemIds(): Set<string> {
    return new Set(this.items.filter(i => !isSubmittable(i)).map(i => i.id));
  }

  private room(roomId: string) {
    return this.rooms.find(r => r.id === roomId);
  }

  /** "Schlafzimmer" twice becomes "Schlafzimmer 2". */
  private uniqueName(name: string, exceptRoomId?: string) {
    const base = name.trim() || 'Raum';
    const taken = new Set(this.rooms.filter(r => r.id !== exceptRoomId).map(r => r.name));
    if (!taken.has(base)) return base;
    let n = 2;
    while (taken.has(`${base} ${n}`)) n++;
    return `${base} ${n}`;
  }
}

export function isSubmittable(item: StoredItem): boolean {
  if (item.volumeM3 == null) return item.frames.length > 0;
  return item.volumeM3 >= MIN_ITEM_M3 && item.volumeM3 <= MAX_ITEM_M3;
}

export const capture = new CaptureStore();
