import ARKit
import CoreImage
import Foundation
import RoomPlan
import UIKit
import simd

/// Measures what RoomPlan saw but doesn't have a category for: a walker, a
/// stroller, a floor lamp, a pile of toys.
///
/// RoomPlan only recognises 16 kinds of furniture. Everything else is still in
/// the geometry it scanned, so this runs alongside it, on the same ARSession:
/// while the customer walks the room it collects the scene's 3D points (the
/// fused mesh when the session exposes one, otherwise its LiDAR depth frames)
/// and a camera photo every second. Once RoomPlan has built the room, every
/// point that belongs to something RoomPlan already knows — a wall, the floor,
/// the ceiling, a door, a window, one of its furniture boxes — is deleted.
/// What remains falls apart into islands; each island is an object, measured
/// with a gravity-aligned box and photographed from the keyframe that saw it
/// best.
///
/// The subtraction is what the earlier mesh-only capture did, with RoomPlan's
/// walls and furniture in place of guessed planes — so only the leftovers are
/// ours to get wrong, never the sofa.
final class LeftoverScanner {

    struct Leftover {
        /// [length, width, height] in metres, length ≥ width.
        let dims: simd_float3
        /// JPEG, base64, upright — the keyframe crop that shows the object best.
        let imageBase64: String?
        /// Its four footprint corners in world x/z, for the floor plan.
        let footprint: [simd_float2]
    }

    private struct Keyframe {
        let jpeg: Data
        /// Camera → world.
        let transform: simd_float4x4
        /// Intrinsics at the stored (downscaled, landscape) resolution.
        let fx: Float, fy: Float, cx: Float, cy: Float
        let width: Float, height: Float
    }

    // MARK: Tuning

    /// Grid the scene's points are deduplicated (and depth fused) onto.
    private static let voxel: Float = 0.03
    /// Clustering resolution: bridges holes in thin parts (a walker's frame)
    /// while a chair next to a table usually stays its own island.
    private static let clusterVoxel: Float = 0.07
    /// A depth voxel counts once this many samples have hit it — single hits
    /// are LiDAR noise.
    private static let minDepthHits: UInt8 = 3
    /// How close to a wall / door / window a point has to be to be part of it.
    fileprivate static let surfaceClearance: Float = 0.08
    /// Margin around RoomPlan's furniture boxes: their faces sit on the surface,
    /// and the mesh around them is a few centimetres proud of it.
    fileprivate static let objectMargin: Float = 0.06
    fileprivate static let floorClearance: Float = 0.05
    fileprivate static let ceilingClearance: Float = 0.10
    private static let minPoints = 25
    /// Every side at least this long — below it, an island is mesh noise.
    private static let minSide: Float = 0.08
    /// A box bigger than this is a mis-subtracted wall or a whole kitchen run.
    private static let maxBoxVolume: Float = 6.0
    /// Anything hovering this far above the floor hangs from wall or ceiling:
    /// lamps, shelves, wall cupboards. Not part of a move.
    private static let maxBottomAboveFloor: Float = 1.2
    /// Flat things right against a wall are radiators, pictures, curtains.
    private static let wallHuggerWidth: Float = 0.15
    private static let wallHuggerDistance: Float = 0.30
    private static let maxPhotos = 40

    private static let structureClasses: Set<UInt8> = [
        UInt8(ARMeshClassification.wall.rawValue),
        UInt8(ARMeshClassification.floor.rawValue),
        UInt8(ARMeshClassification.ceiling.rawValue),
        UInt8(ARMeshClassification.window.rawValue),
        UInt8(ARMeshClassification.door.rawValue),
    ]

    // MARK: State

    /// Everything below `queue` is touched only on it; `meshAnchors` only on main.
    private let queue = DispatchQueue(label: "roomplan.leftovers", qos: .userInitiated)
    private var meshAnchors: [ARMeshAnchor] = []
    private var depthHits: [SIMD3<Int32>: UInt8] = [:]
    private var depthFrames = 0
    private var depthBusy = false
    private var keyframes: [Keyframe] = []
    private var lastDepth: TimeInterval = 0
    private var lastKeyframe: TimeInterval = 0
    private let ciContext = CIContext()

