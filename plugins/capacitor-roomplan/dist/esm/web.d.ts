import { WebPlugin } from '@capacitor/core';
import type { RoomPlanPlugin, RoomScanResult } from './definitions';
/**
 * Web / Android: RoomPlan doesn't exist, so the app falls back to manual entry.
 *
 * For working on the review screen in a browser, set
 * `localStorage.setItem('roomplan-demo', '1')`: `isSupported` then reports true
 * and `scanRoom` returns a fixed living room.
 */
export declare class RoomPlanWeb extends WebPlugin implements RoomPlanPlugin {
    isSupported(): Promise<{
        supported: boolean;
    }>;
    scanRoom(_options: {
        roomName: string;
    }): Promise<RoomScanResult>;
}
