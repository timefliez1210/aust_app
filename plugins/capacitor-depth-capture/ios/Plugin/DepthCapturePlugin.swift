import Foundation
import Capacitor
import ARKit
import SceneKit
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
    /// Orbit span covered while measuring, in degrees. Reporting only.
    let arcDegrees: Float
    let hasDepth: Bool
    /// Volume in m³ incl. packing factor — measured on device, or typed by the
    /// customer via manual entry. nil when neither worked; the backend then
    /// estimates from the photos.
    let volumeM3: Float?
    /// Gravity-aligned OBB dimensions [length, width, height] in metres.
    let dims: simd_float3?
    /// Heuristic confidence [0, 1] for the volume.
    let deviceConfidence: Float?
}

// MARK: - DetectionBox
//
// YOLO output. Never drawn — detection runs silently and its best guess for
// whatever sits in the reticle only pre-fills the (optional) name field.

private struct DetectionBox {
    let label: String
    let germanLabel: String
    let confidence: Float
    let x: Float
    let y: Float
    let w: Float
    let h: Float

    var centerDistance: Float {
        // Distance of the box centre from the frame centre, in normalized units.
        simd_length(simd_float2(x + w / 2 - 0.5, y + h / 2 - 0.5))
    }

    func contains(normalized p: simd_float2) -> Bool {
        p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + h
    }
}

// MARK: - DepthCapturePlugin

