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
    let pose: [Float]          // 16 floats, 4×4 column-major
}

private struct SavedItem {
    let label: String
    let frames: [ItemFrame]
    let arcDegrees: Float
    let hasDepth: Bool
}

// MARK: - DepthCapturePlugin

/// Capacitor plugin for per-item AR arc-sweep capture.
///
/// **Architecture**: On startSession() the plugin inserts an ARSCNView behind
/// the Capacitor WebView and makes the WebView transparent. YOLO detections are
/// drawn natively via CAShapeLayers. JS receives only state-transition events
/// and renders the chrome (count chip, arc progress, bottom sheets).
///
/// On stopSession() the ARSCNView is removed and WebView opacity is restored.
@objc(DepthCapturePlugin)
public class DepthCapturePlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "DepthCapturePlugin"
    public let jsName = "DepthCapture"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "checkSupport",   returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startSession",   returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSession",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startItemScan",  returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelItemScan", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setDrawMode",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getIntrinsics",  returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAllItems",     returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearItems",     returnType: CAPPluginReturnPromise),
    ]

    // ── AR session ────────────────────────────────────────────────────────
    private var arView: ARSCNView?
    private var arSession: ARSession { arView?.session ?? ARSession() }
    private var frameCounter = 0
    private let yoloEveryNFrames = 10
    private var hasLidar = false
    private var sessionIntrinsics: simd_float3x3?

    // ── YOLO ──────────────────────────────────────────────────────────────
    private var visionModel: VNCoreMLModel?
    private var furnitureLabels: [String: String] = [:]
    private var currentDetections: [DetectionBox] = []
    private var detectionLayers: [CALayer] = []

    // ── Arc sweep state ───────────────────────────────────────────────────
    private var scanActive = false
    private var scanLabel = ""
    private var scanFrames: [ItemFrame] = []
    private var scanRefQuaternion: simd_quatf?
    private var scanAccumulatedDeg: Float = 0
    private var scanPrevQuaternion: simd_quatf?
    private static let arcThresholdDeg: Float = 28
    private static let minFrames = 4

    // ── Saved items ───────────────────────────────────────────────────────
    private var savedItems: [SavedItem] = []

    // ── Draw mode ─────────────────────────────────────────────────────────
    private var drawOverlay: DrawOverlayView?

    // MARK: - Plugin methods

    @objc func checkSupport(_ call: CAPPluginCall) {
        let supported = ARWorldTrackingConfiguration.isSupported
        let lidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        call.resolve(["supported": supported, "hasLidar": lidar])
    }

    @objc func startSession(_ call: CAPPluginCall) {
        // Request camera permission first — ARKit needs it, and if previously
        // denied the session would start but show a black feed with no error.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                call.reject("Camera permission denied")
                return
            }
            DispatchQueue.main.async {
                self.setupARView()
                self.loadFurnitureLabels()
                self.loadYOLOModel()
                call.resolve()
            }
        }
    }

    @objc func stopSession(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.teardownARView()
            call.resolve()
        }
    }

    @objc func startItemScan(_ call: CAPPluginCall) {
        guard !scanActive else {
            call.reject("Scan already in progress")
            return
        }
        let label = call.getString("label") ?? "Objekt"
        scanLabel = label
        scanFrames = []
        scanRefQuaternion = nil
        scanPrevQuaternion = nil
        scanAccumulatedDeg = 0
        scanActive = true
        // Hide detection overlays during sweep
        DispatchQueue.main.async { [weak self] in
            self?.clearDetectionLayers()
        }
        call.resolve()
    }

    @objc func cancelItemScan(_ call: CAPPluginCall) {
        scanActive = false
        scanFrames = []
        call.resolve()
    }

    @objc func setDrawMode(_ call: CAPPluginCall) {
        let enabled = call.getBool("enabled") ?? false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if enabled {
                self.enableDrawMode()
            } else {
                self.disableDrawMode()
            }
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
            "fx": intrinsics[0][0],
            "fy": intrinsics[1][1],
            "cx": intrinsics[2][0],
            "cy": intrinsics[2][1],
            "width": Int(w),
            "height": Int(h),
        ])
    }

    @objc func getAllItems(_ call: CAPPluginCall) {
        let result = savedItems.map { item -> [String: Any] in
            let frames = item.frames.map { f -> [String: Any] in
                var fd: [String: Any] = ["imageBase64": f.imageBase64, "pose": f.pose]
                fd["depthMapBase64"] = f.depthMapBase64 as Any
                return fd
            }
            return [
                "label": item.label,
                "frames": frames,
                "arcDegrees": item.arcDegrees,
                "hasDepth": item.hasDepth,
            ]
        }
        call.resolve(["items": result])
    }

    @objc func clearItems(_ call: CAPPluginCall) {
        savedItems = []
        call.resolve()
    }

    // MARK: - ARView setup / teardown

    private func setupARView() {
        guard let rootVC = bridge?.viewController,
              let webView = bridge?.webView else { return }

        hasLidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

        let sceneView = ARSCNView(frame: rootVC.view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.isUserInteractionEnabled = false

        // Insert behind WebView
        rootVC.view.insertSubview(sceneView, belowSubview: webView)
        arView = sceneView

        // Make WebView transparent so ARSCNView shows through
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = []
        if hasLidar {
            config.frameSemantics = .sceneDepth
        }
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func teardownARView() {
        arView?.session.pause()
        arView?.removeFromSuperview()
        arView = nil
        clearDetectionLayers()
        scanActive = false

        // Restore WebView opacity
        if let webView = bridge?.webView {
            webView.isOpaque = true
            webView.backgroundColor = .white
            webView.scrollView.backgroundColor = .white
        }
    }

    // MARK: - YOLO

    private func loadYOLOModel() {
        guard let modelURL = Bundle.main.url(forResource: "YOLOv11n", withExtension: "mlmodelc")
                          ?? Bundle.main.url(forResource: "YOLOv11n", withExtension: "mlpackage") else {
            print("[DepthCapture] YOLOv11n model not found — detection disabled")
            return
        }
        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            visionModel = try VNCoreMLModel(for: mlModel)
        } catch {
            print("[DepthCapture] Failed to load YOLO model: \(error)")
        }
    }

    private func loadFurnitureLabels() {
        // SPM bundles resources into Bundle.module, not Bundle.main
        guard let url = Bundle.module.url(forResource: "furniture_labels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            print("[DepthCapture] furniture_labels.json not found in bundle")
            return
        }
        furnitureLabels = map
    }

    private func runYOLO(on pixelBuffer: CVPixelBuffer) {
        guard let model = visionModel else { return }
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self,
                  let results = req.results as? [VNRecognizedObjectObservation] else { return }
            let boxes = results.prefix(5).compactMap { obs -> DetectionBox? in
                guard let top = obs.labels.first, top.confidence > 0.35 else { return nil }
                let german = self.furnitureLabels[top.identifier] ?? ""
                // VNRecognizedObjectObservation bbox is normalized, origin bottom-left
                // Convert to top-left origin for JS
                let bb = obs.boundingBox
                let x = bb.minX
                let y = 1.0 - bb.maxY
                return DetectionBox(label: top.identifier,
                                    germanLabel: german,
                                    confidence: top.confidence,
                                    x: Float(x), y: Float(y),
                                    w: Float(bb.width), h: Float(bb.height))
            }
            self.currentDetections = boxes
            self.emitDetections(boxes)
            DispatchQueue.main.async { self.updateDetectionLayers(boxes) }
        }
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try? handler.perform([request])
    }

    private func emitDetections(_ boxes: [DetectionBox]) {
        let payload = boxes.map { b -> [String: Any] in
            return [
                "label": b.label,
                "germanLabel": b.germanLabel,
                "confidence": b.confidence,
                "bbox": ["x": b.x, "y": b.y, "w": b.w, "h": b.h],
            ]
        }
        notifyListeners("detections", data: ["detections": payload])
    }

    // MARK: - Detection layer drawing

    private func updateDetectionLayers(_ boxes: [DetectionBox]) {
        guard let sceneView = arView else { return }
        clearDetectionLayers()

        let bounds = sceneView.bounds
        for box in boxes {
            let layer = CAShapeLayer()
            let rect = CGRect(
                x: CGFloat(box.x) * bounds.width,
                y: CGFloat(box.y) * bounds.height,
                width: CGFloat(box.w) * bounds.width,
                height: CGFloat(box.h) * bounds.height
            )
            layer.path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
            layer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            layer.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
            layer.lineWidth = 2

            // Label badge
            let label = CATextLayer()
            let displayName = box.germanLabel.isEmpty ? box.label : box.germanLabel
            let pct = Int(box.confidence * 100)
            label.string = "\(displayName)  \(pct)%"
            label.fontSize = 12
            label.foregroundColor = UIColor.white.cgColor
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
            label.cornerRadius = 4
            label.contentsScale = UIScreen.main.scale
            label.frame = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: rect.width - 12, height: 20)

            sceneView.layer.addSublayer(layer)
            sceneView.layer.addSublayer(label)
            detectionLayers.append(contentsOf: [layer, label])
        }
    }

    private func clearDetectionLayers() {
        detectionLayers.forEach { $0.removeFromSuperlayer() }
        detectionLayers.removeAll()
    }

    // MARK: - Arc sweep per-frame processing

    private func processArcFrame(_ frame: ARFrame) {
        guard scanActive else { return }

        let currentTransform = frame.camera.transform
        let currentQuat = simd_quatf(currentTransform)

        // Record reference pose on first frame
        if scanRefQuaternion == nil {
            scanRefQuaternion = currentQuat
            scanPrevQuaternion = currentQuat
        }

        // Accumulate frame-to-frame rotation
        if let prev = scanPrevQuaternion {
            let deltaDeg = quaternionAngularDistance(prev, currentQuat)
            scanAccumulatedDeg += deltaDeg
            scanPrevQuaternion = currentQuat

            // Determine dominant rotation direction
            let direction = dominantDirection(from: prev, to: currentQuat)
            notifyListeners("arcProgress", data: [
                "degrees": scanAccumulatedDeg,
                "direction": direction,
            ])
        }

        // Capture this frame
        let imageBase64 = pixelBufferToJPEGBase64(frame.capturedImage)
        var depthBase64: String? = nil
        if hasLidar, let depthMap = frame.sceneDepth?.depthMap {
            depthBase64 = depthMapToBase64PNG(depthMap)
        }
        let poseArray = transformToFloatArray(currentTransform)
        scanFrames.append(ItemFrame(imageBase64: imageBase64,
                                    depthMapBase64: depthBase64,
                                    pose: poseArray))

        // Auto-stop when threshold reached
        if scanAccumulatedDeg >= DepthCapturePlugin.arcThresholdDeg
            && scanFrames.count >= DepthCapturePlugin.minFrames {
            finalizeScan()
        }
    }

    private func finalizeScan() {
        scanActive = false
        let item = SavedItem(
            label: scanLabel,
            frames: scanFrames,
            arcDegrees: scanAccumulatedDeg,
            hasDepth: scanFrames.contains { $0.depthMapBase64 != nil }
        )
        savedItems.append(item)
        notifyListeners("itemSaved", data: [
            "label": item.label,
            "frameCount": item.frames.count,
            "arcDegrees": item.arcDegrees,
            "hasDepth": item.hasDepth,
        ])
    }

    // MARK: - Draw mode

    private func enableDrawMode() {
        guard let rootVC = bridge?.viewController,
              let webView = bridge?.webView else { return }
        let overlay = DrawOverlayView(frame: rootVC.view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.onBoxDrawn = { [weak self] rect, screenSize in
            guard let self else { return }
            self.disableDrawMode()
            self.notifyListeners("boxDrawn", data: [
                "x": rect.minX / screenSize.width,
                "y": rect.minY / screenSize.height,
                "w": rect.width / screenSize.width,
                "h": rect.height / screenSize.height,
                "screenW": Int(screenSize.width),
                "screenH": Int(screenSize.height),
            ])
        }
        rootVC.view.insertSubview(overlay, aboveSubview: webView)
        drawOverlay = overlay
    }

    private func disableDrawMode() {
        drawOverlay?.removeFromSuperview()
        drawOverlay = nil
    }

    // MARK: - Math helpers

    /// Angular distance between two unit quaternions in degrees.
    private func quaternionAngularDistance(_ q1: simd_quatf, _ q2: simd_quatf) -> Float {
        let dot = abs(simd_dot(q1.vector, q2.vector))
        let clamped = min(max(dot, -1.0), 1.0)
        return 2.0 * acos(clamped) * (180.0 / .pi)
    }

    /// Determine dominant rotation direction from quaternion delta.
    private func dominantDirection(from q1: simd_quatf, to q2: simd_quatf) -> String {
        // Compute rotation axis in world space
        let deltaQuat = q2 * q1.inverse
        let axis = deltaQuat.axis
        let absX = abs(axis.x)
        let absY = abs(axis.y)
        if absY > absX {
            return axis.y > 0 ? "left" : "right"
        } else {
            return axis.x > 0 ? "down" : "up"
        }
    }

    /// 4×4 simd_float4x4 → [Float] × 16, column-major.
    private func transformToFloatArray(_ t: simd_float4x4) -> [Float] {
        return [
            t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
        ]
    }

    // MARK: - Image encoding

    private func pixelBufferToJPEGBase64(_ pixelBuffer: CVPixelBuffer) -> String {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85) else {
            return ""
        }
        return data.base64EncodedString()
    }

    /// Convert ARDepthMap (Float32, metres) to 16-bit grayscale PNG base64.
    private func depthMapToBase64PNG(_ depthMap: CVPixelBuffer) -> String? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let src = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let float32Ptr = src.bindMemory(to: Float32.self, capacity: width * height)
        var uint16Data = [UInt16](repeating: 0, count: width * height)

        for i in 0 ..< width * height {
            // Convert metres to millimetres, clamp to UInt16
            let mm = float32Ptr[i] * 1000.0
            uint16Data[i] = UInt16(clamping: Int(mm))
        }

        guard let provider = CGDataProvider(data: Data(bytes: uint16Data,
                                                       count: width * height * 2) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 16, bitsPerPixel: 16,
                bytesPerRow: width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return nil }

        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else { return nil }
        return pngData.base64EncodedString()
    }
}

