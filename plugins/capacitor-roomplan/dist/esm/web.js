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
                { category: 'sofa', dimsM: [2.24, 0.95, 0.86], confidence: 0.9, footprint: rect(0.2, 0.2, 2.24, 0.95) },
                { category: 'table', dimsM: [1.2, 0.6, 0.45], confidence: 0.9, footprint: rect(0.7, 1.6, 1.2, 0.6) },
                { category: 'storage', dimsM: [1.8, 0.42, 2.0], confidence: 0.6, footprint: rect(2.0, 3.5, 1.8, 0.42) },
                { category: 'television', dimsM: [1.45, 0.08, 0.84], confidence: 0.6, footprint: rect(0.6, 3.82, 1.45, 0.08) },
                { category: 'chair', dimsM: [0.62, 0.58, 0.9], confidence: 0.3, footprint: rect(3.2, 1.2, 0.62, 0.58) },
                { category: 'other', dimsM: [0.62, 0.55, 0.52], confidence: 0.3, footprint: rect(3.0, 2.4, 0.62, 0.55) },
                { category: 'other', dimsM: [0.45, 0.3, 1.6], confidence: 0.3, footprint: rect(3.4, 0.2, 0.45, 0.3) },
                { category: 'other', dimsM: [0.3, 0.22, 0.25], confidence: 0.3, footprint: rect(1.5, 2.6, 0.3, 0.22) },
                { category: 'other', dimsM: [0.25, 0.2, 0.12], confidence: 0.3, footprint: rect(2.2, 2.7, 0.25, 0.2) },
                { category: 'other', dimsM: [0.4, 0.3, 0.2], confidence: 0.3, footprint: rect(0.3, 2.8, 0.4, 0.3) },
            ],
            walls: [
                [[0, 0], [4, 0]],
                [[4, 0], [4, 4]],
                [[4, 4], [0, 4]],
                [[0, 4], [0, 0]],
            ],
            diagnostics: { source: 'demo', points: 41200, kept: 3100, clusters: 9, leftovers: 5, photos: 0, keyframes: 0, rejected: { hanging: 1 } },
        };
    }
}
/** Axis-aligned footprint with its corner at (x, z). */
function rect(x, z, w, d) {
    return [[x, z], [x + w, z], [x + w, z + d], [x, z + d]];
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