public class DepthCapturePlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "DepthCapturePlugin"
    public let jsName = "DepthCapture"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "checkSupport",   returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startSession",   returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSession",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getIntrinsics",  returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAllItems",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearItems",     returnType: CAPPluginReturnPromise),
    ]

    // ── AR ────────────────────────────────────────────────────────────────
    private var arView: ARSCNView?
    private var frameCounter = 0
    private let yoloEveryNFrames = 12
    private var hasLidar = false
    private var canMesh = false
    private var sessionIntrinsics: simd_float3x3?
    /// AR view size, cached on the main thread — the render thread must not
    /// read `arView.bounds`.
    private var viewportSize: CGSize = .zero

    // ── YOLO (silent) ─────────────────────────────────────────────────────
    private var visionModel: VNCoreMLModel?
    private var furnitureLabels: [String: String] = [:]
    /// Best guess for whatever is in front of the camera. Never drawn — it only
    /// pre-fills the (optional) name field in manual entry.
    private var silentLabelGuess = ""

    // ── Room sweep ────────────────────────────────────────────────────────
    private var sweeping = false
    /// Photos taken during the sweep, one of which ends up attached to each
    /// object so the backend can name it.
    private var sweepFrames: [ItemFrame] = []
    private var sweepPoses: [simd_float4x4] = []
    private var lastFrameCapture: TimeInterval = 0
    private static let frameCaptureInterval: TimeInterval = 0.7
    private static let maxSweepFrames = 40

    /// The mesh is re-read on a background queue while the sweep continues, so
    /// objects appear as they are found instead of all at once at the end.
    private var scanning = false
    private var lastScanTime: TimeInterval = 0
    private static let scanInterval: TimeInterval = 1.5
    private let scanQueue = DispatchQueue(label: "aust.depthcapture.rooms", qos: .userInitiated)

    private var objects: [RoomObject] = []
    private var nextObjectID = 0
    private var selectedObjectID: Int?
    private var boxNodes: [Int: SCNNode] = [:]
    /// The selected object's node and dimensions, published for the render
    /// thread so it never walks `objects` while the main thread rebuilds it.
    private var selectedBox: (node: SCNNode, dims: simd_float3)?

    // ── Items ─────────────────────────────────────────────────────────────
    private var savedItems: [SavedItem] = []

    // ── Native UI ─────────────────────────────────────────────────────────
    private var overlay: ScanOverlayView?

    // MARK: - Plugin methods

    @objc func checkSupport(_ call: CAPPluginCall) {
        let supported = ARWorldTrackingConfiguration.isSupported
        let lidar = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        call.resolve(["supported": supported, "hasLidar": lidar])
    }

    @objc func startSession(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard ARWorldTrackingConfiguration.isSupported else {
                call.reject("AR wird auf diesem Gerät nicht unterstützt")
                return
            }
            self.loadYOLOModel()
            self.loadFurnitureLabels()
            self.setupARView()
            self.setupNativeOverlay()
            call.resolve()
        }
    }

    @objc func stopSession(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.teardownAll()
            call.resolve()
        }
    }

    @objc func getIntrinsics(_ call: CAPPluginCall) {
        guard let k = sessionIntrinsics,
              let resolution = arView?.session.currentFrame?.camera.imageResolution else {
            call.reject("Keine Kameradaten verfügbar")
            return
        }
        call.resolve([
            "fx": k[0][0], "fy": k[1][1], "cx": k[2][0], "cy": k[2][1],
            "width": Int(resolution.width), "height": Int(resolution.height),
        ])
    }

    @objc func getAllItems(_ call: CAPPluginCall) {
        let items: [[String: Any]] = savedItems.map { item in
            var payload: [String: Any] = [
                "label": item.label,
                "arcDegrees": item.arcDegrees,
                "hasDepth": item.hasDepth,
                "frames": item.frames.map { frame -> [String: Any] in
                    var f: [String: Any] = ["imageBase64": frame.imageBase64]
                    f["depthMapBase64"] = frame.depthMapBase64 as Any
                    f["pose"] = frame.pose
                    return f
                },
            ]
            if let volume = item.volumeM3 { payload["volumeM3"] = volume }
            if let dims = item.dims { payload["dimsM"] = [dims.x, dims.y, dims.z] }
            if let confidence = item.deviceConfidence { payload["deviceConfidence"] = confidence }
            return payload
        }
        call.resolve(["items": items])
    }

    @objc func clearItems(_ call: CAPPluginCall) {
        savedItems.removeAll()
        call.resolve()
    }

    // MARK: - AR setup / teardown

    private func setupARView() {
        guard let rootVC = bridge?.viewController,
              let window = rootVC.view.window ?? UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }

        hasLidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        canMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

        let sceneView = ARSCNView(frame: window.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.isUserInteractionEnabled = false

        // Add to window (not rootVC.view, which IS the WKWebView in Capacitor)
        window.addSubview(sceneView)
        arView = sceneView
        viewportSize = sceneView.bounds.size

        // Hide WebView entirely — native UI takes over
        bridge?.webView?.isHidden = true

        let config = ARWorldTrackingConfiguration()
        // Both alignments: the floor and the ceiling bound the room vertically,
        // and the walls are what a sofa pushed against one would otherwise grow
        // into. All three are what gets subtracted.
        config.planeDetection = [.horizontal, .vertical]
        // Classification is what lets a table stay furniture while a wall does
        // not — plain `.mesh` would force us to guess that geometrically.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if canMesh {
            config.sceneReconstruction = .mesh
        }
        if hasLidar { config.frameSemantics = .sceneDepth }
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func setupNativeOverlay() {
        guard let arView = arView,
              let window = arView.superview else { return }

        let view = ScanOverlayView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.canMeasure = canMesh

        view.onClose = { [weak self] in
            self?.notifyListeners("sessionCancelled", data: [:])
            self?.teardownAll()
        }
        view.onStartSweep = { [weak self] in self?.beginSweep() }
        view.onFinishSweep = { [weak self] in self?.finishSweep() }
        view.onSelect = { [weak self] id in self?.selectObject(id < 0 ? nil : id) }
        view.onMerge = { [weak self] first, second in self?.mergeObjects(first, second) }
        view.onSplit = { [weak self] in self?.splitSelection() }
        view.onDelete = { [weak self] in self?.deleteSelection() }
        view.onRename = { [weak self] id, text in
            self?.objects.first { $0.id == id }?.label = text
        }
        view.onSubmit = { [weak self] in self?.submitObjects() }
        view.onManualRequested = { [weak self] in
            guard let self else { return }
            self.overlay?.showManualEntry(suggestedLabel: self.silentLabelGuess)
        }
        view.onManualCancel = { [weak self] in
            guard let self else { return }
            self.overlay?.setState(self.objects.isEmpty && !self.sweeping ? .intro : .results)
        }
        view.onManualSubmit = { [weak self] entry in self?.addManualObject(entry) }

        window.addSubview(view)
        overlay = view
    }

    private func teardownAll() {
        removeBoxNodes()
        arView?.session.pause()
        arView?.removeFromSuperview()
        arView = nil
        overlay?.removeFromSuperview()
        overlay = nil
        bridge?.webView?.isHidden = false
        sweeping = false
    }

    // MARK: - Sweep

    private func beginSweep() {
        objects.removeAll()
        nextObjectID = 0
        selectedObjectID = nil
        sweepFrames.removeAll()
        sweepPoses.removeAll()
        removeBoxNodes()
        lastScanTime = 0
        lastFrameCapture = 0
        sweeping = true
        overlay?.setState(.sweeping)
        overlay?.updateSweep(objectCount: 0, totalVolume: 0)
    }

    /// End the sweep and freeze the list. One last read of the mesh, because the
    /// customer usually taps Fertig right after pointing at the last thing.
    private func finishSweep() {
        guard sweeping else { return }
        sweeping = false
        rescan { [weak self] in
            guard let self else { return }
            self.assignRepresentativeFrames()
            self.presentResults()
        }
    }

    /// Re-read the mesh and rebuild the object list.
    ///
    /// Everything expensive happens on `scanQueue`; the render thread only
    /// copies the anchor list out of the current frame. Labels the customer has
    /// already typed survive by id, so a rescan never eats their typing.
    private func rescan(completion: (() -> Void)? = nil) {
        guard canMesh, let frame = arView?.session.currentFrame else {
            completion?()
            return
        }
        guard !scanning else { completion?(); return }
        scanning = true

        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let planeAnchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }

        scanQueue.async { [weak self] in
            let found = RoomScanner.objects(from: meshAnchors, planeAnchors: planeAnchors)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.adopt(found)
                completion?()
            }
        }
    }

    /// Replace the auto-detected objects while keeping everything the customer
    /// has touched: manual entries have no mesh behind them and would otherwise
    /// vanish on the next rescan, and typed labels are matched back by position.
    private func adopt(_ found: [RoomObject]) {
        let manual = objects.filter { !$0.hasGeometry }
        let previous = objects.filter { $0.hasGeometry }

        var adopted: [RoomObject] = []
        for object in found {
            object.id = nextObjectID
            nextObjectID += 1
            // Carry a label across if a previous object sat in the same place.
            if let match = previous.first(where: {
                !$0.label.isEmpty && simd_distance($0.box.center, object.box.center) < 0.25
            }) {
                object.label = match.label
            }
            adopted.append(object)
        }
        objects = adopted + manual
        if let selected = selectedObjectID, !objects.contains(where: { $0.id == selected }) {
            selectedObjectID = nil
        }
        rebuildBoxNodes()
        let total = objects.reduce(Float(0)) { $0 + $1.volume }
        if sweeping {
            overlay?.updateSweep(objectCount: objects.count, totalVolume: total)
        }
    }

    private func presentResults() {
        overlay?.setState(.results)
        refreshResults()
    }

    private func refreshResults() {
        let rows = objects.map {
            ResultRow(id: $0.id, label: $0.label, volumeM3: $0.volume, dims: $0.box.dims)
        }
        overlay?.showResults(rows)
        overlay?.selectRow(selectedObjectID)
        rebuildBoxNodes()
    }

    // MARK: - Editing the found objects

    private func selectObject(_ id: Int?) {
        selectedObjectID = id
        rebuildBoxNodes()
    }

    private func mergeObjects(_ firstID: Int, _ secondID: Int) {
        guard let first = objects.first(where: { $0.id == firstID }),
              let second = objects.first(where: { $0.id == secondID }),
              first.id != second.id else { return }
        guard first.hasGeometry, second.hasGeometry else {
            overlay?.showToast("Manuelle Objekte lassen sich nicht zusammenfassen")
            return
        }
        guard let merged = RoomScanner.merged(first, second, id: nextObjectID) else {
            overlay?.showToast("Zusammenfassen nicht möglich")
            return
        }
        nextObjectID += 1
        objects.removeAll { $0.id == first.id || $0.id == second.id }
        objects.append(merged)
        objects.sort { $0.volume > $1.volume }
        selectedObjectID = merged.id
        refreshResults()
    }

    private func splitSelection() {
        guard let id = selectedObjectID,
              let object = objects.first(where: { $0.id == id }) else { return }
        guard object.hasGeometry else {
            overlay?.showToast("Manuelle Objekte lassen sich nicht teilen")
            return
        }
        let parts = RoomScanner.split(object, startingID: nextObjectID)
        guard parts.count >= 2 else {
            overlay?.showToast("Dieses Objekt lässt sich nicht teilen")
            return
        }
        nextObjectID += parts.count
        objects.removeAll { $0.id == id }
        objects.append(contentsOf: parts)
        objects.sort { $0.volume > $1.volume }
        selectedObjectID = parts.first?.id
        refreshResults()
    }

    private func deleteSelection() {
        guard let id = selectedObjectID else { return }
        objects.removeAll { $0.id == id }
        selectedObjectID = nil
        refreshResults()
    }

    private func addManualObject(_ entry: ManualEntry) {
        let dims = entry.dims ?? simd_float3(repeating: cbrt(max(entry.volumeM3, 0.001)))
        let box = OrientedBox(center: .zero, dims: dims, yaw: 0)
        let object = RoomObject(id: nextObjectID, points: [], box: box)
        nextObjectID += 1
        object.label = entry.label
        // A typed volume is taken as given; a typed L×W×H goes through the same
        // packing factor as a measured one.
        object.typedVolume = entry.dims == nil ? entry.volumeM3 : nil
        objects.append(object)
        objects.sort { $0.volume > $1.volume }
        selectedObjectID = object.id
        presentResults()
    }

    // MARK: - Frames

    /// Attach the photo that saw each object best, so the backend can name it.
    ///
    /// "Best" is the frame whose camera has the object in front of it and
    /// nearest — good enough for a naming pass, and the manifest only needs one
    /// frame per item for `representative_frame_per_item` to line up.
    private func assignRepresentativeFrames() {
        guard !sweepPoses.isEmpty else { return }
        for object in objects where object.hasGeometry {
            var best: (index: Int, distance: Float)?
            for (i, pose) in sweepPoses.enumerated() {
                let camera = simd_float3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
                let local = simd_inverse(pose) * simd_float4(object.box.center, 1)
                guard -local.z > 0.3 else { continue }   // behind the camera
                let distance = simd_distance(camera, object.box.center)
                if best == nil || distance < best!.distance { best = (i, distance) }
            }
            object.frameIndex = best?.index
        }
    }

    // MARK: - Submitting

    private func submitObjects() {
        savedItems = objects.map { object in
            let frames: [ItemFrame]
            if let index = object.frameIndex, index < sweepFrames.count {
                frames = [sweepFrames[index]]
            } else {
                frames = []
            }
            return SavedItem(label: object.label,
                             frames: frames,
                             arcDegrees: 0,
                             hasDepth: object.hasGeometry,
                             volumeM3: object.volume,
                             dims: object.typedVolume == nil ? object.box.dims : nil,
                             deviceConfidence: object.hasGeometry ? 0.8 : nil)
        }
        for item in savedItems {
            notifyListeners("itemSaved", data: [
                "label": item.label,
                "frameCount": item.frames.count,
                "arcDegrees": item.arcDegrees,
                "hasDepth": item.hasDepth,
                "volumeM3": item.volumeM3 as Any,
            ])
        }
        notifyListeners("sessionComplete", data: ["itemCount": savedItems.count])
    }

    // MARK: - Per-frame work

    private func processSweepFrame(_ frame: ARFrame) {
        let now = CACurrentMediaTime()

        if now - lastFrameCapture >= Self.frameCaptureInterval,
           sweepFrames.count < Self.maxSweepFrames {
            lastFrameCapture = now
            captureFrame(frame)
        }
        if now - lastScanTime >= Self.scanInterval {
            lastScanTime = now
            rescan()
        }
    }

    private func captureFrame(_ frame: ARFrame) {
        let image = pixelBufferToJPEGBase64(frame.capturedImage)
        guard !image.isEmpty else { return }
        sweepFrames.append(ItemFrame(imageBase64: image,
                                     depthMapBase64: nil,
                                     pose: transformToFloatArray(frame.camera.transform)))
        sweepPoses.append(frame.camera.transform)
    }

    // MARK: - Boxes

    /// One wireframe box per object, the selected one in orange. Rebuilt whole
    /// rather than diffed: merges and splits renumber everything, and a dozen
    /// boxes is nothing to SceneKit.
    private func rebuildBoxNodes() {
        guard let arView else { return }
        removeBoxNodes()
        var selected: (node: SCNNode, dims: simd_float3)?
        for object in objects where object.hasGeometry {
            let selected = object.id == selectedObjectID
            let node = makeBoxNode(selected: selected)
            node.simdPosition = object.box.center
            node.simdOrientation = simd_quatf(angle: object.box.yaw, axis: simd_float3(0, 1, 0))
            node.scale = SCNVector3(object.box.dims.x, object.box.dims.z, object.box.dims.y)
            arView.scene.rootNode.addChildNode(node)
            boxNodes[object.id] = node
            if selected == nil, object.id == selectedObjectID {
                selected = (node, object.box.dims)
            }
        }
        selectedBox = selected
    }

    private func removeBoxNodes() {
        for (_, node) in boxNodes { node.removeFromParentNode() }
        boxNodes.removeAll()
        selectedBox = nil
        overlay?.updateDimensionTags([])
    }

    private func makeBoxNode(selected: Bool) -> SCNNode {
        let container = SCNNode()
        let tint = selected
            ? UIColor(red: 252/255, green: 96/255, blue: 24/255, alpha: 1)
            : UIColor.white

        // The 12 edges are drawn as explicit line primitives. An SCNBox with
        // `fillMode = .lines` wireframes the *triangulated* mesh instead, which
        // puts a diagonal across every face — that reads as a mess, not as the
        // outline of the thing being measured.
        let wireMat = SCNMaterial()
        wireMat.diffuse.contents = tint
        wireMat.emission.contents = tint
        wireMat.transparency = selected ? 1.0 : 0.45
        wireMat.lightingModel = .constant
        wireMat.isDoubleSided = true
        wireMat.writesToDepthBuffer = false
        wireMat.readsFromDepthBuffer = false

        var corners: [SCNVector3] = []
        for sx in [Float(-0.5), 0.5] {
            for sy in [Float(-0.5), 0.5] {
                for sz in [Float(-0.5), 0.5] { corners.append(SCNVector3(sx, sy, sz)) }
            }
        }
        // Corner index bits: x = 4, y = 2, z = 1. Two corners share an edge when
        // exactly one bit differs.
        var indices: [Int32] = []
        for i in 0..<8 {
            for bit in [4, 2, 1] where i & bit == 0 {
                indices.append(Int32(i))
                indices.append(Int32(i | bit))
            }
        }
        let wire = SCNGeometry(
            sources: [SCNGeometrySource(vertices: corners)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        wire.materials = [wireMat]
        container.addChildNode(SCNNode(geometry: wire))

        if selected {
            let fill = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
            let fillMat = SCNMaterial()
            fillMat.diffuse.contents = tint.withAlphaComponent(0.14)
            fillMat.lightingModel = .constant
            fillMat.isDoubleSided = true
            fillMat.writesToDepthBuffer = false
            fillMat.readsFromDepthBuffer = false
            fill.materials = [fillMat]
            container.addChildNode(SCNNode(geometry: fill))
        }

        container.renderingOrder = 100
        return container
    }

    /// Pin L/B/H to the edges of the selected object's box.
    ///
    /// Reads one cached handle rather than the live object list: this runs on
    /// the render thread, and the list is rebuilt on the main one by every
    /// merge, split and rescan.
    private func updateDimensionTags() {
        guard let arView, let selected = selectedBox else {
            DispatchQueue.main.async { [weak self] in self?.overlay?.updateDimensionTags([]) }
            return
        }
        let node = selected.node, dims = selected.dims
        func project(_ local: simd_float3) -> CGPoint? {
            let world = node.simdConvertPosition(local, to: nil)
            let p = arView.projectPoint(SCNVector3(world))
            guard p.z > 0, p.z < 1 else { return nil }
            return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        }
        let anchors: [(simd_float3, String, Float)] = [
            (simd_float3(0, -0.5, 0.5), "L", dims.x),
            (simd_float3(0.5, -0.5, 0), "B", dims.y),
            (simd_float3(0.5, 0, 0.5), "H", dims.z),
        ]
        var tags: [DimensionTag] = []
        for (local, prefix, metres) in anchors {
            guard let point = project(local) else { continue }
            tags.append(DimensionTag(point: point,
                                     text: "\(prefix) \(Int((metres * 100).rounded())) cm"))
        }
        DispatchQueue.main.async { [weak self] in self?.overlay?.updateDimensionTags(tags) }
    }

    // MARK: - YOLO (silent)

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
            print("[DepthCapture] YOLO model not found — name suggestions disabled"); return
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

    /// Detection is a naming convenience only, so the single interesting result
    /// is whatever covers the reticle: that is the thing being measured.
    private func runYOLO(on pixelBuffer: CVPixelBuffer) {
        guard let model = visionModel else { return }
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self, let results = req.results as? [VNRecognizedObjectObservation] else { return }
            let boxes = results.compactMap { obs -> DetectionBox? in
                guard let top = obs.labels.first, top.confidence > 0.35 else { return nil }
                let german = self.furnitureLabels[top.identifier] ?? ""
                // Skip non-furniture classes (person, handbag, …)
                guard !german.isEmpty else { return nil }
                let bb = obs.boundingBox
                return DetectionBox(label: top.identifier,
                                    germanLabel: german,
                                    confidence: top.confidence,
                                    x: Float(bb.minX), y: Float(1.0 - bb.maxY),
                                    w: Float(bb.width), h: Float(bb.height))
            }
            let center = simd_float2(0.5, 0.5)
            let best = boxes
                .filter { $0.contains(normalized: center) }
                .max(by: { $0.confidence < $1.confidence })
                ?? boxes.min(by: { $0.centerDistance < $1.centerDistance })
            let guess = best.map { $0.germanLabel.isEmpty ? $0.label : $0.germanLabel } ?? ""
            DispatchQueue.main.async { self.silentLabelGuess = guess }
        }
        request.imageCropAndScaleOption = .scaleFit
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right).perform([request])
    }

    // MARK: - Math helpers

    private func quaternionAngularDistance(_ q1: simd_quatf, _ q2: simd_quatf) -> Float {
        let dot = abs(simd_dot(q1.vector, q2.vector))
        return 2.0 * acos(min(max(dot, -1.0), 1.0)) * (180.0 / .pi)
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

        if sweeping { processSweepFrame(frame) }
        updateDimensionTags()

        // Keep a name suggestion warm for the manual sheet. Nothing is drawn.
        frameCounter += 1
        if frameCounter % yoloEveryNFrames == 0 {
            let buf = frame.capturedImage
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.runYOLO(on: buf) }
        }
    }
}

