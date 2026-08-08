import Foundation
import Capacitor
import ARKit
import AVFoundation
import Vision
import UIKit
import simd
import CoreImage

// MARK: - Data models

private struct ItemFrame {
    let imageBase64: String
    let depthMapBase64: String?
    let pose: [Float]
}

private struct SavedItem {
    /// Customer-supplied name. **May be empty** — the measurement is what the
    /// submission is about, and the backend names unlabelled items from their
    /// photo. Never block a saved volume on a missing name.
    var label: String
    let frames: [ItemFrame]
    let arcDegrees: Float
    let hasDepth: Bool
    /// On-device volume estimate in m³ (LiDAR only, incl. packing factor). nil when
    /// depth segmentation failed — the backend falls back to server-side estimation.
    let volumeM3: Float?
    /// Gravity-aligned OBB dimensions [length, width, height] in metres.
    let dims: simd_float3?
    /// Heuristic confidence [0, 1] for the on-device measurement.
    let deviceConfidence: Float?
}

// MARK: - DetectionBox

private struct DetectionBox {
    let label: String
    let germanLabel: String
    let confidence: Float
    let x: Float
    let y: Float
    let w: Float
    let h: Float
}

// MARK: - VolumeAccumulator
//
// On-device volume estimation for LiDAR devices. Per captured frame, the object
// the user is orbiting (kept centered during the arc sweep) is segmented out of
// the depth map by region-growing from the frame center; segment pixels are
// back-projected through the camera intrinsics and pose into world space. At
// finalize, the fused cloud is trimmed (2–98 percentile per axis) and measured
// with a gravity-aligned oriented bounding box (ARKit world: -Y is gravity).
private final class VolumeAccumulator {

    /// Subsample stride over the 256×192 depth grid.
    private static let stride = 2
    /// Depth continuity threshold for region growing: max(4 cm, 2% of depth).
    private static let depthJump: Float = 0.04
    /// Points farther than this from the seed are never part of one furniture item.
    private static let maxRadiusFromSeed: Float = 2.5
    /// A flood that swallows this fraction of the grid hit the walls/floor — discard frame.
    private static let maxRegionFraction = 0.45
    /// Loading volume includes handling space around the raw geometric OBB.
    private static let packingFactor: Float = 1.2

    private var worldPoints: [simd_float3] = []
    private(set) var framesUsed = 0

