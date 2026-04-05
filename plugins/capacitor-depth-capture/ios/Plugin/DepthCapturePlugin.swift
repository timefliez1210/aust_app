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
    let label: String
    let frames: [ItemFrame]
    let arcDegrees: Float
    let hasDepth: Bool
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
    private var detectionLayers: [CALayer] = []

    // ── Arc sweep ─────────────────────────────────────────────────────────
    private var scanActive = false
    private var scanLabel = ""
    private var scanFrames: [ItemFrame] = []
    private var scanRefQuaternion: simd_quatf?
    private var scanAccumulatedDeg: Float = 0
    private var scanPrevQuaternion: simd_quatf?
    private static let arcThresholdDeg: Float = 28
    private static let minFrames = 4

    // ── Items ─────────────────────────────────────────────────────────────
    private var savedItems: [SavedItem] = []

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
            return [
                "label": item.label, "frames": frames,
                "arcDegrees": item.arcDegrees, "hasDepth": item.hasDepth,
            ]
        }
        call.resolve(["items": result])
    }

    @objc func clearItems(_ call: CAPPluginCall) {
        savedItems = []
        call.resolve()
    }

    // MARK: - AR setup / teardown

    private func setupARView() {
        guard let rootVC = bridge?.viewController else { return }

        hasLidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

        let sceneView = ARSCNView(frame: rootVC.view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.isUserInteractionEnabled = false

        rootVC.view.addSubview(sceneView)
        arView = sceneView

        // Hide WebView entirely — native UI takes over
        bridge?.webView?.isHidden = true

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = []
        if hasLidar { config.frameSemantics = .sceneDepth }
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func setupNativeOverlay() {
        guard let rootVC = bridge?.viewController,
              let arView = arView else { return }

        let ov = ScanOverlayView(frame: rootVC.view.bounds)
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
        ov.onDetectionTapped = { [weak self] box in
            self?.overlay?.showItemSheet(label: box.germanLabel.isEmpty ? box.label : box.germanLabel,
                                         confidence: box.confidence)
        }
        ov.onConfirmItem = { [weak self] label in
            self?.beginArcSweep(label: label)
        }
        ov.onDrawModeRequested = { [weak self] in
            self?.enterNativeDrawMode()
        }
        ov.onCancelArc = { [weak self] in
            self?.scanActive = false
            self?.scanFrames = []
            self?.overlay?.setState(.idle)
        }

        rootVC.view.insertSubview(ov, aboveSubview: arView)
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

    private func beginArcSweep(label: String) {
        scanLabel = label
        scanFrames = []
        scanRefQuaternion = nil
        scanPrevQuaternion = nil
        scanAccumulatedDeg = 0
        scanActive = true
        clearDetectionLayers()
        overlay?.setState(.arcSweep)
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

        let imageBase64 = pixelBufferToJPEGBase64(frame.capturedImage)
        var depthBase64: String?
        if hasLidar, let dm = frame.sceneDepth?.depthMap { depthBase64 = depthMapToBase64PNG(dm) }
        scanFrames.append(ItemFrame(imageBase64: imageBase64, depthMapBase64: depthBase64,
                                    pose: transformToFloatArray(frame.camera.transform)))

        if scanAccumulatedDeg >= Self.arcThresholdDeg && scanFrames.count >= Self.minFrames {
            finalizeScan()
        }
    }

    private func finalizeScan() {
        scanActive = false
        let item = SavedItem(label: scanLabel, frames: scanFrames,
                             arcDegrees: scanAccumulatedDeg,
                             hasDepth: scanFrames.contains { $0.depthMapBase64 != nil })
        savedItems.append(item)
        notifyListeners("itemSaved", data: [
            "label": item.label, "frameCount": item.frames.count,
            "arcDegrees": item.arcDegrees, "hasDepth": item.hasDepth,
        ])
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlay?.showSavedFlash(label: self.scanLabel)
            self.overlay?.updateItemCount(self.savedItems.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.overlay?.setState(.idle)
            }
        }
    }

    // MARK: - Draw mode

    private func enterNativeDrawMode() {
        guard let rootVC = bridge?.viewController,
              let ov = overlay else { return }
        ov.setState(.drawMode)
        let draw = DrawOverlayView(frame: rootVC.view.bounds)
        draw.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        draw.onBoxDrawn = { [weak self] rect, screenSize in
            guard let self else { return }
            draw.removeFromSuperview()
            self.overlay?.showLabelInput { [weak self] label in
                guard let self, let label else {
                    self?.overlay?.setState(.idle)
                    return
                }
                self.beginArcSweep(label: label)
            }
        }
        draw.onCancelled = { [weak self] in
            draw.removeFromSuperview()
            self?.overlay?.setState(.idle)
        }
        rootVC.view.insertSubview(draw, aboveSubview: ov)
    }

    // MARK: - YOLO

    private func loadYOLOModel() {
        let names = ["yolov8n", "YOLOv8n", "YOLOv11n"]
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
            let boxes = results.prefix(5).compactMap { obs -> DetectionBox? in
                guard let top = obs.labels.first, top.confidence > 0.35 else { return nil }
                let bb = obs.boundingBox
                return DetectionBox(label: top.identifier,
                                    germanLabel: self.furnitureLabels[top.identifier] ?? "",
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
        clearDetectionLayers()
        let bounds = sceneView.bounds
        for box in boxes {
            let rect = CGRect(x: CGFloat(box.x) * bounds.width, y: CGFloat(box.y) * bounds.height,
                              width: CGFloat(box.w) * bounds.width, height: CGFloat(box.h) * bounds.height)
            let layer = CAShapeLayer()
            layer.path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
            layer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            layer.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
            layer.lineWidth = 2
            let label = CATextLayer()
            let name = box.germanLabel.isEmpty ? box.label : box.germanLabel
            label.string = "\(name)  \(Int(box.confidence * 100))%"
            label.fontSize = 12; label.foregroundColor = UIColor.white.cgColor
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
            label.cornerRadius = 4; label.contentsScale = UIScreen.main.scale
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

        if !scanActive {
            frameCounter += 1
            if frameCounter % yoloEveryNFrames == 0 {
                let buf = frame.capturedImage
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.runYOLO(on: buf) }
            }
        } else {
            processArcFrame(frame)
        }
    }
}

// MARK: - ScanOverlayView (100% native UI)

private class ScanOverlayView: UIView {

    enum State { case idle, drawMode, arcSweep, itemSaved }

    // Callbacks
    var onClose: (() -> Void)?
    var onFinish: (() -> Void)?
    var onDetectionTapped: ((DetectionBox) -> Void)?
    var onConfirmItem: ((String) -> Void)?
    var onDrawModeRequested: (() -> Void)?
    var onCancelArc: (() -> Void)?

    private var state: State = .idle
    private var detections: [DetectionBox] = []
    private var itemCount = 0

    // ── Top bar ──────────────────────────────────────────────────────────
    private let countPill = UIView()
    private let countDot = UIView()
    private let countLabel = UILabel()
    private let closeBtn = UIButton(type: .system)

    // ── Bottom bar ───────────────────────────────────────────────────────
    private let bottomBar = UIView()
    private let addBtn = UIButton(type: .system)
    private let finishBtn = UIButton(type: .system)
    private let hintLabel = UILabel()

    // ── Bottom sheet ─────────────────────────────────────────────────────
    private let sheet = UIView()
    private let sheetHandle = UIView()
    private let sheetTitle = UILabel()
    private let sheetSubtitle = UILabel()
    private let sheetCancel = UIButton(type: .system)
    private let sheetConfirm = UIButton(type: .system)
    private var sheetLabel = ""

    // ── Arc overlay ──────────────────────────────────────────────────────
    private let arcContainer = UIView()
    private let arcBgLayer = CAShapeLayer()
    private let arcProgressLayer = CAShapeLayer()
    private let arcDegreesLabel = UILabel()
    private let arcMaxLabel = UILabel()
    private let arcDirLabel = UILabel()
    private let arcCancelBtn = UIButton(type: .system)

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
        buildBottomBar()
        buildSheet()
        buildArcOverlay()
        buildFlash()
        addTapGesture()
        setState(.idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build UI

    private func buildTopBar() {
        // Count pill
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

        // Close button
        closeBtn.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        closeBtn.layer.cornerRadius = 20
        closeBtn.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeBtn)
    }

    private func buildBottomBar() {
        bottomBar.backgroundColor = .clear
        addSubview(bottomBar)

        hintLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        hintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        hintLabel.layer.cornerRadius = 12
        hintLabel.clipsToBounds = true
        bottomBar.addSubview(hintLabel)

        // Add button
        addBtn.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        addBtn.layer.cornerRadius = 12
        addBtn.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)), for: .normal)
        addBtn.tintColor = .white
        addBtn.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        bottomBar.addSubview(addBtn)

        // Finish button
        finishBtn.backgroundColor = UIColor(red: 2/255, green: 36/255, blue: 72/255, alpha: 1)
        finishBtn.layer.cornerRadius = 12
        finishBtn.setTitle("Fertig", for: .normal)
        finishBtn.setTitleColor(.white, for: .normal)
        finishBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        finishBtn.contentEdgeInsets = UIEdgeInsets(top: 14, left: 28, bottom: 14, right: 28)
        finishBtn.alpha = 0.4
        finishBtn.isEnabled = false
        finishBtn.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
        bottomBar.addSubview(finishBtn)
    }

    private func buildSheet() {
        sheet.backgroundColor = UIColor(red: 236/255, green: 238/255, blue: 240/255, alpha: 1)
        sheet.layer.cornerRadius = 24
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.isHidden = true
        addSubview(sheet)

        sheetHandle.backgroundColor = UIColor.gray.withAlphaComponent(0.3)
        sheetHandle.layer.cornerRadius = 2
        sheet.addSubview(sheetHandle)

        sheetTitle.font = .systemFont(ofSize: 20, weight: .bold)
        sheetTitle.textColor = UIColor(red: 25/255, green: 28/255, blue: 30/255, alpha: 1)
        sheet.addSubview(sheetTitle)

        sheetSubtitle.font = .systemFont(ofSize: 14, weight: .regular)
        sheetSubtitle.textColor = UIColor(red: 116/255, green: 119/255, blue: 127/255, alpha: 1)
        sheet.addSubview(sheetSubtitle)

        sheetCancel.backgroundColor = UIColor(red: 230/255, green: 232/255, blue: 234/255, alpha: 1)
        sheetCancel.layer.cornerRadius = 12
        sheetCancel.setTitle("Abbrechen", for: .normal)
        sheetCancel.setTitleColor(UIColor(red: 67/255, green: 71/255, blue: 78/255, alpha: 1), for: .normal)
        sheetCancel.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        sheetCancel.addTarget(self, action: #selector(sheetCancelTapped), for: .touchUpInside)
        sheet.addSubview(sheetCancel)

        sheetConfirm.backgroundColor = UIColor(red: 2/255, green: 36/255, blue: 72/255, alpha: 1)
        sheetConfirm.layer.cornerRadius = 12
        sheetConfirm.setTitle("Erfassen →", for: .normal)
        sheetConfirm.setTitleColor(.white, for: .normal)
        sheetConfirm.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        sheetConfirm.addTarget(self, action: #selector(sheetConfirmTapped), for: .touchUpInside)
        sheet.addSubview(sheetConfirm)
    }

    private func buildArcOverlay() {
        arcContainer.isHidden = true
        arcContainer.isUserInteractionEnabled = true
        addSubview(arcContainer)

        // Background circle
        arcBgLayer.fillColor = UIColor.clear.cgColor
        arcBgLayer.strokeColor = UIColor.white.withAlphaComponent(0.15).cgColor
        arcBgLayer.lineWidth = 4
        arcContainer.layer.addSublayer(arcBgLayer)

        // Progress arc
        arcProgressLayer.fillColor = UIColor.clear.cgColor
        arcProgressLayer.strokeColor = UIColor.white.cgColor
        arcProgressLayer.lineWidth = 5
        arcProgressLayer.lineCap = .round
        arcProgressLayer.strokeEnd = 0
        arcContainer.layer.addSublayer(arcProgressLayer)

        arcDegreesLabel.text = "0°"
        arcDegreesLabel.textColor = .white
        arcDegreesLabel.font = .systemFont(ofSize: 28, weight: .bold)
        arcDegreesLabel.textAlignment = .center
        arcContainer.addSubview(arcDegreesLabel)

        arcMaxLabel.text = "von 28°"
        arcMaxLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        arcMaxLabel.font = .systemFont(ofSize: 13)
        arcMaxLabel.textAlignment = .center
        arcContainer.addSubview(arcMaxLabel)

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
        flashLabel.font = .systemFont(ofSize: 20, weight: .bold)
        flashLabel.textAlignment = .center
        flashView.addSubview(flashLabel)

        flashSub.text = "gespeichert"
        flashSub.textColor = UIColor.white.withAlphaComponent(0.7)
        flashSub.font = .systemFont(ofSize: 14)
        flashSub.textAlignment = .center
        flashView.addSubview(flashSub)
    }

    private func addTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
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

        // Bottom bar
        let bbH: CGFloat = 120
        bottomBar.frame = CGRect(x: 0, y: bounds.height - bbH - safe.bottom, width: w, height: bbH)
        hintLabel.frame = CGRect(x: (w - 240) / 2, y: 0, width: 240, height: 28)
        addBtn.frame = CGRect(x: 20, y: 40, width: 48, height: 48)
        finishBtn.sizeToFit()
        finishBtn.frame = CGRect(x: w - finishBtn.frame.width - 20, y: 40,
                                  width: finishBtn.frame.width, height: 48)

        // Sheet
        let sheetH: CGFloat = 220 + safe.bottom
        sheet.frame = CGRect(x: 0, y: bounds.height - sheetH, width: w, height: sheetH)
        sheetHandle.frame = CGRect(x: (w - 40) / 2, y: 12, width: 40, height: 4)
        sheetTitle.frame = CGRect(x: 24, y: 36, width: w - 48, height: 28)
        sheetSubtitle.frame = CGRect(x: 24, y: 68, width: w - 48, height: 20)
        let btnY: CGFloat = 108
        let btnW = (w - 60) / 2
        sheetCancel.frame = CGRect(x: 24, y: btnY, width: btnW, height: 48)
        sheetConfirm.frame = CGRect(x: 24 + btnW + 12, y: btnY, width: btnW, height: 48)

        // Arc overlay
        arcContainer.frame = bounds
        let arcR: CGFloat = 120
        let cx = w / 2, cy = bounds.height / 2 - 40
        let circleRect = CGRect(x: cx - arcR, y: cy - arcR, width: arcR * 2, height: arcR * 2)
        arcBgLayer.path = UIBezierPath(ovalIn: circleRect).cgPath
        arcProgressLayer.path = UIBezierPath(arcCenter: CGPoint(x: cx, y: cy), radius: arcR,
                                              startAngle: -.pi / 2,
                                              endAngle: -.pi / 2 + 2 * .pi,
                                              clockwise: true).cgPath
        arcDegreesLabel.frame = CGRect(x: cx - 60, y: cy - 20, width: 120, height: 34)
        arcMaxLabel.frame = CGRect(x: cx - 60, y: cy + 16, width: 120, height: 20)
        arcDirLabel.frame = CGRect(x: (w - 280) / 2, y: cy + arcR + 30, width: 280, height: 36)
        arcCancelBtn.frame = CGRect(x: (w - 140) / 2, y: bounds.height - safe.bottom - 70, width: 140, height: 48)

        // Flash
        flashView.frame = bounds
        flashCheck.frame = CGRect(x: (w - 80) / 2, y: bounds.height / 2 - 80, width: 80, height: 80)
        flashLabel.frame = CGRect(x: 20, y: bounds.height / 2 + 16, width: w - 40, height: 28)
        flashSub.frame = CGRect(x: 20, y: bounds.height / 2 + 48, width: w - 40, height: 20)
    }

    // MARK: - State

    func setState(_ newState: State) {
        state = newState
        let idle = newState == .idle
        countPill.isHidden = false
        closeBtn.isHidden = false
        bottomBar.isHidden = !idle
        sheet.isHidden = true
        arcContainer.isHidden = newState != .arcSweep
        flashView.isHidden = newState != .itemSaved
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
        arcDegreesLabel.text = "\(Int(degrees))°"
        arcProgressLayer.strokeEnd = CGFloat(min(degrees / 28.0, 1.0))
        switch direction {
        case "left":  arcDirLabel.text = "  ← langsam nach links bewegen  "
        case "right": arcDirLabel.text = "  → langsam nach rechts bewegen  "
        case "up":    arcDirLabel.text = "  ↑ langsam nach oben bewegen  "
        default:      arcDirLabel.text = "  ↓ langsam nach unten bewegen  "
        }
    }

    func showItemSheet(label: String, confidence: Float) {
        sheetLabel = label
        sheetTitle.text = label
        sheetSubtitle.text = "\(Int(confidence * 100))% Konfidenz · 28° Sweep"
        sheet.isHidden = false
        bottomBar.isHidden = true
        sheet.transform = CGAffineTransform(translationX: 0, y: 300)
        UIView.animate(withDuration: 0.3) { self.sheet.transform = .identity }
    }

    func showSavedFlash(label: String) {
        flashLabel.text = label
        setState(.itemSaved)
    }

    func showLabelInput(completion: @escaping (String?) -> Void) {
        guard let vc = findViewController() else { completion(nil); return }
        let alert = UIAlertController(title: "Objekt benennen", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "z.B. Schrank, Sofa, Bett..."
            tf.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "Erfassen", style: .default) { _ in
            completion(alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces))
        })
        vc.present(alert, animated: true)
    }

    // MARK: - Private

    private func updateHint() {
        if state != .idle { return }
        if !detections.isEmpty {
            hintLabel.text = "  Tippe auf ein erkanntes Objekt  "
            hintLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        } else {
            hintLabel.text = "  Richte die Kamera auf Möbel...  "
            hintLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        }
    }

    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }

    // MARK: - Actions

    @objc private func closeTapped() { onClose?() }
    @objc private func finishTapped() { onFinish?() }
    @objc private func addTapped() { onDrawModeRequested?() }
    @objc private func arcCancelTapped() { onCancelArc?() }

    @objc private func sheetCancelTapped() {
        UIView.animate(withDuration: 0.2, animations: {
            self.sheet.transform = CGAffineTransform(translationX: 0, y: 300)
        }) { _ in
            self.sheet.isHidden = true
            self.setState(.idle)
        }
    }

    @objc private func sheetConfirmTapped() {
        sheet.isHidden = true
        onConfirmItem?(sheetLabel)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard state == .idle else { return }
        let pt = gesture.location(in: self)
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

// MARK: - DrawOverlayView

private class DrawOverlayView: UIView {

    var onBoxDrawn: ((CGRect, CGSize) -> Void)?
    var onCancelled: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentRect: CGRect?
    private let shapeLayer = CAShapeLayer()
    private let cancelBtn = UIButton(type: .system)
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.3)
        isUserInteractionEnabled = true

        // Dot grid
        let grid = UIView(frame: bounds.insetBy(dx: 32, dy: 32))
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        grid.isUserInteractionEnabled = false
        addSubview(grid)

        shapeLayer.strokeColor = UIColor.white.cgColor
        shapeLayer.fillColor = UIColor.white.withAlphaComponent(0.1).cgColor
        shapeLayer.lineWidth = 2
        shapeLayer.lineDashPattern = [6, 4]
        layer.addSublayer(shapeLayer)

        hintLabel.text = "Ziehe ein Rechteck um das Objekt"
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.textAlignment = .center
        addSubview(hintLabel)

        cancelBtn.setTitle("Abbrechen", for: .normal)
        cancelBtn.setTitleColor(.white, for: .normal)
        cancelBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        cancelBtn.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        cancelBtn.layer.cornerRadius = 12
        cancelBtn.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        cancelBtn.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        addSubview(cancelBtn)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = safeAreaInsets
        hintLabel.frame = CGRect(x: 32, y: bounds.height - 180 - safe.bottom, width: bounds.width - 64, height: 20)
        cancelBtn.sizeToFit()
        cancelBtn.frame = CGRect(x: (bounds.width - cancelBtn.frame.width) / 2,
                                  y: bounds.height - safe.bottom - 70,
                                  width: cancelBtn.frame.width, height: 48)
    }

    @objc private func cancel() { onCancelled?() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = touches.first?.location(in: self) else { return }
        if cancelBtn.frame.contains(pt) { return }
        startPoint = pt
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let start = startPoint, let cur = touches.first?.location(in: self) else { return }
        currentRect = CGRect(x: min(start.x, cur.x), y: min(start.y, cur.y),
                             width: abs(cur.x - start.x), height: abs(cur.y - start.y))
        if let r = currentRect { shapeLayer.path = UIBezierPath(roundedRect: r, cornerRadius: 6).cgPath }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let rect = currentRect, rect.width > 20, rect.height > 20 else {
            startPoint = nil; currentRect = nil; shapeLayer.path = nil; return
        }
        onBoxDrawn?(rect, bounds.size)
    }
}