    // MARK: Sampling (main thread)

    /// Called a few times a second with the session's current frame. Copies
    /// what it needs and lets go of the frame at once — holding ARFrames
    /// starves the session of buffers.
    func sample(_ frame: ARFrame) {
        let meshes = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if !meshes.isEmpty { meshAnchors = meshes }

        let t = frame.timestamp
        if t - lastDepth >= 0.5, let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
            lastDepth = t
            sampleDepth(depth, frame: frame)
        }
        if t - lastKeyframe >= 1.0 {
            lastKeyframe = t
            sampleKeyframe(frame)
        }
    }

    private func sampleDepth(_ depth: ARDepthData, frame: ARFrame) {
        let map = depth.depthMap
        guard !depthBusy, CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)

        CVPixelBufferLockBaseAddress(map, .readOnly)
        var values = [Float](repeating: 0, count: w * h)
        if let base = CVPixelBufferGetBaseAddress(map) {
            let rowBytes = CVPixelBufferGetBytesPerRow(map)
            let row = w * MemoryLayout<Float>.size
            values.withUnsafeMutableBytes { dst in
                for y in 0..<h { memcpy(dst.baseAddress! + y * row, base + y * rowBytes, row) }
            }
        }
        CVPixelBufferUnlockBaseAddress(map, .readOnly)

        var confidence: [UInt8]? = nil
        if let conf = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(conf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(conf)
                var c = [UInt8](repeating: 0, count: w * h)
                c.withUnsafeMutableBytes { dst in
                    for y in 0..<h { memcpy(dst.baseAddress! + y * w, base + y * rowBytes, w) }
                }
                confidence = c
            }
            CVPixelBufferUnlockBaseAddress(conf, .readOnly)
        }

        // Intrinsics are for the full camera image; scale them to the depth map.
        let image = frame.camera.imageResolution
        let sx = Float(w) / Float(image.width), sy = Float(h) / Float(image.height)
        let k = frame.camera.intrinsics
        let fx = k[0][0] * sx, fy = k[1][1] * sy, cx = k[2][0] * sx, cy = k[2][1] * sy
        let transform = frame.camera.transform

        depthBusy = true
        queue.async {
            self.fuse(values, confidence: confidence, width: w, height: h,
                      fx: fx, fy: fy, cx: cx, cy: cy, transform: transform)
            DispatchQueue.main.async { self.depthBusy = false }
        }
    }

    /// Unproject every other depth pixel and count it into its voxel.
    private func fuse(_ depth: [Float], confidence: [UInt8]?, width: Int, height: Int,
                      fx: Float, fy: Float, cx: Float, cy: Float, transform: simd_float4x4) {
        let high = UInt8(ARConfidenceLevel.high.rawValue)
        for v in stride(from: 0, to: height, by: 2) {
            for u in stride(from: 0, to: width, by: 2) {
                let i = v * width + u
                if let confidence, confidence[i] < high { continue }
                let d = depth[i]
                guard d > 0.3, d < 4.0 else { continue }
                // Pixel rays are y-down / z-forward; ARKit's camera is y-up / z-back.
                let x: Float = (Float(u) - cx) / fx * d
                let y: Float = -(Float(v) - cy) / fy * d
                let local = simd_float4(x, y, -d, 1)
                let p: simd_float4 = transform * local
                let world = simd_float3(p.x, p.y, p.z)
                let cell = Self.cell(world, Self.voxel)
                let n = depthHits[cell] ?? 0
                if n < .max { depthHits[cell] = n + 1 }
            }
        }
        depthFrames += 1
    }

    private func sampleKeyframe(_ frame: ARFrame) {
        // ~720 px on the long side: enough to crop one object and name it.
        let image = frame.camera.imageResolution
        let scale = 720 / max(image.width, image.height)
        let ci = CIImage(cvPixelBuffer: frame.capturedImage)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Rendered here, synchronously, so no reference to the frame's buffer survives.
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let k = frame.camera.intrinsics
        let s = Float(scale)
        let transform = frame.camera.transform
        queue.async {
            guard let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.75) else { return }
            self.keyframes.append(Keyframe(
                jpeg: jpeg, transform: transform,
                fx: k[0][0] * s, fy: k[1][1] * s, cx: k[2][0] * s, cy: k[2][1] * s,
                width: Float(cg.width), height: Float(cg.height)))
            // A long scan keeps every other frame rather than growing without bound.
            if self.keyframes.count > 160 {
                self.keyframes = self.keyframes.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            }
        }
    }

    // MARK: Result

    /// Subtract `room` from the collected points and measure what is left.
    /// Calls back on the main thread.
    func leftovers(in room: CapturedRoom,
                   completion: @escaping ([Leftover], [String: Any]) -> Void) {
        let meshes = meshAnchors
        queue.async {
            var diagnostics: [String: Any] = [
                "meshAnchors": meshes.count,
                "depthFrames": self.depthFrames,
                "keyframes": self.keyframes.count,
                "walls": room.walls.count,
                "roomObjects": room.objects.count,
            ]
            let points: [simd_float3]
            if !meshes.isEmpty {
                points = Self.meshPoints(meshes)
                diagnostics["source"] = "mesh"
            } else if !self.depthHits.isEmpty {
                var fused: [simd_float3] = []
                for (cell, hits) in self.depthHits where hits >= Self.minDepthHits {
                    let corner = simd_float3(Float(cell.x), Float(cell.y), Float(cell.z))
                    fused.append((corner + simd_float3(repeating: 0.5)) * Self.voxel)
                }
                points = fused
                diagnostics["source"] = "depth"
            } else {
                points = []
                diagnostics["source"] = "none"
            }
            diagnostics["points"] = points.count

            let result = self.measure(points, room: room, diagnostics: &diagnostics)
            diagnostics["leftovers"] = result.count
            DispatchQueue.main.async { completion(result, diagnostics) }
        }
    }

    private func measure(_ points: [simd_float3], room: CapturedRoom,
                         diagnostics: inout [String: Any]) -> [Leftover] {
        let geometry = RoomGeometry(room: room, points: points)
        let kept = points.filter { !geometry.contains($0) }
        diagnostics["kept"] = kept.count

        let clusters = RoomGeometry.cluster(kept, voxel: Self.clusterVoxel)
        diagnostics["clusters"] = clusters.count

        var boxes: [(box: Box, rejected: Bool)] = []
        var rejections: [String: Int] = [:]
        for cluster in clusters where cluster.count >= Self.minPoints {
            guard let box = Box.fit(cluster) else { continue }
            let reason: String?
            if min(box.dims.x, box.dims.y, box.dims.z) < Self.minSide {
                reason = "tiny"
            } else if box.volume > Self.maxBoxVolume {
                reason = "huge"
            } else if let floor = geometry.floorY, box.bottom > floor + Self.maxBottomAboveFloor {
                reason = "hanging"
            } else if box.dims.y < Self.wallHuggerWidth, geometry.distanceToWall(box.center) < Self.wallHuggerDistance {
                reason = "onWall"
            } else {
                reason = nil
            }
            if let reason { rejections[reason, default: 0] += 1 }
            boxes.append((box, reason != nil))
        }
        diagnostics["rejected"] = rejections

        var accepted: [Box] = []
        for entry in boxes where !entry.rejected { accepted.append(entry.box) }
        accepted.sort { (a: Box, b: Box) -> Bool in a.volume > b.volume }
        var leftovers: [Leftover] = []
        var photos = 0
        for (index, box) in accepted.enumerated() {
            let image = index < Self.maxPhotos ? photo(of: box) : nil
            if image != nil { photos += 1 }
            leftovers.append(Leftover(dims: box.dims, imageBase64: image, footprint: box.footprint))
        }
        diagnostics["photos"] = photos
        return leftovers
    }

    // MARK: Photos

    /// Crop the keyframe that shows `box` most centred, most fully, from a
    /// sensible distance — upright, as the customer held the phone.
    ///
    /// Only the box's centre has to be in view: close up, a tall object's top
    /// is often cut off in every frame, and a partial photo still says what it is.
    private func photo(of box: Box) -> String? {
        let corners = box.corners
        var best: (score: Float, frame: Keyframe, rect: CGRect)?
        for frame in keyframes {
            let view = simd_inverse(frame.transform)
            let imageSize = simd_float2(frame.width, frame.height)
            guard let center = project(box.center, view: view, frame: frame) else { continue }
            let margin: simd_float2 = imageSize * 0.05
            guard center.x > margin.x, center.y > margin.y,
                  center.x < imageSize.x - margin.x, center.y < imageSize.y - margin.y else { continue }

            var lo = center, hi = center
            for c in corners {
                guard let uv = project(c, view: view, frame: frame) else { continue }
                lo = simd_min(lo, uv); hi = simd_max(hi, uv)
            }
            let extent: simd_float2 = hi - lo
            let area: Float = max(extent.x * extent.y, 1)
            let clipLo: simd_float2 = simd_max(lo, simd_float2(0, 0))
            let clipHi: simd_float2 = simd_min(hi, imageSize)
            let clipped: simd_float2 = simd_max(clipHi - clipLo, simd_float2(0, 0))
            let inside: Float = clipped.x * clipped.y / area

            let offset: Float = simd_length((center - imageSize * 0.5) / imageSize)
            let boxInView: simd_float4 = view * simd_float4(box.center, 1)
            let distance: Float = max(-boxInView.z, 0.1)
            let framing: Float = abs(log(distance / 1.8))
            let score: Float = 0.5 * inside - offset - 0.3 * framing
            if best == nil || score > best!.score {
                let rect = CGRect(x: CGFloat(clipLo.x), y: CGFloat(clipLo.y),
                                  width: CGFloat(clipped.x), height: CGFloat(clipped.y))
                best = (score, frame, rect)
            }
        }
        guard let best, let source = UIImage(data: best.frame.jpeg)?.cgImage else { return nil }

        // Some context around the object, never less than a thumbnail's worth.
        let side = max(best.rect.width, best.rect.height) * 1.3
        let size = max(side, 200)
        var crop = CGRect(x: best.rect.midX - size / 2, y: best.rect.midY - size / 2, width: size, height: size)
        crop = crop.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height)).integral
        guard !crop.isEmpty, let cropped = source.cropping(to: crop) else { return nil }

        // The camera's buffer is landscape; the customer held the phone upright.
        let upright = UIImage(cgImage: cropped, scale: 1, orientation: .right)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: upright.size, format: format).image { _ in
            upright.draw(in: CGRect(origin: .zero, size: upright.size))
        }
        return rendered.jpegData(compressionQuality: 0.8)?.base64EncodedString()
    }

    /// Pixel position of world point `p` in a keyframe, or nil when it is behind the camera.
    private func project(_ p: simd_float3, view: simd_float4x4, frame: Keyframe) -> simd_float2? {
        let c: simd_float4 = view * simd_float4(p, 1)
        guard c.z < -0.2 else { return nil }
        let depth: Float = -c.z
        let u: Float = frame.fx * c.x / depth + frame.cx
        let v: Float = frame.fy * -c.y / depth + frame.cy
        return simd_float2(u, v)
    }

    // MARK: Mesh

    /// Mesh vertices in world space, minus faces ARKit classified as structure,
    /// deduplicated onto the voxel grid.
    private static func meshPoints(_ anchors: [ARMeshAnchor]) -> [simd_float3] {
        var occupied = Set<SIMD3<Int32>>()
        var points: [simd_float3] = []
        for anchor in anchors {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces
            guard faces.indexCountPerPrimitive == 3 else { continue }
            let classification = geometry.classification
            let vertexBase = vertices.buffer.contents()
            let faceBase = faces.buffer.contents()
            let transform = anchor.transform

            // Three packed Floats at `stride` — not a simd_float3, whose 16-byte
            // alignment doesn't match ARKit's 12-byte stride.
            func vertex(_ index: Int) -> simd_float3 {
                let p = vertexBase.advanced(by: vertices.offset + vertices.stride * index)
                    .assumingMemoryBound(to: Float.self)
                let world = transform * simd_float4(p[0], p[1], p[2], 1)
                return simd_float3(world.x, world.y, world.z)
            }
            func index(_ i: Int) -> Int {
                Int(faceBase.advanced(by: i * faces.bytesPerIndex).assumingMemoryBound(to: UInt32.self).pointee)
            }
            func faceClass(_ face: Int) -> UInt8? {
                guard let classification else { return nil }
                return classification.buffer.contents()
                    .advanced(by: classification.offset + classification.stride * face)
                    .assumingMemoryBound(to: UInt8.self).pointee
            }

            for face in 0..<faces.count {
                if let c = faceClass(face), structureClasses.contains(c) { continue }
                for corner in 0..<3 {
                    let p = vertex(index(face * 3 + corner))
                    if occupied.insert(cell(p, voxel)).inserted { points.append(p) }
                }
            }
        }
        return points
    }

    fileprivate static func cell(_ p: simd_float3, _ size: Float) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32(floor(p.x / size)), Int32(floor(p.y / size)), Int32(floor(p.z / size)))
    }
}