    /// Segment the centered object in one depth frame and fuse its points into
    /// the world-space cloud. `intrinsics` and `imageSize` describe the RGB
    /// image the depth map is registered to.
    func ingest(depthMap: CVPixelBuffer,
                intrinsics k: simd_float3x3,
                imageSize: CGSize,
                cameraTransform: simd_float4x4) {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let rowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let ptr = base.bindMemory(to: Float32.self, capacity: rowStride * h)

        // Intrinsics are for the full RGB resolution — rescale to the depth grid.
        let sx = Float(w) / Float(imageSize.width)
        let sy = Float(h) / Float(imageSize.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy
        let cx = k[2][0] * sx, cy = k[2][1] * sy
        guard fx > 0, fy > 0 else { return }

        let s = Self.stride
        let gw = w / s, gh = h / s
        func depthAt(_ gx: Int, _ gy: Int) -> Float {
            ptr[(gy * s) * rowStride + gx * s]
        }

        // Seed: median depth of the central window.
        var centerDepths: [Float] = []
        let half = 7
        for gy in max(0, gh / 2 - half)...min(gh - 1, gh / 2 + half) {
            for gx in max(0, gw / 2 - half)...min(gw - 1, gw / 2 + half) {
                let d = depthAt(gx, gy)
                if d.isFinite && d > 0.2 && d < 6.0 { centerDepths.append(d) }
            }
        }
        guard centerDepths.count >= 20 else { return }
        centerDepths.sort()
        let seedDepth = centerDepths[centerDepths.count / 2]

        func backProject(_ gx: Int, _ gy: Int, _ d: Float) -> simd_float3 {
            let u = Float(gx * s), v = Float(gy * s)
            let xc = (u - cx) * d / fx
            let yc = -(v - cy) * d / fy
            let cam = simd_float4(xc, yc, -d, 1)
            let world = cameraTransform * cam
            return simd_float3(world.x, world.y, world.z)
        }

        // Region-grow (BFS, 4-neighbor) from the seed across depth-continuous pixels.
        var visited = [Bool](repeating: false, count: gw * gh)
        var region: [(Int, Int, Float)] = []
        var queue: [(Int, Int, Float)] = []
        let seed = (gw / 2, gh / 2, depthAt(gw / 2, gh / 2))
        guard seed.2.isFinite, abs(seed.2 - seedDepth) < 0.3 else { return }
        let seedWorld = backProject(seed.0, seed.1, seed.2)
        queue.append(seed)
        visited[seed.1 * gw + seed.0] = true
        let maxRegion = Int(Double(gw * gh) * Self.maxRegionFraction)

        var qi = 0
        while qi < queue.count {
            let (gx, gy, d) = queue[qi]
            qi += 1
            region.append((gx, gy, d))
            if region.count > maxRegion { return }  // flooded into the room — unusable frame

            for (nx, ny) in [(gx - 1, gy), (gx + 1, gy), (gx, gy - 1), (gx, gy + 1)] {
                guard nx >= 0, nx < gw, ny >= 0, ny < gh, !visited[ny * gw + nx] else { continue }
                visited[ny * gw + nx] = true
                let nd = depthAt(nx, ny)
                guard nd.isFinite, nd > 0.2, nd < 6.0,
                      abs(nd - d) < max(Self.depthJump, 0.02 * d),
                      simd_distance(backProject(nx, ny, nd), seedWorld) < Self.maxRadiusFromSeed
                else { continue }
                queue.append((nx, ny, nd))
            }
        }
        guard region.count >= 150 else { return }  // too small to be the item

        // Fuse into the world cloud, capped per frame.
        let cap = 6000
        let keepEvery = max(1, region.count / cap)
        var added = 0
        for (i, (gx, gy, d)) in region.enumerated() where i % keepEvery == 0 {
            worldPoints.append(backProject(gx, gy, d))
            added += 1
        }
        if added > 0 { framesUsed += 1 }
    }

    /// Measure the fused cloud. Returns (loading volume m³, dims [l, w, h]) or nil.
    func finalize() -> (volume: Float, dims: simd_float3, confidence: Float)? {
        guard framesUsed >= 1, worldPoints.count >= 400 else { return nil }

        func trimmedExtent(_ values: [Float]) -> (lo: Float, hi: Float) {
            let sorted = values.sorted()
            let lo = sorted[Int(Float(sorted.count - 1) * 0.02)]
            let hi = sorted[Int(Float(sorted.count - 1) * 0.98)]
            return (lo, hi)
        }

        // Trim outliers per world axis, keeping points inside the trimmed box.
        let ex = trimmedExtent(worldPoints.map { $0.x })
        let ey = trimmedExtent(worldPoints.map { $0.y })
        let ez = trimmedExtent(worldPoints.map { $0.z })
        let pts = worldPoints.filter {
            $0.x >= ex.lo && $0.x <= ex.hi &&
            $0.y >= ey.lo && $0.y <= ey.hi &&
            $0.z >= ez.lo && $0.z <= ez.hi
        }
        guard pts.count >= 300 else { return nil }

        // Gravity-aligned OBB: height straight from Y; footprint via 2D PCA on XZ.
        let height = ey.hi - ey.lo
        let mx = pts.reduce(Float(0)) { $0 + $1.x } / Float(pts.count)
        let mz = pts.reduce(Float(0)) { $0 + $1.z } / Float(pts.count)
        var cxx: Float = 0, cxz: Float = 0, czz: Float = 0
        for p in pts {
            let dx = p.x - mx, dz = p.z - mz
            cxx += dx * dx; cxz += dx * dz; czz += dz * dz
        }
        cxx /= Float(pts.count); cxz /= Float(pts.count); czz /= Float(pts.count)
        // Principal axis angle of the 2×2 covariance matrix.
        let theta = 0.5 * atan2(2 * cxz, cxx - czz)
        let ct = cos(theta), st = sin(theta)
        let a = trimmedExtent(pts.map { ($0.x - mx) * ct + ($0.z - mz) * st })
        let b = trimmedExtent(pts.map { -($0.x - mx) * st + ($0.z - mz) * ct })
        let da = a.hi - a.lo, db = b.hi - b.lo

        let length = max(da, db), width = min(da, db)
        guard height > 0.05, length > 0.05, width > 0.02 else { return nil }

        let volume = length * width * height * Self.packingFactor
        guard volume.isFinite, volume > 0.005, volume < 12.0 else { return nil }

        // More usable frames and denser clouds → higher confidence.
        let confidence = min(0.9, 0.5 + 0.08 * Float(framesUsed) + 0.00001 * Float(pts.count))
        return (volume, simd_float3(length, width, height), confidence)
    }

    func reset() {
        worldPoints.removeAll()
        framesUsed = 0
    }
}

// MARK: - DepthCapturePlugin

@objc(DepthCapturePlugin)
public class DepthCapturePlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "DepthCapturePlugin"
    public let jsName = "DepthCapture"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "checkSupport",   returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startSession",   returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSession",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getIntrinsics",  returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAllItems",     returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearItems",     returnType: CAPPluginReturnPromise),
    ]

    // ── AR ────────────────────────────────────────────────────────────────
    private var arView: ARSCNView?
    private var frameCounter = 0
    private let yoloEveryNFrames = 10
    private var hasLidar = false
    private var sessionIntrinsics: simd_float3x3?

    // ── YOLO ──────────────────────────────────────────────────────────────
    private var visionModel: VNCoreMLModel?
    private var furnitureLabels: [String: String] = [:]
    private var currentDetections: [DetectionBox] = []
    // Reusable layer pool — avoids clear+recreate flicker every YOLO tick
    private var detectionLayerPool: [(CAShapeLayer, CATextLayer)] = []

    // ── Arc sweep ─────────────────────────────────────────────────────────
    private var scanActive = false
    /// Name proposed by YOLO when the sweep was started from a detection tap.
    /// Only a pre-fill for the review card — the user may clear it.
    private var scanSuggestedLabel = ""
    private var scanFrames: [ItemFrame] = []
    private var scanRefQuaternion: simd_quatf?
    private var scanAccumulatedDeg: Float = 0
    private var scanPrevQuaternion: simd_quatf?
    private var scanLastCapturedDeg: Float = -Float.greatestFiniteMagnitude
    private let scanVolume = VolumeAccumulator()
    private static let arcThresholdDeg: Float = 28
    private static let minFrames = 4
    /// Encode a frame every N degrees of sweep instead of every render tick —
    /// 28° yields ~8 frames instead of 100+, keeping upload size and the render
    /// loop sane.
    private static let captureEveryDeg: Float = 3.5

    /// Live volume readout during the sweep is refreshed at most this often —
    /// measuring re-sorts the whole cloud, which is too heavy for every frame.
    private static let previewEveryDeg: Float = 7
    private var scanLastPreviewDeg: Float = -Float.greatestFiniteMagnitude

    // ── Items ─────────────────────────────────────────────────────────────
    private var savedItems: [SavedItem] = []
    /// Finished sweep awaiting the user's confirmation in the review card.
    /// Nothing reaches `savedItems` until they tap "Sichern".
    private var pendingItem: SavedItem?

    // ── Native UI ─────────────────────────────────────────────────────────
    private var overlay: ScanOverlayView?

    // MARK: - Plugin methods

    @objc func checkSupport(_ call: CAPPluginCall) {
        let supported = ARWorldTrackingConfiguration.isSupported
        let lidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        call.resolve(["supported": supported, "hasLidar": lidar])
    }

    @objc func startSession(_ call: CAPPluginCall) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                call.reject("Camera permission denied")
                return
            }
            DispatchQueue.main.async {
                self.setupARView()
                self.setupNativeOverlay()
                self.loadFurnitureLabels()
                self.loadYOLOModel()
                call.resolve()
            }
        }
    }

    @objc func stopSession(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.teardownAll()
            call.resolve()
        }
    }

    @objc func getIntrinsics(_ call: CAPPluginCall) {
        guard let intrinsics = sessionIntrinsics,
              let frame = arView?.session.currentFrame else {
            call.resolve(["fx": 0, "fy": 0, "cx": 0, "cy": 0, "width": 0, "height": 0])
            return
        }
        let w = frame.camera.imageResolution.width
        let h = frame.camera.imageResolution.height
        call.resolve([
            "fx": intrinsics[0][0], "fy": intrinsics[1][1],
            "cx": intrinsics[2][0], "cy": intrinsics[2][1],
            "width": Int(w), "height": Int(h),
        ])
    }

    @objc func getAllItems(_ call: CAPPluginCall) {
        let result = savedItems.map { item -> [String: Any] in
            let frames = item.frames.map { f -> [String: Any] in
                var fd: [String: Any] = ["imageBase64": f.imageBase64, "pose": f.pose]
                fd["depthMapBase64"] = f.depthMapBase64 as Any
                return fd
            }
            var dict: [String: Any] = [
                "label": item.label, "frames": frames,
                "arcDegrees": item.arcDegrees, "hasDepth": item.hasDepth,
            ]
            if let v = item.volumeM3 { dict["volumeM3"] = v }
            if let d = item.dims { dict["dimsM"] = [d.x, d.y, d.z] }
            if let c = item.deviceConfidence { dict["deviceConfidence"] = c }
            return dict
        }
        call.resolve(["items": result])
    }

    @objc func clearItems(_ call: CAPPluginCall) {
        savedItems = []
        call.resolve()
    }

    // MARK: - AR setup / teardown

    private func setupARView() {
        guard let rootVC = bridge?.viewController,
              let window = rootVC.view.window ?? UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }

        hasLidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

        let sceneView = ARSCNView(frame: window.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.isUserInteractionEnabled = false

        // Add to window (not rootVC.view, which IS the WKWebView in Capacitor)
        window.addSubview(sceneView)
        arView = sceneView

        // Hide WebView entirely — native UI takes over
        bridge?.webView?.isHidden = true

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = []
        if hasLidar { config.frameSemantics = .sceneDepth }
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func setupNativeOverlay() {
        guard let arView = arView,
              let window = arView.superview else { return }

        let ov = ScanOverlayView(frame: window.bounds)
        ov.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Wire callbacks
        ov.onClose = { [weak self] in
            self?.teardownAll()
            self?.notifyListeners("sessionCancelled", data: [:])
        }
        ov.onFinish = { [weak self] in
            guard let self else { return }
            self.notifyListeners("sessionComplete", data: ["itemCount": self.savedItems.count])
        }
        // Tapping a detection is a shortcut, not a gate: it starts the same
        // measurement and only pre-fills the name.
        ov.onDetectionTapped = { [weak self] box in
            self?.beginArcSweep(suggestedLabel: box.germanLabel.isEmpty ? box.label : box.germanLabel)
        }
        ov.onMeasureRequested = { [weak self] in
            self?.beginArcSweep(suggestedLabel: "")
        }
        ov.onCancelArc = { [weak self] in
            self?.abortScan()
        }
        ov.onSaveItem = { [weak self] label in
            self?.commitPendingItem(label: label)
        }
        ov.onRemeasure = { [weak self] in
            guard let self else { return }
            let suggestion = self.pendingItem?.label ?? ""
            self.pendingItem = nil
            self.beginArcSweep(suggestedLabel: suggestion)
        }

        window.addSubview(ov)
        overlay = ov
    }

    private func teardownAll() {
        overlay?.removeFromSuperview()
        overlay = nil
        arView?.session.pause()
        arView?.removeFromSuperview()
        arView = nil
        clearDetectionLayers()
        scanActive = false
        bridge?.webView?.isHidden = false
    }

    // MARK: - Arc sweep

    private func beginArcSweep(suggestedLabel: String) {
        scanSuggestedLabel = suggestedLabel
        scanFrames = []
        scanRefQuaternion = nil
        scanPrevQuaternion = nil
        scanAccumulatedDeg = 0
        scanLastCapturedDeg = -Float.greatestFiniteMagnitude
        scanLastPreviewDeg = -Float.greatestFiniteMagnitude
        scanVolume.reset()
        scanActive = true
        clearDetectionLayers()
        DispatchQueue.main.async { [weak self] in
            self?.overlay?.setState(.arcSweep)
        }
    }

    private func abortScan() {
        scanActive = false
        scanFrames = []
        scanVolume.reset()
        pendingItem = nil
        overlay?.setState(.idle)
    }

    private func processArcFrame(_ frame: ARFrame) {
        guard scanActive else { return }
        let currentQuat = simd_quatf(frame.camera.transform)

        if scanRefQuaternion == nil {
            scanRefQuaternion = currentQuat
            scanPrevQuaternion = currentQuat
        }

        if let prev = scanPrevQuaternion {
            let delta = quaternionAngularDistance(prev, currentQuat)
            scanAccumulatedDeg += delta
            scanPrevQuaternion = currentQuat
            let dir = dominantDirection(from: prev, to: currentQuat)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.overlay?.updateArc(degrees: self.scanAccumulatedDeg, direction: dir)
            }
        }

        // Encode + fuse only every ~3.5° of sweep; encoding every render tick
        // stutters the render loop and balloons the upload.
        if scanAccumulatedDeg - scanLastCapturedDeg >= Self.captureEveryDeg || scanFrames.isEmpty {
            scanLastCapturedDeg = scanAccumulatedDeg
            let imageBase64 = pixelBufferToJPEGBase64(frame.capturedImage)
            var depthBase64: String?
            if hasLidar, let dm = frame.sceneDepth?.depthMap {
                depthBase64 = depthMapToBase64PNG(dm)
                scanVolume.ingest(depthMap: dm,
                                  intrinsics: frame.camera.intrinsics,
                                  imageSize: frame.camera.imageResolution,
                                  cameraTransform: frame.camera.transform)
            }
            scanFrames.append(ItemFrame(imageBase64: imageBase64, depthMapBase64: depthBase64,
                                        pose: transformToFloatArray(frame.camera.transform)))

            // Live readout: the measurement is the point of the sweep, so show it
            // growing rather than only degrees. Measuring re-sorts the cloud —
            // keep it to every few degrees.
            if hasLidar, scanAccumulatedDeg - scanLastPreviewDeg >= Self.previewEveryDeg {
                scanLastPreviewDeg = scanAccumulatedDeg
                let preview = scanVolume.finalize()?.volume
                DispatchQueue.main.async { [weak self] in
                    self?.overlay?.updateLiveVolume(preview)
                }
            }
        }

        if scanAccumulatedDeg >= Self.arcThresholdDeg && scanFrames.count >= Self.minFrames {
            finalizeScan()
        }
    }

    /// End the sweep and hand the measurement to the review card. Nothing is
    /// saved yet — the user confirms (and optionally names) it there.
    private func finalizeScan() {
        scanActive = false
        let measured = scanVolume.finalize()
        pendingItem = SavedItem(label: scanSuggestedLabel, frames: scanFrames,
                                arcDegrees: scanAccumulatedDeg,
                                hasDepth: scanFrames.contains { $0.depthMapBase64 != nil },
                                volumeM3: measured?.volume,
                                dims: measured?.dims,
                                deviceConfidence: measured?.confidence)
        // Unpack the OBB here: `measured?.dims.map { … }` would chain onto the
        // unwrapped simd_float3 (whose `map` hands out Floats), not the Optional.
        let dimsArray: [Float]? = measured.map { [$0.dims.x, $0.dims.y, $0.dims.z] }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlay?.showReview(volumeM3: measured?.volume,
                                     dims: dimsArray,
                                     suggestedLabel: self.scanSuggestedLabel,
                                     measurable: self.hasLidar)
        }
    }

    /// Save the reviewed item. `label` may be empty — the backend names it from
    /// the photo, so a blank name never costs a measurement.
    private func commitPendingItem(label: String) {
        guard var item = pendingItem else { return }
        item.label = label.trimmingCharacters(in: .whitespaces)
        pendingItem = nil
        savedItems.append(item)

        var eventData: [String: Any] = [
            "label": item.label, "frameCount": item.frames.count,
            "arcDegrees": item.arcDegrees, "hasDepth": item.hasDepth,
        ]
        if let v = item.volumeM3 { eventData["volumeM3"] = v }
        notifyListeners("itemSaved", data: eventData)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlay?.updateItemCount(self.savedItems.count)
            self.overlay?.showSavedFlash(label: item.label, volumeM3: item.volumeM3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.overlay?.setState(.idle)
            }
        }
    }

    // MARK: - YOLO

    private func loadYOLOModel() {
        let names = ["yolo11n", "YOLOv11n", "yolov8n", "YOLOv8n"]
        let bundles = [Bundle.module, Bundle.main]
        var modelURL: URL?
        for name in names {
            for bundle in bundles {
                if let url = bundle.url(forResource: name, withExtension: "mlmodelc")
                          ?? bundle.url(forResource: name, withExtension: "mlpackage") {
                    modelURL = url; break
                }
            }
            if modelURL != nil { break }
        }
        guard let url = modelURL else {
            print("[DepthCapture] YOLO model not found — detection disabled"); return
        }
        do {
            visionModel = try VNCoreMLModel(for: MLModel(contentsOf: url))
            print("[DepthCapture] YOLO model loaded: \(url.lastPathComponent)")
        } catch { print("[DepthCapture] Failed to load YOLO: \(error)") }
    }

    private func loadFurnitureLabels() {
        guard let url = Bundle.module.url(forResource: "furniture_labels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        furnitureLabels = map
    }

    private func runYOLO(on pixelBuffer: CVPixelBuffer) {
        guard let model = visionModel else { return }
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self, let results = req.results as? [VNRecognizedObjectObservation] else { return }
            let boxes = results.compactMap { obs -> DetectionBox? in
                // 0.35: detections are tap-to-confirm, so extra candidates are cheap
                // and misses are expensive (user has to fall back to draw mode).
                guard let top = obs.labels.first, top.confidence > 0.35 else { return nil }
                let german = self.furnitureLabels[top.identifier] ?? ""
                // Skip non-furniture items (person, handbag, etc.)
                guard !german.isEmpty else { return nil }
                let bb = obs.boundingBox
                return DetectionBox(label: top.identifier,
                                    germanLabel: german,
                                    confidence: top.confidence,
                                    x: Float(bb.minX), y: Float(1.0 - bb.maxY),
                                    w: Float(bb.width), h: Float(bb.height))
            }
            self.currentDetections = boxes
            DispatchQueue.main.async {
                self.updateDetectionLayers(boxes)
                self.overlay?.updateDetections(boxes)
            }
        }
        request.imageCropAndScaleOption = .scaleFit
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right).perform([request])
    }

    // MARK: - Detection layers on ARView

    private func updateDetectionLayers(_ boxes: [DetectionBox]) {
        guard let sceneView = arView else { return }
        let bounds = sceneView.bounds

        // Grow pool if we need more layers than we have
        while detectionLayerPool.count < boxes.count {
            let shape = CAShapeLayer()
            let text = CATextLayer()
            sceneView.layer.addSublayer(shape)
            sceneView.layer.addSublayer(text)
            detectionLayerPool.append((shape, text))
        }

        // Update all layers in one transaction — no implicit animations, no flicker
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, (shape, text)) in detectionLayerPool.enumerated() {
            if i < boxes.count {
                let box = boxes[i]
                let rect = CGRect(x: CGFloat(box.x) * bounds.width,
                                  y: CGFloat(box.y) * bounds.height,
                                  width: CGFloat(box.w) * bounds.width,
                                  height: CGFloat(box.h) * bounds.height)
                shape.path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
                shape.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
                shape.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
                shape.lineWidth = 2
                shape.isHidden = false

                text.string = "\(box.germanLabel)  \(Int(box.confidence * 100))%"
                text.fontSize = 12
                text.foregroundColor = UIColor.white.cgColor
                text.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
                text.cornerRadius = 4
                text.contentsScale = UIScreen.main.scale
                text.frame = CGRect(x: rect.minX + 6, y: rect.minY + 6,
                                    width: rect.width - 12, height: 20)
                text.isHidden = false
            } else {
                shape.isHidden = true
                text.isHidden = true
            }
        }
        CATransaction.commit()
    }

    private func clearDetectionLayers() {
        detectionLayerPool.forEach { shape, text in
            shape.removeFromSuperlayer()
            text.removeFromSuperlayer()
        }
        detectionLayerPool.removeAll()
    }

    // MARK: - Math helpers

    private func quaternionAngularDistance(_ q1: simd_quatf, _ q2: simd_quatf) -> Float {
        let dot = abs(simd_dot(q1.vector, q2.vector))
        return 2.0 * acos(min(max(dot, -1.0), 1.0)) * (180.0 / .pi)
    }

    private func dominantDirection(from q1: simd_quatf, to q2: simd_quatf) -> String {
        let axis = (q2 * q1.inverse).axis
        return abs(axis.y) > abs(axis.x) ? (axis.y > 0 ? "left" : "right") : (axis.x > 0 ? "down" : "up")
    }

    private func transformToFloatArray(_ t: simd_float4x4) -> [Float] {
        [t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
         t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
         t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
         t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w]
    }

    // MARK: - Image encoding

    private func pixelBufferToJPEGBase64(_ buf: CVPixelBuffer) -> String {
        let ci = CIImage(cvPixelBuffer: buf)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent),
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { return "" }
        return data.base64EncodedString()
    }

    private func depthMapToBase64PNG(_ depthMap: CVPixelBuffer) -> String? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let w = CVPixelBufferGetWidth(depthMap), h = CVPixelBufferGetHeight(depthMap)
        guard let src = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let ptr = src.bindMemory(to: Float32.self, capacity: w * h)
        var u16 = [UInt16](repeating: 0, count: w * h)
        for i in 0..<(w * h) { u16[i] = UInt16(clamping: Int(ptr[i] * 1000.0)) }
        guard let prov = CGDataProvider(data: Data(bytes: u16, count: w * h * 2) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 16,
                                bytesPerRow: w * 2, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: img).pngData()?.base64EncodedString()
    }
}

