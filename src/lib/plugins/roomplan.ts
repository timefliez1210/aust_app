import { Capacitor, registerPlugin } from '@capacitor/core';
import type { RoomPlanPlugin, ScannedObject } from 'capacitor-roomplan';

export type { RoomScanResult, ScannedObject } from 'capacitor-roomplan';

export const RoomPlan = registerPlugin<RoomPlanPlugin>('RoomPlan', {
  web: () => import('capacitor-roomplan').then(m => new m.RoomPlanWeb()),
});

/**
 * Loading volume includes handling space around each piece. Same factor the
 * previous capture applied, so offer pricing stays calibrated.
 */
export const PACKING_FACTOR = 1.2;

/** One standard Umzugskarton, as moving inventories count it. */
export const BOX_VOLUME_M3 = 0.1;

/** The backend rejects per-item device volumes outside this range. */
export const MIN_ITEM_M3 = 0.005;
export const MAX_ITEM_M3 = 12;

/** RoomPlan category → German item name. Fixtures that don't move are absent. */
const CATEGORY_LABELS: Record<string, string> = {
  storage: 'Schrank / Regal',
  refrigerator: 'Kühlschrank',
  stove: 'Herd',
  bed: 'Bett',
  washerDryer: 'Waschmaschine / Trockner',
  oven: 'Backofen',
  dishwasher: 'Geschirrspüler',
  table: 'Tisch',
  sofa: 'Sofa',
  chair: 'Stuhl',
  television: 'Fernseher',
};

/** Built into the flat — scanned, but never part of a move. */
const FIXTURES = new Set(['sink', 'toilet', 'bathtub', 'fireplace', 'stairs']);

/** Whether this device can run a RoomPlan scan (iOS 16+ with LiDAR). */
export async function canScanRooms(): Promise<boolean> {
  if (Capacitor.getPlatform() === 'android') return false;
  try {
    return (await RoomPlan.isSupported()).supported;
  } catch {
    return false;
  }
}

export function boxVolume(dimsM: number[]): number {
  return dimsM[0] * dimsM[1] * dimsM[2] * PACKING_FACTOR;
}

/** Movable objects from a scan, named and with their loading volume. */
export function movableObjects(objects: ScannedObject[]) {
  return objects
    .filter(o => !FIXTURES.has(o.category))
    .map(o => ({
      label: CATEGORY_LABELS[o.category] ?? '',
      dimsM: [...o.dimsM],
      volumeM3: boxVolume(o.dimsM),
      confidence: o.confidence,
    }));
}