// MARK: - RoomGeometry

/// RoomPlan's room as something points can be tested against.
private struct RoomGeometry {
    /// A wall, door, window or opening: a rectangle in its local x/y, normal along z.
    struct Slab {
        let inverse: simd_float4x4
        let half: simd_float2
    }

    /// A furniture box, centred on its transform.
    struct Solid {
        let inverse: simd_float4x4
        let half: simd_float3
    }

    let walls: [Slab]
    let slabs: [Slab]
    let solids: [Solid]
    let floorY: Float?
    let ceilingY: Float?
    /// The walls' footprint as segments in x/z, for an inside-the-room test.
    let outline: [(simd_float2, simd_float2)]

    init(room: CapturedRoom, points: [simd_float3]) {
        func slab(_ s: CapturedRoom.Surface) -> Slab {
            let half = simd_float2(s.dimensions.x, s.dimensions.y) * 0.5
            return Slab(inverse: simd_inverse(s.transform), half: half)
        }
        walls = room.walls.map(slab)
        slabs = (room.walls + room.doors + room.windows + room.openings).map(slab)
        solids = room.objects.map { (o: CapturedRoom.Object) -> Solid in
            Solid(inverse: simd_inverse(o.transform), half: o.dimensions * 0.5)
        }

        var floor: Float? = nil
        if #available(iOS 17.0, *), !room.floors.isEmpty {
            floor = room.floors.map { (f: CapturedRoom.Surface) -> Float in f.transform.columns.3.y }.min()
        }
        if floor == nil, !room.walls.isEmpty {
            floor = room.walls.map { (w: CapturedRoom.Surface) -> Float in w.transform.columns.3.y - w.dimensions.y * 0.5 }.min()
        }
        if floor == nil, !points.isEmpty {
            let ys: [Float] = points.map { (p: simd_float3) -> Float in p.y }.sorted()
            floor = ys[ys.count / 50]
        }
        floorY = floor
        ceilingY = room.walls.map { (w: CapturedRoom.Surface) -> Float in w.transform.columns.3.y + w.dimensions.y * 0.5 }.max()

