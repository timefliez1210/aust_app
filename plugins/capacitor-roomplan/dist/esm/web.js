import { WebPlugin } from '@capacitor/core';
const DEMO_KEY = 'roomplan-demo';
/**
 * Web / Android: RoomPlan doesn't exist, so the app falls back to manual entry.
 *
 * For working on the review screen in a browser, set
 * `localStorage.setItem('roomplan-demo', '1')`: `isSupported` then reports true
 * and `scanRoom` returns a fixed living room.
 */
export class RoomPlanWeb extends WebPlugin {
    async isSupported() {
        return { supported: demoEnabled() };
    }
    async scanRoom(_options) {
        if (!demoEnabled())
            throw this.unavailable('RoomPlan is only available on iOS with LiDAR.');
        return {
            cancelled: false,
            objects: [
                { category: 'sofa', dimsM: [2.24, 0.95, 0.86], confidence: 0.9 },
                { category: 'table', dimsM: [1.2, 0.6, 0.45], confidence: 0.9 },
                { category: 'storage', dimsM: [1.8, 0.42, 2.0], confidence: 0.6 },
                { category: 'television', dimsM: [1.45, 0.08, 0.84], confidence: 0.6 },
                { category: 'chair', dimsM: [0.62, 0.58, 0.9], confidence: 0.3 },
            ],
        };
    }
}
function demoEnabled() {
    try {
        return localStorage.getItem(DEMO_KEY) === '1';
    }
    catch {
        return false;
    }
}
//# sourceMappingURL=web.js.map