// MARK: - ARSCNViewDelegate

extension DepthCapturePlugin: ARSCNViewDelegate {
    public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let frame = arView?.session.currentFrame else { return }
        if sessionIntrinsics == nil { sessionIntrinsics = frame.camera.intrinsics }

        if scanActive {
            processArcFrame(frame)
        } else if pendingItem == nil {
            // Detection only runs on the idle screen — behind the review card it
            // would just flicker boxes the user can't act on.
            frameCounter += 1
            if frameCounter % yoloEveryNFrames == 0 {
                let buf = frame.capturedImage
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.runYOLO(on: buf) }
            }
        }
    }
}

// MARK: - ScanOverlayView (100% native UI)
//
// Volume-first capture UI. The screen is built around one action: put the object
// in the reticle and measure it. Detections are a shortcut that pre-fills a name;
// naming itself happens after the measurement and is optional.

private class ScanOverlayView: UIView {

    enum State { case idle, arcSweep, review, itemSaved }

    // Callbacks
    var onClose: (() -> Void)?
    var onFinish: (() -> Void)?
    var onDetectionTapped: ((DetectionBox) -> Void)?
    /// Measure whatever is in the reticle — no name required.
    var onMeasureRequested: (() -> Void)?
    var onCancelArc: (() -> Void)?
    /// Save the reviewed item under this name; empty means "let the backend name it".
    var onSaveItem: ((String) -> Void)?
    var onRemeasure: (() -> Void)?