        outline = room.walls.map { (wall: CapturedRoom.Surface) -> (simd_float2, simd_float2) in
            let c = simd_float2(wall.transform.columns.3.x, wall.transform.columns.3.z)
            let axis = simd_float2(wall.transform.columns.0.x, wall.transform.columns.0.z)
            let reach: simd_float2 = axis * (wall.dimensions.x * 0.5)
            return (c - reach, c + reach)
        }
    }

    /// True when `p` is part of what RoomPlan already accounts for, or outside the room.
    func contains(_ p: simd_float3) -> Bool {
        if let floorY, p.y < floorY + LeftoverScanner.floorClearance { return true }
        if let ceilingY, p.y > ceilingY - LeftoverScanner.ceilingClearance { return true }
        let h = simd_float4(p, 1)
        for s in slabs {
            let l = s.inverse * h
            if abs(l.z) < LeftoverScanner.surfaceClearance,
               abs(l.x) < s.half.x + 0.1, abs(l.y) < s.half.y + 0.1 { return true }
        }
        for o in solids {
            let l = o.inverse * h
            let local = simd_abs(simd_float3(l.x, l.y, l.z))
            let beyond: simd_float3 = local - o.half
            if simd_reduce_max(beyond) < LeftoverScanner.objectMargin { return true }
        }
        return !inside(simd_float2(p.x, p.z))
    }

    /// Even-odd ray cast against the wall outline. RoomPlan's walls meet at the
    /// corners, so they close the room; with fewer than three there is no
    /// outline to trust, and everything counts as inside.
    private func inside(_ q: simd_float2) -> Bool {
        guard outline.count >= 3 else { return true }
        var crossings = 0
        for (a, b) in outline where (a.y > q.y) != (b.y > q.y) {
            let t: Float = (q.y - a.y) / (b.y - a.y)
            let x: Float = a.x + t * (b.x - a.x)
            if x > q.x { crossings += 1 }
        }
        return crossings % 2 == 1
    }

    /// Distance from `p` to the nearest wall, within the wall's extent.
    func distanceToWall(_ p: simd_float3) -> Float {
        let h = simd_float4(p, 1)
        var best = Float.greatestFiniteMagnitude
        for w in walls {
            let l = w.inverse * h
            if abs(l.x) < w.half.x + 0.1 { best = min(best, abs(l.z)) }
        }
        return best
    }

    /// 26-neighbour connected components on a voxel grid.
    static func cluster(_ points: [simd_float3], voxel: Float) -> [[simd_float3]] {
        var occupancy: [SIMD3<Int32>: [Int]] = [:]
        for (i, p) in points.enumerated() { occupancy[LeftoverScanner.cell(p, voxel), default: []].append(i) }

        var seen = Set<SIMD3<Int32>>(minimumCapacity: occupancy.count)
        var clusters: [[simd_float3]] = []
        for key in occupancy.keys where !seen.contains(key) {
            var reached = [key]
            seen.insert(key)
            var qi = 0
            while qi < reached.count {
                let c = reached[qi]; qi += 1
                for dx in Int32(-1)...1 {
                    for dy in Int32(-1)...1 {
                        for dz in Int32(-1)...1 where !(dx == 0 && dy == 0 && dz == 0) {
                            let n = SIMD3<Int32>(c.x + dx, c.y + dy, c.z + dz)
                            guard occupancy[n] != nil, seen.insert(n).inserted else { continue }
                            reached.append(n)
                        }
                    }
                }
            }
            clusters.append(reached.flatMap { (occupancy[$0] ?? []).map { points[$0] } })
        }
        return clusters
    }
}

