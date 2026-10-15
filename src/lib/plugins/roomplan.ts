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

/**
 * Measured leftovers smaller than this (loading volume) aren't listed one by
 * one: toys, shoes, a vase. They go into moving boxes, so a scan sums them into
 * one "Kleinteile" line counted in boxes.
 */
export const SMALL_ITEM_M3 = 0.05;

/** Shows each room's scan diagnostics under its card. For TestFlight builds only. */
export const SCAN_DEBUG = true;

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

export interface MovableObject {
  /** '' for objects RoomPlan has no category for — the backend names them from the photo. */
  label: string;
  dimsM: number[];
  volumeM3: number;
  confidence: number;
  imageBase64: string | null;
  footprint: number[][] | null;
}

/**
 * Movable objects from a scan, named and with their loading volume, plus the
 * small leftovers as a count and the boxes they fill.
 */
export function movableObjects(objects: ScannedObject[]) {
  const items: MovableObject[] = [];
  const fixtures: number[][][] = [];
  const smallFootprints: number[][][] = [];
  let smallCount = 0;
  let smallVolumeM3 = 0;
  for (const o of objects) {
    if (FIXTURES.has(o.category)) {
      if (o.footprint) fixtures.push(o.footprint);
      continue;
    }
    const volumeM3 = boxVolume(o.dimsM);
    if (o.category === 'other' && volumeM3 < SMALL_ITEM_M3) {
      smallCount++;
      smallVolumeM3 += volumeM3;
      if (o.footprint) smallFootprints.push(o.footprint);
      continue;
    }
    items.push({
      label: CATEGORY_LABELS[o.category] ?? '',
      dimsM: [...o.dimsM],
      volumeM3,
      confidence: o.confidence,
      imageBase64: o.imageBase64 ?? null,
      footprint: o.footprint ?? null,
    });
  }
  return {
    items,
    fixtures,
    small: {
      count: smallCount,
      boxes: smallCount > 0 ? Math.max(1, Math.ceil(smallVolumeM3 / BOX_VOLUME_M3)) : 0,
      footprints: smallFootprints,
    },
  };
}