    private var state: State = .idle
    private var detections: [DetectionBox] = []
    private var itemCount = 0

    private static let navy = UIColor(red: 2/255, green: 36/255, blue: 72/255, alpha: 1)
    private static let orange = UIColor(red: 252/255, green: 96/255, blue: 24/255, alpha: 1)

    // ── Top bar ──────────────────────────────────────────────────────────
    private let countPill = UIView()
    private let countDot = UIView()
    private let countLabel = UILabel()
    private let closeBtn = UIButton(type: .system)

    // ── Reticle ──────────────────────────────────────────────────────────
    // Segmentation seeds from the frame centre, so "what's in the middle gets
    // measured" is a hard rule of the pipeline — the UI has to say it.
    private let reticle = UIView()
    private let reticleLayer = CAShapeLayer()

    // ── Bottom bar ───────────────────────────────────────────────────────
    private let bottomBar = UIView()
    private let measureBtn = UIButton(type: .custom)
    private let measureRing = CAShapeLayer()
    private let finishBtn = UIButton(type: .system)
    private let hintLabel = UILabel()

    // ── Arc overlay ──────────────────────────────────────────────────────
    private let arcContainer = UIView()
    private let arcBgLayer = CAShapeLayer()
    private let arcProgressLayer = CAShapeLayer()
    private let arcVolumeLabel = UILabel()
    private let arcDegreesLabel = UILabel()
    private let arcDirLabel = UILabel()
    private let arcCancelBtn = UIButton(type: .system)