// MARK: - Overlay support types

/// A dimension readout pinned to the screen position of the edge it measures.
private struct DimensionTag {
    let point: CGPoint
    let text: String
}

/// Result of the manual-entry sheet: a volume the customer vouches for.
private struct ManualEntry {
    let label: String
    let volumeM3: Float
    /// Present when entered as L × W × H; absent when a volume was typed directly.
    let dims: simd_float3?
}

/// One object in the results list.
private struct ResultRow {
    let id: Int
    let label: String
    let volumeM3: Float
    let dims: simd_float3
}

// MARK: - ResultRowView

/// One found object: its volume, and an optional name.
///
/// The volume is set in the largest type on the row because it is the thing
/// being confirmed; the name is a text field the customer may simply ignore,
/// as everywhere else in this app.
private class ResultRowView: UIView, UITextFieldDelegate {
    let id: Int
    let nameField = UITextField()
    private let volumeLabel = UILabel()
    private let dimsLabel = UILabel()
    private let bullet = UIView()

    var onTap: ((Int) -> Void)?
    var onRename: ((Int, String) -> Void)?

    var isSelected = false {
        didSet {
            backgroundColor = isSelected
                ? UIColor(red: 252/255, green: 96/255, blue: 24/255, alpha: 0.14)
                : .clear
            bullet.backgroundColor = isSelected
                ? UIColor(red: 252/255, green: 96/255, blue: 24/255, alpha: 1)
                : UIColor(red: 200/255, green: 203/255, blue: 209/255, alpha: 1)
        }
    }