// MARK: - ARSCNViewDelegate

extension DepthCapturePlugin: ARSCNViewDelegate {

    public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let frame = arView?.session.currentFrame else { return }

        // Capture intrinsics once
        if sessionIntrinsics == nil {
            sessionIntrinsics = frame.camera.intrinsics
        }

        // YOLO inference every N frames (when not in arc sweep)
        if !scanActive {
            frameCounter += 1
            if frameCounter % yoloEveryNFrames == 0 {
                let pixelBuffer = frame.capturedImage
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.runYOLO(on: pixelBuffer)
                }
            }
        } else {
            // Arc sweep: capture every frame
            processArcFrame(frame)
        }
    }
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

// MARK: - DrawOverlayView

/// Full-screen native view that captures a single drag gesture for manual bbox drawing.
private class DrawOverlayView: UIView {

    var onBoxDrawn: ((CGRect, CGSize) -> Void)?

    private var startPoint: CGPoint?
    private var currentRect: CGRect?
    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        shapeLayer.strokeColor = UIColor.white.cgColor
        shapeLayer.fillColor = UIColor.white.withAlphaComponent(0.1).cgColor
        shapeLayer.lineWidth = 2
        shapeLayer.lineDashPattern = [6, 4]
        layer.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        startPoint = touches.first?.location(in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let start = startPoint,
              let current = touches.first?.location(in: self) else { return }
        currentRect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        if let rect = currentRect {
            shapeLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 6).cgPath
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let rect = currentRect, rect.width > 20, rect.height > 20 else {
            startPoint = nil
            currentRect = nil
            shapeLayer.path = nil
            return
        }
        onBoxDrawn?(rect, bounds.size)
    }
}