    // ── Review card ──────────────────────────────────────────────────────
    private let reviewCard = UIView()
    private let reviewTitle = UILabel()
    private let reviewVolume = UILabel()
    private let reviewDims = UILabel()
    private let reviewField = UITextField()
    private let reviewFieldHint = UILabel()
    private let reviewSave = UIButton(type: .system)
    private let reviewRemeasure = UIButton(type: .system)
    private var reviewKeyboardShift: CGFloat = 0

    // ── Saved flash ──────────────────────────────────────────────────────
    private let flashView = UIView()
    private let flashCheck = UILabel()
    private let flashLabel = UILabel()
    private let flashSub = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        buildTopBar()
        buildReticle()
        buildBottomBar()
        buildArcOverlay()
        buildReviewCard()
        buildFlash()
        addTapGesture()
        observeKeyboard()
        setState(.idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Build UI

    private func buildTopBar() {
        countPill.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        countPill.layer.cornerRadius = 16
        addSubview(countPill)

        countDot.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        countDot.layer.cornerRadius = 4
        countPill.addSubview(countDot)

        countLabel.text = "0 Objekte"
        countLabel.textColor = .white
        countLabel.font = .systemFont(ofSize: 12, weight: .bold)
        countPill.addSubview(countLabel)

        closeBtn.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        closeBtn.layer.cornerRadius = 20
        closeBtn.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeBtn)
    }

    private func buildReticle() {
        reticle.isUserInteractionEnabled = false
        reticleLayer.fillColor = UIColor.clear.cgColor
        reticleLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        reticleLayer.lineWidth = 3
        reticleLayer.lineCap = .round
        reticle.layer.addSublayer(reticleLayer)
        addSubview(reticle)
    }