// MARK: - Box

/// A gravity-aligned box: `dims` is [length, width, height], length ≥ width.
private struct Box {
    let center: simd_float3
    let dims: simd_float3
    /// Unit vectors of the length and width sides in x/z.
    let lengthAxis: simd_float2
    let widthAxis: simd_float2

    var bottom: Float { center.y - dims.z * 0.5 }

    /// The four footprint corners in x/z.
    var footprint: [simd_float2] {
        let c = simd_float2(center.x, center.z)
        let l: simd_float2 = lengthAxis * (dims.x * 0.5)
        let w: simd_float2 = widthAxis * (dims.y * 0.5)
        let back: simd_float2 = c - w
        let front: simd_float2 = c + w
        return [back - l, back + l, front + l, front - l]
    }

    /// Geometric volume in m³, without packing factor.
    var volume: Float { dims.x * dims.y * dims.z }

    var corners: [simd_float3] {
        var result: [simd_float3] = []
        for a in [-0.5, 0.5] as [Float] {
            for b in [-0.5, 0.5] as [Float] {
                for c in [-0.5, 0.5] as [Float] {
                    let along: simd_float2 = lengthAxis * (dims.x * a)
                    let across: simd_float2 = widthAxis * (dims.y * b)
                    let xz: simd_float2 = along + across
                    let offset = simd_float3(xz.x, dims.z * c, xz.y)
                    result.append(center + offset)
                }
            }
        }
        return result
    }