    init(row: ResultRow) {
        id = row.id
        super.init(frame: .zero)
        layer.cornerRadius = 14

        bullet.layer.cornerRadius = 5
        addSubview(bullet)

        volumeLabel.text = String(format: "%.2f m³", row.volumeM3)
        volumeLabel.font = .systemFont(ofSize: 19, weight: .bold)
        volumeLabel.textColor = UIColor(red: 2/255, green: 36/255, blue: 72/255, alpha: 1)
        addSubview(volumeLabel)

        dimsLabel.text = String(format: "%.0f × %.0f × %.0f cm",
                                row.dims.x * 100, row.dims.y * 100, row.dims.z * 100)
        dimsLabel.font = .systemFont(ofSize: 12, weight: .regular)
        dimsLabel.textColor = UIColor(red: 116/255, green: 119/255, blue: 127/255, alpha: 1)
        addSubview(dimsLabel)

        nameField.text = row.label
        nameField.placeholder = "Bezeichnung (optional)"
        nameField.font = .systemFont(ofSize: 15)
        nameField.textColor = UIColor(red: 2/255, green: 36/255, blue: 72/255, alpha: 1)
        nameField.backgroundColor = UIColor(red: 230/255, green: 232/255, blue: 234/255, alpha: 1)
        nameField.layer.cornerRadius = 10
        nameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        nameField.leftViewMode = .always
        nameField.returnKeyType = .done
        nameField.autocorrectionType = .no
        nameField.delegate = self
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        addSubview(nameField)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isSelected = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        bullet.frame = CGRect(x: 14, y: 20, width: 10, height: 10)
        volumeLabel.frame = CGRect(x: 34, y: 10, width: 130, height: 24)
        dimsLabel.frame = CGRect(x: 34, y: 34, width: 150, height: 16)
        nameField.frame = CGRect(x: 186, y: 14, width: bounds.width - 200, height: 36)
    }

