import { WebPlugin } from '@capacitor/core';
import type { PluginListenerHandle } from '@capacitor/core';
import type { DepthCapturePlugin, DepthSupportResult, CameraIntrinsics, ItemScan, ItemSavedEvent } from './definitions';
/**
 * Web fallback. Uses getUserMedia — no AR, no YOLO, no depth.
 * Simulates the native session flow so the scan page runs in a browser for dev.
 */
export declare class DepthCaptureWeb extends WebPlugin implements DepthCapturePlugin {
    private stream;
    private video;
    private items;
    checkSupport(): Promise<DepthSupportResult>;
    startSession(): Promise<void>;
    stopSession(): Promise<void>;
    getIntrinsics(): Promise<CameraIntrinsics>;
    getAllItems(): Promise<{
        items: ItemScan[];
    }>;
    clearItems(): Promise<void>;
    addListener(event: 'itemSaved', handler: (data: ItemSavedEvent) => void): Promise<PluginListenerHandle>;
    addListener(event: 'sessionComplete', handler: (data: {
        itemCount: number;
    }) => void): Promise<PluginListenerHandle>;
    addListener(event: 'sessionCancelled', handler: (data: Record<string, never>) => void): Promise<PluginListenerHandle>;
    /** Simulate capturing one item (call from browser devtools for testing). */
    simulateCapture(label: string): Promise<void>;
    private _captureFrame;
}