    /// Height straight from y (1st–99th percentile, so a stray point doesn't
    /// stretch it); footprint from the minimum-area rectangle over the convex
    /// hull — rotating calipers, because PCA would lean towards whichever side
    /// the customer walked past twice.
    static func fit(_ points: [simd_float3]) -> Box? {
        guard points.count >= 8 else { return nil }
        let ys: [Float] = points.map { (p: simd_float3) -> Float in p.y }.sorted()
        let loY = ys[Int(Float(ys.count - 1) * 0.01)]
        let hiY = ys[Int(Float(ys.count - 1) * 0.99)]
        guard hiY - loY > 0.03 else { return nil }

        let hull = hullXZ(points)
        guard hull.count >= 3 else { return nil }

        var best: (area: Float, axis: simd_float2, a: (Float, Float), b: (Float, Float))?
        for i in hull.indices {
            let edge = hull[(i + 1) % hull.count] - hull[i]
            guard simd_length(edge) > 1e-5 else { continue }
            let axis = simd_normalize(edge)
            let normal = simd_float2(-axis.y, axis.x)
            var a = (Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
            var b = a
            for h in hull {
                let pa = simd_dot(h, axis), pb = simd_dot(h, normal)
                a = (min(a.0, pa), max(a.1, pa))
                b = (min(b.0, pb), max(b.1, pb))
            }
            let area = (a.1 - a.0) * (b.1 - b.0)
            if best == nil || area < best!.area { best = (area, axis, a, b) }
        }
        guard let best else { return nil }

        let normal = simd_float2(-best.axis.y, best.axis.x)
        let da = best.a.1 - best.a.0, db = best.b.1 - best.b.0
        let midA: simd_float2 = best.axis * ((best.a.0 + best.a.1) * 0.5)
        let midB: simd_float2 = normal * ((best.b.0 + best.b.1) * 0.5)
        let mid: simd_float2 = midA + midB
        let longIsA = da >= db
        let midY: Float = (loY + hiY) * 0.5
        return Box(center: simd_float3(mid.x, midY, mid.y),
                   dims: simd_float3(max(da, db), min(da, db), hiY - loY),
                   lengthAxis: longIsA ? best.axis : normal,
                   widthAxis: longIsA ? normal : best.axis)
    }

    /// Convex hull of the x/z footprint (Andrew's monotone chain).
    private static func hullXZ(_ points: [simd_float3]) -> [simd_float2] {
        var input: [simd_float2] = points.map { (p: simd_float3) -> simd_float2 in simd_float2(p.x, p.z) }
        input.sort { (a: simd_float2, b: simd_float2) -> Bool in a.x == b.x ? a.y < b.y : a.x < b.x }
        guard input.count >= 3 else { return input }
        func cross(_ o: simd_float2, _ a: simd_float2, _ b: simd_float2) -> Float {
            let oa: simd_float2 = a - o
            let ob: simd_float2 = b - o
            return oa.x * ob.y - oa.y * ob.x
        }
        var hull: [simd_float2] = []
        for p in input {
            while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
            hull.append(p)
        }
        let lower = hull.count + 1
        for p in input.reversed() {
            while hull.count >= lower, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
            hull.append(p)
        }
        hull.removeLast()
        return hull
    }
}