    @objc private func tapped() { onTap?(id) }
    @objc private func nameChanged() {
        onRename?(id, nameField.text?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - ScanOverlayView (100% native UI)
//
// The flow is: sweep the room once, then confirm the objects that fell out of
// it. There is no per-object measuring ritual and no reticle — nothing here
// depends on an object fitting into one camera frame, because the mesh the
// objects come from does not.

private class ScanOverlayView: UIView, UITextFieldDelegate {

    enum State { case intro, sweeping, results, manual }

    // Callbacks
    var onClose: (() -> Void)?
    var onStartSweep: (() -> Void)?
    var onFinishSweep: (() -> Void)?
    var onSelect: ((Int) -> Void)?
    var onMerge: ((Int, Int) -> Void)?
    var onSplit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRename: ((Int, String) -> Void)?
    /// Hand the confirmed objects over and close the session.
    var onSubmit: (() -> Void)?
    var onManualRequested: (() -> Void)?
    var onManualSubmit: ((ManualEntry) -> Void)?
    var onManualCancel: (() -> Void)?

    /// False on devices without LiDAR — there is no mesh to subtract a room
    /// from, so the copy promises photos rather than metres.
    var canMeasure = true { didSet { updateIntro() } }

    private var state: State = .intro
    private var rows: [ResultRowView] = []
    private var selectedID: Int?
    /// Set while the customer is picking the second object of a merge.
    private var mergePending = false

    private static let navy = UIColor(red: 2/255, green: 36/255, blue: 72/255, alpha: 1)
    private static let orange = UIColor(red: 252/255, green: 96/255, blue: 24/255, alpha: 1)
    private static let cardBg = UIColor(red: 236/255, green: 238/255, blue: 240/255, alpha: 1)
    private static let fieldBg = UIColor(red: 230/255, green: 232/255, blue: 234/255, alpha: 1)
    private static let subtle = UIColor(red: 116/255, green: 119/255, blue: 127/255, alpha: 1)

    // ── Top bar ──────────────────────────────────────────────────────────
    private let countPill = UIView()
    private let countDot = UIView()
    private let countLabel = UILabel()
    private let closeBtn = UIButton(type: .system)

    // ── Intro ────────────────────────────────────────────────────────────
    private let introCard = UIView()
    private let introTitle = UILabel()
    private let introBody = UILabel()
    private let introStart = UIButton(type: .system)
    private let introManual = UIButton(type: .system)

    // ── Sweeping HUD ─────────────────────────────────────────────────────
    private let hud = UIView()
    private let sweepHint = UILabel()
    private let sweepStats = UILabel()
    private let sweepFinish = UIButton(type: .system)
    /// One label per dimension of the selected object, over the edge it names.
    private var dimLabels: [UILabel] = []

    // ── Results ──────────────────────────────────────────────────────────
    private let resultsCard = UIView()
    private let resultsTitle = UILabel()
    private let resultsScroll = UIScrollView()
    private let actionBar = UIView()
    private let mergeBtn = UIButton(type: .system)
    private let splitBtn = UIButton(type: .system)
    private let deleteBtn = UIButton(type: .system)
    private let totalLabel = UILabel()
    private let submitBtn = UIButton(type: .system)
    private let addManualBtn = UIButton(type: .system)

    // ── Toast ────────────────────────────────────────────────────────────
    private let toastLabel = UILabel()
    private var toastHideWork: DispatchWorkItem?

    // ── Manual card ──────────────────────────────────────────────────────
    private let manualCard = UIView()
    private let manualTitle = UILabel()
    private let manualSubtitle = UILabel()
    private let manualName = UITextField()
    private let manualMode = UISegmentedControl(items: ["Maße", "Volumen"])
    private let manualL = UITextField()
    private let manualW = UITextField()
    private let manualH = UITextField()
    private let manualVolume = UITextField()
    private let manualHint = UILabel()
    private let manualCancelBtn = UIButton(type: .system)
    private let manualSaveBtn = UIButton(type: .system)

    private var cardKeyboardShift: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        buildTopBar()
        buildIntro()
        buildHUD()
        buildResults()
        buildManualCard()
        addTapGesture()
        observeKeyboard()
        setState(.intro)
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

    private func buildIntro() {
        introCard.backgroundColor = Self.cardBg
        introCard.layer.cornerRadius = 24
        introCard.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(introCard)

        introTitle.text = "Raum erfassen"
        introTitle.font = .systemFont(ofSize: 26, weight: .bold)
        introTitle.textColor = Self.navy
        introCard.addSubview(introTitle)

        introBody.font = .systemFont(ofSize: 15)
        introBody.textColor = Self.subtle
        introBody.numberOfLines = 4
        introCard.addSubview(introBody)

        stylePrimary(introStart, title: "Erfassung starten")
        introStart.addTarget(self, action: #selector(startSweepTapped), for: .touchUpInside)
        introCard.addSubview(introStart)

        styleSecondary(introManual, title: "Maße eintragen")
        introManual.addTarget(self, action: #selector(manualTapped), for: .touchUpInside)
        introCard.addSubview(introManual)

        updateIntro()
    }

    private func buildHUD() {
        hud.isHidden = true
        addSubview(hud)

        sweepHint.text = "Gehen Sie langsam durch den Raum und richten Sie die Kamera auf alle Möbel."
        sweepHint.font = .systemFont(ofSize: 15, weight: .semibold)
        sweepHint.textColor = .white
        sweepHint.textAlignment = .center
        sweepHint.numberOfLines = 3
        sweepHint.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        sweepHint.layer.cornerRadius = 20
        sweepHint.clipsToBounds = true
        hud.addSubview(sweepHint)

        // Live count, so the sweep has visible progress without a progress bar
        // pretending to know how big the room is.
        sweepStats.font = .systemFont(ofSize: 26, weight: .bold)
        sweepStats.textColor = .white
        sweepStats.textAlignment = .center
        sweepStats.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        sweepStats.layer.cornerRadius = 22
        sweepStats.clipsToBounds = true
        sweepStats.text = "0 Objekte"
        hud.addSubview(sweepStats)

        sweepFinish.backgroundColor = Self.orange
        sweepFinish.layer.cornerRadius = 14
        sweepFinish.setTitle("Fertig", for: .normal)
        sweepFinish.setTitleColor(.white, for: .normal)
        sweepFinish.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        sweepFinish.addTarget(self, action: #selector(finishSweepTapped), for: .touchUpInside)
        hud.addSubview(sweepFinish)

        toastLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        toastLabel.textColor = .white
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 2
        toastLabel.backgroundColor = Self.orange.withAlphaComponent(0.94)
        toastLabel.layer.cornerRadius = 14
        toastLabel.clipsToBounds = true
        toastLabel.alpha = 0
        addSubview(toastLabel)
    }

    private func buildResults() {
        resultsCard.backgroundColor = Self.cardBg
        resultsCard.layer.cornerRadius = 24
        resultsCard.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        resultsCard.isHidden = true
        addSubview(resultsCard)

        resultsTitle.font = .systemFont(ofSize: 20, weight: .bold)
        resultsTitle.textColor = Self.navy
        resultsCard.addSubview(resultsTitle)

        resultsScroll.showsVerticalScrollIndicator = true
        resultsScroll.keyboardDismissMode = .interactive
        resultsCard.addSubview(resultsScroll)

        // Only meaningful with something selected, so it starts hidden rather
        // than disabled — a bar of dead buttons is worse than no bar.
        actionBar.isHidden = true
        resultsCard.addSubview(actionBar)
        styleSmall(mergeBtn, title: "Zusammenfassen")
        mergeBtn.addTarget(self, action: #selector(mergeTapped), for: .touchUpInside)
        actionBar.addSubview(mergeBtn)
        styleSmall(splitBtn, title: "Teilen")
        splitBtn.addTarget(self, action: #selector(splitTapped), for: .touchUpInside)
        actionBar.addSubview(splitBtn)
        styleSmall(deleteBtn, title: "Löschen")
        deleteBtn.setTitleColor(UIColor.systemRed, for: .normal)
        deleteBtn.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        actionBar.addSubview(deleteBtn)

        totalLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        totalLabel.textColor = Self.navy
        resultsCard.addSubview(totalLabel)

        styleSecondary(addManualBtn, title: "Objekt manuell")
        addManualBtn.addTarget(self, action: #selector(manualTapped), for: .touchUpInside)
        resultsCard.addSubview(addManualBtn)

        stylePrimary(submitBtn, title: "Weiter")
        submitBtn.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        resultsCard.addSubview(submitBtn)
    }

    private func buildManualCard() {
        manualCard.backgroundColor = Self.cardBg
        manualCard.layer.cornerRadius = 24
        manualCard.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        manualCard.isHidden = true
        addSubview(manualCard)

        manualTitle.text = "Maße eintragen"
        manualTitle.font = .systemFont(ofSize: 22, weight: .bold)
        manualTitle.textColor = Self.navy
        manualCard.addSubview(manualTitle)

        manualSubtitle.text = "Für Glas, Spiegel und alles, was der Scan nicht sieht."
        manualSubtitle.font = .systemFont(ofSize: 13)
        manualSubtitle.textColor = Self.subtle
        manualSubtitle.numberOfLines = 2
        manualCard.addSubview(manualSubtitle)

        styleField(manualName, placeholder: "Bezeichnung (optional)")
        manualCard.addSubview(manualName)

        manualMode.selectedSegmentIndex = 0
        manualMode.addTarget(self, action: #selector(manualModeChanged), for: .valueChanged)
        manualCard.addSubview(manualMode)

        styleField(manualL, placeholder: "Länge cm")
        styleField(manualW, placeholder: "Breite cm")
        styleField(manualH, placeholder: "Höhe cm")
        styleField(manualVolume, placeholder: "Volumen m³")
        for f in [manualL, manualW, manualH, manualVolume] {
            f.keyboardType = .decimalPad
            manualCard.addSubview(f)
        }

        manualHint.font = .systemFont(ofSize: 12)
        manualHint.textColor = UIColor(red: 142/255, green: 145/255, blue: 152/255, alpha: 1)
        manualHint.numberOfLines = 2
        manualCard.addSubview(manualHint)

        styleSecondary(manualCancelBtn, title: "Abbrechen")
        manualCancelBtn.addTarget(self, action: #selector(manualCancelTapped), for: .touchUpInside)
        manualCard.addSubview(manualCancelBtn)

        stylePrimary(manualSaveBtn, title: "Sichern")
        manualSaveBtn.addTarget(self, action: #selector(manualSaveTapped), for: .touchUpInside)
        manualCard.addSubview(manualSaveBtn)

        updateManualMode()
    }

    private func styleField(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.font = .systemFont(ofSize: 16)
        field.textColor = Self.navy
        field.backgroundColor = Self.fieldBg
        field.layer.cornerRadius = 12
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.returnKeyType = .done
        field.delegate = self
    }

    private func stylePrimary(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        button.backgroundColor = Self.orange
        button.layer.cornerRadius = 14
    }

    private func styleSecondary(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(Self.navy, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = UIColor.white
        button.layer.cornerRadius = 14
    }

    private func styleSmall(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(Self.navy, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.backgroundColor = .white
        button.layer.cornerRadius = 11
    }

    private func addTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let safeTop = safeAreaInsets.top
        let safeBottom = safeAreaInsets.bottom
        let w = bounds.width, h = bounds.height

        countPill.frame = CGRect(x: 16, y: safeTop + 10, width: 132, height: 32)
        countDot.frame = CGRect(x: 12, y: 12, width: 8, height: 8)
        countLabel.frame = CGRect(x: 28, y: 0, width: 100, height: 32)
        closeBtn.frame = CGRect(x: w - 56, y: safeTop + 6, width: 40, height: 40)

        // Intro
        let introHeight: CGFloat = 268 + safeBottom
        introCard.frame = CGRect(x: 0, y: h - introHeight, width: w, height: introHeight)
        introTitle.frame = CGRect(x: 22, y: 24, width: w - 44, height: 32)
        introBody.frame = CGRect(x: 22, y: 62, width: w - 44, height: 82)
        introStart.frame = CGRect(x: 22, y: 156, width: w - 44, height: 52)
        introManual.frame = CGRect(x: 22, y: 216, width: w - 44, height: 44)

        // Sweeping
        hud.frame = bounds
        sweepHint.frame = CGRect(x: 24, y: safeTop + 62, width: w - 48, height: 76)
        sweepStats.frame = CGRect(x: w / 2 - 96, y: h - safeBottom - 148, width: 192, height: 44)
        sweepFinish.frame = CGRect(x: 24, y: h - safeBottom - 88, width: w - 48, height: 54)

        // Results
        let resultsHeight = min(h * 0.66, 520) + safeBottom
        resultsCard.frame = CGRect(x: 0, y: h - resultsHeight + cardKeyboardShift,
                                   width: w, height: resultsHeight)
        resultsTitle.frame = CGRect(x: 22, y: 20, width: w - 44, height: 26)
        let listTop: CGFloat = 56
        let footerHeight: CGFloat = 132 + safeBottom
        let barHeight: CGFloat = actionBar.isHidden ? 0 : 44
        resultsScroll.frame = CGRect(x: 14, y: listTop, width: w - 28,
                                     height: max(80, resultsHeight - listTop - footerHeight - barHeight))
        layoutRows()
        actionBar.frame = CGRect(x: 14, y: resultsScroll.frame.maxY + 4, width: w - 28, height: barHeight)
        let third = (w - 28 - 16) / 3
        mergeBtn.frame = CGRect(x: 0, y: 2, width: third, height: 36)
        splitBtn.frame = CGRect(x: third + 8, y: 2, width: third, height: 36)
        deleteBtn.frame = CGRect(x: 2 * third + 16, y: 2, width: third, height: 36)

        let footerTop = resultsCard.bounds.height - footerHeight
        totalLabel.frame = CGRect(x: 22, y: footerTop + 4, width: w - 44, height: 22)
        addManualBtn.frame = CGRect(x: 22, y: footerTop + 30, width: w - 44, height: 40)
        submitBtn.frame = CGRect(x: 22, y: footerTop + 76, width: w - 44, height: 52)

        // Manual card
        let manualHeight: CGFloat = 452 + safeBottom
        manualCard.frame = CGRect(x: 0, y: h - manualHeight + cardKeyboardShift, width: w, height: manualHeight)
        manualTitle.frame = CGRect(x: 22, y: 22, width: w - 44, height: 28)
        manualSubtitle.frame = CGRect(x: 22, y: 52, width: w - 44, height: 34)
        manualName.frame = CGRect(x: 22, y: 94, width: w - 44, height: 48)
        manualMode.frame = CGRect(x: 22, y: 152, width: w - 44, height: 34)
        let fieldWidth = (w - 44 - 16) / 3
        manualL.frame = CGRect(x: 22, y: 198, width: fieldWidth, height: 48)
        manualW.frame = CGRect(x: 22 + fieldWidth + 8, y: 198, width: fieldWidth, height: 48)
        manualH.frame = CGRect(x: 22 + 2 * (fieldWidth + 8), y: 198, width: fieldWidth, height: 48)
        manualVolume.frame = CGRect(x: 22, y: 198, width: w - 44, height: 48)
        manualHint.frame = CGRect(x: 22, y: 252, width: w - 44, height: 34)
        manualCancelBtn.frame = CGRect(x: 22, y: 296, width: w - 44, height: 44)
        manualSaveBtn.frame = CGRect(x: 22, y: 348, width: w - 44, height: 52)

        toastLabel.frame = CGRect(x: 30, y: safeTop + 150, width: w - 60, height: 46)
    }

    private func layoutRows() {
        let rowHeight: CGFloat = 64
        let width = resultsScroll.bounds.width
        for (i, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(i) * (rowHeight + 6), width: width, height: rowHeight)
        }
        resultsScroll.contentSize = CGSize(
            width: width,
            height: CGFloat(rows.count) * (rowHeight + 6))
    }

    // MARK: - State

    func setState(_ newState: State) {
        state = newState
        introCard.isHidden = newState != .intro
        hud.isHidden = newState != .sweeping
        resultsCard.isHidden = newState != .results
        manualCard.isHidden = newState != .manual
        if newState != .manual && newState != .results {
            endEditing(true)
            cardKeyboardShift = 0
        }
        if newState != .results {
            selectedID = nil
            mergePending = false
            actionBar.isHidden = true
        }
        if newState != .sweeping { updateDimensionTags([]) }
        setNeedsLayout()
    }

    func updateItemCount(_ count: Int) {
        countLabel.text = count == 1 ? "1 Objekt" : "\(count) Objekte"
        countDot.backgroundColor = count > 0
            ? Self.orange
            : UIColor.white.withAlphaComponent(0.3)
    }

    private func updateIntro() {
        introBody.text = canMeasure
            ? "Wir erfassen den Raum einmal komplett und erkennen daraus jedes Möbelstück mit seinem Volumen. Danach prüfen Sie die Liste."
            : "Dieses Gerät hat keinen LiDAR-Sensor. Wir nehmen Fotos auf und ermitteln die Volumen anschließend für Sie."
        introStart.setTitle(canMeasure ? "Erfassung starten" : "Aufnahme starten", for: .normal)
    }

    // MARK: - Sweeping feedback

    /// Live count during the sweep. Objects appear as they are found, which is
    /// the only honest progress signal — nothing here knows how big the room is.
    func updateSweep(objectCount: Int, totalVolume: Float) {
        sweepStats.text = objectCount == 0
            ? "suche…"
            : String(format: "%d Objekte · %.1f m³", objectCount, totalVolume)
        updateItemCount(objectCount)
    }

    /// Dimension readouts for the selected object, pinned to its box edges.
    func updateDimensionTags(_ tags: [DimensionTag]) {
        while dimLabels.count < tags.count {
            let label = UILabel()
            label.font = .systemFont(ofSize: 13, weight: .bold)
            label.textColor = .white
            label.textAlignment = .center
            label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
            label.layer.cornerRadius = 9
            label.clipsToBounds = true
            addSubview(label)
            dimLabels.append(label)
        }
        for (i, label) in dimLabels.enumerated() {
            guard i < tags.count else { label.isHidden = true; continue }
            let tag = tags[i]
            label.isHidden = false
            label.text = tag.text
            let size = CGSize(width: 88, height: 24)
            label.frame = CGRect(x: tag.point.x - size.width / 2,
                                 y: tag.point.y - size.height / 2,
                                 width: size.width, height: size.height)
        }
    }

    // MARK: - Results

    func showResults(_ newRows: [ResultRow]) {
        for row in rows { row.removeFromSuperview() }
        rows = newRows.map { row in
            let view = ResultRowView(row: row)
            view.onTap = { [weak self] id in self?.rowTapped(id) }
            view.onRename = { [weak self] id, text in self?.onRename?(id, text) }
            resultsScroll.addSubview(view)
            return view
        }
        let total = newRows.reduce(Float(0)) { $0 + $1.volumeM3 }
        resultsTitle.text = newRows.isEmpty
            ? "Nichts gefunden"
            : (newRows.count == 1 ? "1 Objekt gefunden" : "\(newRows.count) Objekte gefunden")
        totalLabel.text = String(format: "Gesamt %.1f m³", total)
        submitBtn.isEnabled = !newRows.isEmpty
        submitBtn.alpha = newRows.isEmpty ? 0.4 : 1
        updateItemCount(newRows.count)
        applySelection()
        setNeedsLayout()
    }

    /// Highlight one row from the outside — used when the plugin re-selects
    /// after a merge or a split.
    func selectRow(_ id: Int?) {
        selectedID = id
        applySelection()
    }

    private func rowTapped(_ id: Int) {
        if mergePending, let first = selectedID, first != id {
            mergePending = false
            onMerge?(first, id)
            return
        }
        mergePending = false
        selectedID = (selectedID == id) ? nil : id
        applySelection()
        onSelect?(selectedID ?? -1)
    }

    private func applySelection() {
        for row in rows { row.isSelected = row.id == selectedID }
        let hadBar = actionBar.isHidden
        actionBar.isHidden = selectedID == nil
        splitBtn.isEnabled = !mergePending
        mergeBtn.setTitle(mergePending ? "Zweites wählen…" : "Zusammenfassen", for: .normal)
        if hadBar != actionBar.isHidden { setNeedsLayout() }
    }

    /// The id the plugin should act on, or nil.
    var selection: Int? { selectedID }

    // MARK: - Toast

    func showToast(_ text: String) {
        toastHideWork?.cancel()
        toastLabel.text = text
        bringSubviewToFront(toastLabel)
        UIView.animate(withDuration: 0.18) { self.toastLabel.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in self?.hideToast() }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    func hideToast() {
        toastHideWork?.cancel()
        UIView.animate(withDuration: 0.2) { self.toastLabel.alpha = 0 }
    }

    // MARK: - Manual entry

    func showManualEntry(suggestedLabel: String) {
        manualName.text = suggestedLabel
        manualL.text = ""; manualW.text = ""; manualH.text = ""; manualVolume.text = ""
        for f in [manualL, manualW, manualH, manualVolume] { f.layer.borderWidth = 0 }
        setState(.manual)
        manualCard.transform = CGAffineTransform(translationX: 0, y: manualCard.bounds.height)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.86,
                       initialSpringVelocity: 0.4, options: [.curveEaseOut]) {
            self.manualCard.transform = .identity
        }
    }

    @objc private func manualModeChanged() { updateManualMode() }

    private func updateManualMode() {
        let dimsMode = manualMode.selectedSegmentIndex == 0
        manualL.isHidden = !dimsMode
        manualW.isHidden = !dimsMode
        manualH.isHidden = !dimsMode
        manualVolume.isHidden = dimsMode
        manualHint.text = dimsMode
            ? "Wir rechnen Packmaß und Ladevolumen automatisch dazu."
            : "Das Volumen übernehmen wir genau so, wie Sie es eintragen."
    }

    // MARK: - Keyboard

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = max(0, bounds.height - frame.origin.y)
        cardKeyboardShift = -overlap * 0.86
        animateCardShift()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        cardKeyboardShift = 0
        animateCardShift()
    }

    private func animateCardShift() {
        UIView.animate(withDuration: 0.24) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    // MARK: - Actions

    @objc private func closeTapped() { onClose?() }
    @objc private func startSweepTapped() { onStartSweep?() }
    @objc private func finishSweepTapped() { onFinishSweep?() }
    @objc private func submitTapped() { endEditing(true); onSubmit?() }
    @objc private func manualTapped() { onManualRequested?() }
    @objc private func manualCancelTapped() { endEditing(true); onManualCancel?() }
    @objc private func deleteTapped() { onDelete?() }
    @objc private func splitTapped() { onSplit?() }

    /// Merging needs two objects, so the first tap arms it and the next row tap
    /// completes it. Anything else — including tapping the same row again —
    /// disarms, because a half-armed mode the customer forgot about is how you
    /// end up merging a wardrobe into a lamp.
    @objc private func mergeTapped() {
        guard selectedID != nil else { return }
        mergePending.toggle()
        applySelection()
        if mergePending { showToast("Zweites Objekt antippen") } else { hideToast() }
    }

    @objc private func manualSaveTapped() {
        endEditing(true)
        let label = manualName.text?.trimmingCharacters(in: .whitespaces) ?? ""
        func number(_ field: UITextField) -> Float? {
            let text = (field.text ?? "").replacingOccurrences(of: ",", with: ".")
            guard let value = Float(text), value > 0 else { return nil }
            return value
        }
        if manualMode.selectedSegmentIndex == 0 {
            guard let l = number(manualL), let w = number(manualW), let h = number(manualH) else {
                flagManual([manualL, manualW, manualH])
                return
            }
            let dims = simd_float3(l / 100, w / 100, h / 100)
            let volume = dims.x * dims.y * dims.z * RoomScanner.packingFactor
            onManualSubmit?(ManualEntry(label: label, volumeM3: volume, dims: dims))
        } else {
            guard let v = number(manualVolume) else {
                flagManual([manualVolume])
                return
            }
            onManualSubmit?(ManualEntry(label: label, volumeM3: v, dims: nil))
        }
    }

    private func flagManual(_ fields: [UITextField]) {
        for f in fields where (f.text ?? "").isEmpty || Float((f.text ?? "").replacingOccurrences(of: ",", with: ".")) == nil {
            f.layer.borderWidth = 1.5
            f.layer.borderColor = UIColor.systemRed.cgColor
        }
        showToast("Bitte gültige Zahlen eintragen")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if state == .manual, !manualCard.frame.contains(point) { endEditing(true) }
        if state == .results, !resultsCard.frame.contains(point) { endEditing(true) }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