    private func buildBottomBar() {
        bottomBar.backgroundColor = .clear
        addSubview(bottomBar)

        hintLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        hintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        hintLabel.layer.cornerRadius = 12
        hintLabel.clipsToBounds = true
        bottomBar.addSubview(hintLabel)

        // Primary action: a shutter-style measure button. Everything else on this
        // screen is secondary to it.
        measureBtn.backgroundColor = .clear
        measureBtn.setImage(UIImage(systemName: "ruler.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)), for: .normal)
        measureBtn.tintColor = Self.navy
        measureBtn.addTarget(self, action: #selector(measureTapped), for: .touchUpInside)
        measureRing.fillColor = UIColor.white.cgColor
        measureRing.strokeColor = UIColor.white.withAlphaComponent(0.45).cgColor
        measureRing.lineWidth = 4
        measureBtn.layer.insertSublayer(measureRing, at: 0)
        bottomBar.addSubview(measureBtn)

        finishBtn.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        finishBtn.layer.cornerRadius = 12
        finishBtn.setTitle("Fertig", for: .normal)
        finishBtn.setTitleColor(.white, for: .normal)
        finishBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        finishBtn.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        finishBtn.alpha = 0.4
        finishBtn.isEnabled = false
        finishBtn.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
        bottomBar.addSubview(finishBtn)
    }

    private func buildArcOverlay() {
        arcContainer.isHidden = true
        arcContainer.isUserInteractionEnabled = true
        addSubview(arcContainer)

        arcBgLayer.fillColor = UIColor.clear.cgColor
        arcBgLayer.strokeColor = UIColor.white.withAlphaComponent(0.15).cgColor
        arcBgLayer.lineWidth = 4
        arcContainer.layer.addSublayer(arcBgLayer)

        arcProgressLayer.fillColor = UIColor.clear.cgColor
        arcProgressLayer.strokeColor = UIColor.white.cgColor
        arcProgressLayer.lineWidth = 5
        arcProgressLayer.lineCap = .round
        arcProgressLayer.strokeEnd = 0
        arcContainer.layer.addSublayer(arcProgressLayer)

        // The measurement, not the sweep angle, is the headline.
        arcVolumeLabel.text = "– m³"
        arcVolumeLabel.textColor = .white
        arcVolumeLabel.font = .systemFont(ofSize: 34, weight: .bold)
        arcVolumeLabel.textAlignment = .center
        arcContainer.addSubview(arcVolumeLabel)

        arcDegreesLabel.text = "0° von 28°"
        arcDegreesLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        arcDegreesLabel.font = .systemFont(ofSize: 13)
        arcDegreesLabel.textAlignment = .center
        arcContainer.addSubview(arcDegreesLabel)

        arcDirLabel.textColor = .white
        arcDirLabel.font = .systemFont(ofSize: 14, weight: .medium)
        arcDirLabel.textAlignment = .center
        arcDirLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        arcDirLabel.layer.cornerRadius = 16
        arcDirLabel.clipsToBounds = true
        arcContainer.addSubview(arcDirLabel)

        arcCancelBtn.setTitle("Abbrechen", for: .normal)
        arcCancelBtn.setTitleColor(.white, for: .normal)
        arcCancelBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        arcCancelBtn.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        arcCancelBtn.layer.cornerRadius = 12
        arcCancelBtn.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        arcCancelBtn.addTarget(self, action: #selector(arcCancelTapped), for: .touchUpInside)
        arcContainer.addSubview(arcCancelBtn)
    }

    private func buildReviewCard() {
        reviewCard.backgroundColor = UIColor(red: 236/255, green: 238/255, blue: 240/255, alpha: 1)
        reviewCard.layer.cornerRadius = 24
        reviewCard.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        reviewCard.isHidden = true
        addSubview(reviewCard)

        reviewTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        reviewTitle.textColor = UIColor(red: 116/255, green: 119/255, blue: 127/255, alpha: 1)
        reviewCard.addSubview(reviewTitle)

        reviewVolume.font = .systemFont(ofSize: 40, weight: .bold)
        reviewVolume.textColor = Self.navy
        reviewCard.addSubview(reviewVolume)

        reviewDims.font = .systemFont(ofSize: 14, weight: .regular)
        reviewDims.textColor = UIColor(red: 116/255, green: 119/255, blue: 127/255, alpha: 1)
        reviewCard.addSubview(reviewDims)

        reviewField.placeholder = "Bezeichnung (optional)"
        reviewField.font = .systemFont(ofSize: 16)
        reviewField.backgroundColor = UIColor(red: 230/255, green: 232/255, blue: 234/255, alpha: 1)
        reviewField.layer.cornerRadius = 12
        reviewField.autocapitalizationType = .sentences
        reviewField.returnKeyType = .done
        reviewField.clearButtonMode = .whileEditing
        reviewField.delegate = self
        reviewField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        reviewField.leftViewMode = .always
        reviewCard.addSubview(reviewField)

        reviewFieldHint.text = "Ohne Bezeichnung erkennen wir das Objekt automatisch."
        reviewFieldHint.font = .systemFont(ofSize: 12)
        reviewFieldHint.textColor = UIColor(red: 142/255, green: 145/255, blue: 152/255, alpha: 1)
        reviewFieldHint.numberOfLines = 2
        reviewCard.addSubview(reviewFieldHint)

        reviewRemeasure.backgroundColor = UIColor(red: 230/255, green: 232/255, blue: 234/255, alpha: 1)
        reviewRemeasure.layer.cornerRadius = 12
        reviewRemeasure.setTitle("Erneut messen", for: .normal)
        reviewRemeasure.setTitleColor(UIColor(red: 67/255, green: 71/255, blue: 78/255, alpha: 1), for: .normal)
        reviewRemeasure.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        reviewRemeasure.addTarget(self, action: #selector(remeasureTapped), for: .touchUpInside)
        reviewCard.addSubview(reviewRemeasure)

        reviewSave.backgroundColor = Self.navy
        reviewSave.layer.cornerRadius = 12
        reviewSave.setTitle("Sichern", for: .normal)
        reviewSave.setTitleColor(.white, for: .normal)
        reviewSave.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        reviewSave.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        reviewCard.addSubview(reviewSave)
    }

    private func buildFlash() {
        flashView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        flashView.isHidden = true
        addSubview(flashView)

        flashCheck.text = "✓"
        flashCheck.font = .systemFont(ofSize: 40, weight: .bold)
        flashCheck.textColor = .white
        flashCheck.textAlignment = .center
        flashCheck.backgroundColor = UIColor(red: 34/255, green: 197/255, blue: 94/255, alpha: 1)
        flashCheck.layer.cornerRadius = 40
        flashCheck.clipsToBounds = true
        flashView.addSubview(flashCheck)

        flashLabel.textColor = .white
        flashLabel.font = .systemFont(ofSize: 22, weight: .bold)
        flashLabel.textAlignment = .center
        flashView.addSubview(flashLabel)

        flashSub.textColor = UIColor.white.withAlphaComponent(0.7)
        flashSub.font = .systemFont(ofSize: 14)
        flashSub.textAlignment = .center
        flashView.addSubview(flashSub)
    }

    private func addTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = safeAreaInsets
        let w = bounds.width

        // Top bar
        countPill.frame = CGRect(x: 20, y: safe.top + 8, width: 130, height: 32)
        countDot.frame = CGRect(x: 12, y: 12, width: 8, height: 8)
        countLabel.frame = CGRect(x: 28, y: 0, width: 96, height: 32)
        closeBtn.frame = CGRect(x: w - 60, y: safe.top + 4, width: 40, height: 40)

        // Reticle: centred square with corner brackets
        let side: CGFloat = min(w, bounds.height) * 0.6
        let cy = bounds.height / 2 - 40
        reticle.frame = CGRect(x: (w - side) / 2, y: cy - side / 2, width: side, height: side)
        reticleLayer.frame = reticle.bounds
        reticleLayer.path = cornerBracketPath(in: reticle.bounds, arm: side * 0.18, radius: 14).cgPath

        // Bottom bar
        let bbH: CGFloat = 150
        bottomBar.frame = CGRect(x: 0, y: bounds.height - bbH - safe.bottom, width: w, height: bbH)
        hintLabel.frame = CGRect(x: (w - 300) / 2, y: 8, width: 300, height: 28)
        let btn: CGFloat = 78
        measureBtn.frame = CGRect(x: (w - btn) / 2, y: 52, width: btn, height: btn)
        measureRing.frame = measureBtn.bounds
        measureRing.path = UIBezierPath(ovalIn: measureBtn.bounds.insetBy(dx: 8, dy: 8)).cgPath
        finishBtn.sizeToFit()
        finishBtn.frame = CGRect(x: w - finishBtn.frame.width - 20,
                                 y: 52 + (btn - 44) / 2,
                                 width: finishBtn.frame.width, height: 44)

        // Arc overlay
        arcContainer.frame = bounds
        let arcR: CGFloat = 120
        let acx = w / 2
        let circleRect = CGRect(x: acx - arcR, y: cy - arcR, width: arcR * 2, height: arcR * 2)
        arcBgLayer.path = UIBezierPath(ovalIn: circleRect).cgPath
        arcProgressLayer.path = UIBezierPath(arcCenter: CGPoint(x: acx, y: cy), radius: arcR,
                                             startAngle: -.pi / 2,
                                             endAngle: -.pi / 2 + 2 * .pi,
                                             clockwise: true).cgPath
        arcVolumeLabel.frame = CGRect(x: acx - 90, y: cy - 30, width: 180, height: 42)
        arcDegreesLabel.frame = CGRect(x: acx - 90, y: cy + 14, width: 180, height: 20)
        arcDirLabel.frame = CGRect(x: (w - 280) / 2, y: cy + arcR + 30, width: 280, height: 36)
        arcCancelBtn.frame = CGRect(x: (w - 140) / 2, y: bounds.height - safe.bottom - 70, width: 140, height: 48)

        // Review card
        let cardH: CGFloat = 330 + safe.bottom
        reviewCard.frame = CGRect(x: 0, y: bounds.height - cardH - reviewKeyboardShift,
                                  width: w, height: cardH)
        reviewTitle.frame = CGRect(x: 24, y: 24, width: w - 48, height: 18)
        reviewVolume.frame = CGRect(x: 24, y: 44, width: w - 48, height: 48)
        reviewDims.frame = CGRect(x: 24, y: 94, width: w - 48, height: 20)
        reviewField.frame = CGRect(x: 24, y: 130, width: w - 48, height: 48)
        reviewFieldHint.frame = CGRect(x: 24, y: 184, width: w - 48, height: 34)
        let rbY: CGFloat = 232
        let rbW = (w - 60) / 2
        reviewRemeasure.frame = CGRect(x: 24, y: rbY, width: rbW, height: 50)
        reviewSave.frame = CGRect(x: 24 + rbW + 12, y: rbY, width: rbW, height: 50)

        // Flash
        flashView.frame = bounds
        flashCheck.frame = CGRect(x: (w - 80) / 2, y: bounds.height / 2 - 80, width: 80, height: 80)
        flashLabel.frame = CGRect(x: 20, y: bounds.height / 2 + 16, width: w - 40, height: 30)
        flashSub.frame = CGRect(x: 20, y: bounds.height / 2 + 50, width: w - 40, height: 20)
    }

    /// Four corner brackets — a viewfinder frame that leaves the object visible.
    private func cornerBracketPath(in rect: CGRect, arm: CGFloat, radius: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        for (corner, sx, sy) in corners {
            path.move(to: CGPoint(x: corner.x + sx * radius, y: corner.y + sy * arm))
            path.addLine(to: CGPoint(x: corner.x + sx * radius, y: corner.y + sy * radius))
            path.addLine(to: CGPoint(x: corner.x + sx * arm, y: corner.y + sy * radius))
        }
        return path
    }

    // MARK: - State

    func setState(_ newState: State) {
        state = newState
        let idle = newState == .idle
        countPill.isHidden = false
        closeBtn.isHidden = false
        bottomBar.isHidden = !idle
        reticle.isHidden = newState == .review || newState == .itemSaved
        arcContainer.isHidden = newState != .arcSweep
        flashView.isHidden = newState != .itemSaved
        if newState != .review {
            reviewField.resignFirstResponder()
            reviewCard.isHidden = true
        }
        updateHint()
    }

    func updateDetections(_ boxes: [DetectionBox]) {
        detections = boxes
        updateHint()
    }

    func updateItemCount(_ count: Int) {
        itemCount = count
        countLabel.text = "\(count) \(count == 1 ? "Objekt" : "Objekte")"
        countDot.backgroundColor = count > 0 ? UIColor(red: 74/255, green: 222/255, blue: 128/255, alpha: 1) : UIColor.white.withAlphaComponent(0.3)
        finishBtn.isEnabled = count > 0
        finishBtn.alpha = count > 0 ? 1.0 : 0.4
        finishBtn.setTitle(count > 0 ? "Fertig (\(count))" : "Fertig", for: .normal)
        finishBtn.sizeToFit()
        setNeedsLayout()
    }

    func updateArc(degrees: Float, direction: String) {
        arcDegreesLabel.text = "\(Int(degrees))° von 28°"
        arcProgressLayer.strokeEnd = CGFloat(min(degrees / 28.0, 1.0))
        switch direction {
        case "left":  arcDirLabel.text = "  ← langsam nach links bewegen  "
        case "right": arcDirLabel.text = "  → langsam nach rechts bewegen  "
        case "up":    arcDirLabel.text = "  ↑ langsam nach oben bewegen  "
        default:      arcDirLabel.text = "  ↓ langsam nach unten bewegen  "
        }
    }

    /// Live measurement while sweeping; nil until enough depth has been fused.
    func updateLiveVolume(_ volumeM3: Float?) {
        arcVolumeLabel.text = volumeM3.map { "≈ \(Self.formatVolume($0)) m³" } ?? "– m³"
    }

    /// Present the finished measurement for confirmation. `volumeM3 == nil` means
    /// the sweep produced no usable measurement (or the device has no LiDAR) —
    /// the photos are still worth keeping, the backend estimates from them.
    func showReview(volumeM3: Float?, dims: [Float]?, suggestedLabel: String, measurable: Bool) {
        if let v = volumeM3 {
            reviewTitle.text = "GEMESSENES VOLUMEN"
            reviewVolume.text = "≈ \(Self.formatVolume(v)) m³"
            reviewVolume.textColor = Self.navy
            if let d = dims, d.count == 3 {
                reviewDims.text = "\(Self.formatCm(d[0])) × \(Self.formatCm(d[1])) × \(Self.formatCm(d[2])) cm"
            } else {
                reviewDims.text = "inkl. Ladespielraum"
            }
            reviewSave.setTitle("Sichern", for: .normal)
        } else if measurable {
            reviewTitle.text = "MESSUNG UNVOLLSTÄNDIG"
            reviewVolume.text = "Kein Volumen"
            reviewVolume.textColor = Self.orange
            reviewDims.text = "Objekt mittig im Rahmen halten und erneut messen — oder Fotos so senden."
            reviewSave.setTitle("Trotzdem sichern", for: .normal)
        } else {
            reviewTitle.text = "AUFNAHME GESPEICHERT"
            reviewVolume.text = "Fotos erfasst"
            reviewVolume.textColor = Self.navy
            reviewDims.text = "Dieses Gerät misst nicht — wir berechnen das Volumen aus den Fotos."
            reviewSave.setTitle("Sichern", for: .normal)
        }
        reviewDims.numberOfLines = 2
        reviewField.text = suggestedLabel

        state = .review
        bottomBar.isHidden = true
        arcContainer.isHidden = true
        flashView.isHidden = true
        reticle.isHidden = true
        reviewCard.isHidden = false
        reviewCard.transform = CGAffineTransform(translationX: 0, y: 340)
        UIView.animate(withDuration: 0.28) { self.reviewCard.transform = .identity }
    }

    func showSavedFlash(label: String, volumeM3: Float? = nil) {
        flashLabel.text = volumeM3.map { "≈ \(Self.formatVolume($0)) m³" } ?? "Gespeichert"
        flashSub.text = label.isEmpty ? "wird automatisch benannt" : label
        setState(.itemSaved)
    }

    // MARK: - Private

    private func updateHint() {
        guard state == .idle else { return }
        if !detections.isEmpty {
            hintLabel.text = "  Objekt antippen oder mittig messen  "
        } else {
            hintLabel.text = "  Objekt in den Rahmen nehmen und messen  "
        }
    }

    /// German decimals: 1.4 m³ reads as "1,4".
    private static func formatVolume(_ v: Float) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    private static func formatCm(_ m: Float) -> String {
        String(Int((m * 100).rounded()))
    }

    // MARK: - Keyboard

    @objc private func keyboardWillChange(_ note: Notification) {
        guard state == .review,
              let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        // Lift the card just enough to keep its buttons above the keyboard.
        let keyboardTop = bounds.height - frameValue.cgRectValue.height
        let cardTop = reviewCard.frame.minY + reviewKeyboardShift
        reviewKeyboardShift = max(0, cardTop + reviewSave.frame.maxY + 16 - keyboardTop)
        animateCardShift()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        guard reviewKeyboardShift != 0 else { return }
        reviewKeyboardShift = 0
        animateCardShift()
    }

    private func animateCardShift() {
        setNeedsLayout()
        UIView.animate(withDuration: 0.25) { self.layoutIfNeeded() }
    }

    // MARK: - Actions

    @objc private func closeTapped() { onClose?() }
    @objc private func finishTapped() { onFinish?() }
    @objc private func measureTapped() { onMeasureRequested?() }
    @objc private func arcCancelTapped() { onCancelArc?() }

    @objc private func saveTapped() {
        reviewField.resignFirstResponder()
        onSaveItem?(reviewField.text?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    @objc private func remeasureTapped() {
        reviewField.resignFirstResponder()
        onRemeasure?()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let pt = gesture.location(in: self)
        if state == .review {
            // Tapping outside the card just dismisses the keyboard.
            if !reviewCard.frame.contains(pt) { reviewField.resignFirstResponder() }
            return
        }
        guard state == .idle else { return }
        for box in detections {
            let rect = CGRect(x: CGFloat(box.x) * bounds.width, y: CGFloat(box.y) * bounds.height,
                              width: CGFloat(box.w) * bounds.width, height: CGFloat(box.h) * bounds.height)
            if rect.contains(pt) {
                onDetectionTapped?(box)
                return
            }
        }
    }
}

// MARK: - UITextFieldDelegate

extension ScanOverlayView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
