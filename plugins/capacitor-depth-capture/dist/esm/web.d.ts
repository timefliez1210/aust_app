import { WebPlugin } from '@capacitor/core';
import type { DepthCapturePlugin, DepthSupportResult, CameraIntrinsics, ItemScan, ArcProgress, ItemSavedEvent, DrawnBox, Detection } from './definitions';
/**
 * Web fallback. Uses getUserMedia — no AR, no YOLO, no depth.
 * Simulates the event-based API so the scan page can run in a browser for dev.
 */
export declare class DepthCaptureWeb extends WebPlugin implements DepthCapturePlugin {
    private stream;
    private video;
    private items;
    private sessionIntrinsics;
    checkSupport(): Promise<DepthSupportResult>;
    startSession(): Promise<void>;
    stopSession(): Promise<void>;
    startItemScan(options: {
        label: string;
    }): Promise<void>;
    cancelItemScan(): Promise<void>;
    setDrawMode(_options: {
        enabled: boolean;
    }): Promise<void>;
    getIntrinsics(): Promise<CameraIntrinsics>;
    getAllItems(): Promise<{
        items: ItemScan[];
    }>;
    clearItems(): Promise<void>;
    addListener(event: 'detections', handler: (data: {
        detections: Detection[];
    }) => void): any;
    addListener(event: 'arcProgress', handler: (data: ArcProgress) => void): any;
    addListener(event: 'itemSaved', handler: (data: ItemSavedEvent) => void): any;
    addListener(event: 'boxDrawn', handler: (data: DrawnBox) => void): any;
    private _captureWebFrame;
}
