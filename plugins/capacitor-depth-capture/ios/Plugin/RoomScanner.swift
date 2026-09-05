import Foundation
import ARKit
import simd

// MARK: - OrientedBox

/// A gravity-aligned oriented bounding box. `dims` is [length, width, height]
/// with length ≥ width and height along gravity, which is the shape a loading
/// volume is quoted in.
struct OrientedBox {
    var center: simd_float3
    var dims: simd_float3
    var yaw: Float

    /// Loading volume: the geometric box plus handling space around it.
    var volume: Float { dims.x * dims.y * dims.z * RoomScanner.packingFactor }
}

// MARK: - RoomObject

/// One thing standing in the room, as found by subtracting the room from its
/// own mesh. Points are the deduplicated mesh vertices that survived that
/// subtraction — kept, rather than only the box, so two objects can be merged
/// or one re-split without rescanning.
final class RoomObject {
    /// Reassigned on every rescan, merge and split — treat it as a handle for
    /// the current list, never as a stable identity.
    var id: Int
    var points: [simd_float3]
    var box: OrientedBox
    /// Set when the customer typed a volume outright rather than measuring one.
    /// It is taken as given: no box was ever fitted, so none is reported.
    var typedVolume: Float?
    /// Optional, as everywhere else in this app: the backend names what the
    /// customer doesn't.
    var label: String = ""
    /// Index into the sweep's captured frames — the photo that saw this object
    /// best, used for naming server-side.
    var frameIndex: Int?

    init(id: Int, points: [simd_float3], box: OrientedBox) {
        self.id = id
        self.points = points
        self.box = box
    }

    /// False for manual entries, which have no mesh behind them: they cannot be
    /// merged, split or drawn in the world.
    var hasGeometry: Bool { !points.isEmpty }

    var volume: Float { typedVolume ?? box.volume }
}

// MARK: - RoomPlane

/// A wall, floor or ceiling, as a finite rectangle rather than an infinite
/// plane — an infinite one reaches across the whole flat and deletes furniture
/// that merely happens to be coplanar with a wall two rooms away.
private struct RoomPlane {
    let inverse: simd_float4x4
    let center: simd_float3
    let halfWidth: Float
    let halfHeight: Float

    init(anchor: ARPlaneAnchor) {
        inverse = simd_inverse(anchor.transform)
        center = anchor.center
        // `planeExtent` is iOS 16, and the SPM app target Capacitor generates
        // is iOS 15 — so the deprecated `extent` still has to carry the floor.
        if #available(iOS 16.0, *) {
            halfWidth = anchor.planeExtent.width / 2
            halfHeight = anchor.planeExtent.height / 2
        } else {
            halfWidth = anchor.extent.x / 2
            halfHeight = anchor.extent.z / 2
        }
    }

    /// True when `p` lies on this plane's surface, within its footprint.
    func absorbs(_ p: simd_float3, clearance: Float) -> Bool {
        let local = inverse * simd_float4(p, 1)
        guard abs(local.y) <= clearance else { return false }
        // The footprint is grown slightly: ARKit's rectangle lags the real
        // surface at the edges, and the skirting board is not furniture.
        return abs(local.x - center.x) <= halfWidth + 0.2
            && abs(local.z - center.z) <= halfHeight + 0.2
    }
}

// MARK: - RoomScanner

/// Turns ARKit's scene mesh into a list of objects, by deleting the room.
///
/// This replaces per-frame region growing, which had to decide "what is this
/// object" from one depth frame at a time and could only ever be told when to
/// *stop* growing — hence a seed, a gate, an anchor lock, and a pile of rules
/// about floors. Subtraction poses the question the other way round: strip out
/// every face that is wall, floor or ceiling, and what remains falls into
/// disconnected islands on its own. Each island is an object, and no island
/// needed to fit in a single camera frame to become one.
///
/// The mesh is also fused over the whole sweep, so a fan's pole accumulates
/// evidence across hundreds of frames instead of having to survive one.
final class RoomScanner {

    /// Loading volume includes handling space around the raw geometric box.
    static let packingFactor: Float = 1.2

    /// Mesh vertices are deduplicated onto this grid before anything else. It
    /// bounds the work and costs nothing: the mesh is far denser than a
    /// bounding box needs.
    private static let dedupVoxel: Float = 0.03
    /// Clustering resolution. Large enough to bridge the holes ARKit leaves in
    /// thin structures, small enough that a chair pushed under a table is still
    /// its own island more often than not.
    private static let clusterVoxel: Float = 0.07
    /// How close to a wall/floor/ceiling plane a point has to be to count as
    /// part of it.
    private static let structureClearance: Float = 0.06
    /// Below this an island is clutter: cables, skirting, mesh noise.
    private static let minVolume: Float = 0.02
    /// Above this it is not a piece of furniture, it is a mis-subtracted wall.
    private static let maxVolume: Float = 15.0
    private static let minPoints = 30
    /// Islands whose whole extent sits below this are floor scraps.
    private static let minHeightAboveFloor: Float = 0.04

    /// Mesh classifications that are the room itself. `.table` and `.seat` are
    /// deliberately absent — those are furniture, and a table classified as a
    /// table is a table we have to move.
    private static let structureClasses: Set<UInt8> = [
        UInt8(ARMeshClassification.wall.rawValue),
        UInt8(ARMeshClassification.floor.rawValue),
        UInt8(ARMeshClassification.ceiling.rawValue),
        UInt8(ARMeshClassification.window.rawValue),
        UInt8(ARMeshClassification.door.rawValue),
    ]

    // MARK: Entry point

    /// Extract the objects from a set of mesh anchors.
    ///
    /// Pure and self-contained, so it can run on a background queue while the
    /// sweep continues: nothing here touches the session.
    static func objects(from meshAnchors: [ARMeshAnchor],
                        planeAnchors: [ARPlaneAnchor]) -> [RoomObject] {
        let planes = structurePlanes(from: planeAnchors)
        let floorY = planeAnchors
            .filter { $0.alignment == .horizontal }
            .map { $0.transform.columns.3.y }
            .min()

        var occupied = Set<SIMD3<Int32>>()
        var points: [simd_float3] = []
        for anchor in meshAnchors {
            collect(anchor: anchor, planes: planes, floorY: floorY,
                    occupied: &occupied, points: &points)
        }
        guard points.count >= minPoints else { return [] }

        var objects: [RoomObject] = []
        for cluster in cluster(points) {
            guard cluster.count >= minPoints, let box = fit(cluster) else { continue }
            let volume = box.volume
            guard volume >= minVolume, volume <= maxVolume else { continue }
            if let floorY, box.center.y + box.dims.z / 2 < floorY + minHeightAboveFloor { continue }
            objects.append(RoomObject(id: objects.count, points: cluster, box: box))
        }
        // Biggest first: that is the order the customer wants to check them in,
        // and the order in which a mistake matters.
        objects.sort { $0.volume > $1.volume }
        return objects
    }

    // MARK: Mesh → points

    private static func structurePlanes(from anchors: [ARPlaneAnchor]) -> [RoomPlane] {
        anchors.compactMap { anchor in
            switch anchor.classification {
            case .wall, .floor, .ceiling: return RoomPlane(anchor: anchor)
            // An unclassified vertical plane of any size is a wall in every room
            // we care about. Unclassified *horizontal* planes are left alone —
            // that is how a table or a bed surface reads before ARKit commits,
            // and deleting those deletes the furniture.
            case .none where anchor.alignment == .vertical: return RoomPlane(anchor: anchor)
            default: return nil
            }
        }
    }

    /// Read one mesh anchor, drop everything that is the room, and fold what is
    /// left into the deduplicated point set.
    ///
    /// Two independent structure rejections, because each covers the other's
    /// blind spot: ARKit's per-face classification is semantic but often `.none`
    /// on a freshly seen surface, while plane proximity is purely geometric and
    /// needs no classifier to have made up its mind.
    private static func collect(anchor: ARMeshAnchor,
                                planes: [RoomPlane],
                                floorY: Float?,
                                occupied: inout Set<SIMD3<Int32>>,
                                points: inout [simd_float3]) {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces
        guard faces.indexCountPerPrimitive == 3 else { return }

        let classification = geometry.classification
        let vertexBase = vertices.buffer.contents()
        let faceBase = faces.buffer.contents()
        let transform = anchor.transform

        /// Vertices are three tightly packed Floats at `stride` intervals —
        /// read them as Floats, not as a `simd_float3`, whose 16-byte alignment
        /// does not match the 12-byte stride ARKit uses.
        func vertex(_ index: Int) -> simd_float3 {
            let p = vertexBase
                .advanced(by: vertices.offset + vertices.stride * index)
                .assumingMemoryBound(to: Float.self)
            let local = simd_float4(p[0], p[1], p[2], 1)
            let world = transform * local
            return simd_float3(world.x, world.y, world.z)
        }
        func index(_ i: Int) -> Int {
            Int(faceBase.advanced(by: i * faces.bytesPerIndex)
                .assumingMemoryBound(to: UInt32.self).pointee)
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
                if let floorY, p.y < floorY + structureClearance { continue }
                if planes.contains(where: { $0.absorbs(p, clearance: structureClearance) }) { continue }
                let cell = SIMD3<Int32>(Int32(floor(p.x / dedupVoxel)),
                                        Int32(floor(p.y / dedupVoxel)),
                                        Int32(floor(p.z / dedupVoxel)))
                if occupied.insert(cell).inserted { points.append(p) }
            }
        }
    }

    // MARK: Points → islands

    /// 26-neighbour connected components on a voxel grid. Whatever the room
    /// subtraction left behind is already separated in space; this just reads
    /// off the separation.
    static func cluster(_ points: [simd_float3], voxel: Float = clusterVoxel) -> [[simd_float3]] {
        guard !points.isEmpty else { return [] }
        var occupancy: [SIMD3<Int32>: [Int]] = [:]
        occupancy.reserveCapacity(points.count)
        for (i, p) in points.enumerated() {
            let cell = SIMD3<Int32>(Int32(floor(p.x / voxel)),
                                    Int32(floor(p.y / voxel)),
                                    Int32(floor(p.z / voxel)))
            occupancy[cell, default: []].append(i)
        }

        var seen = Set<SIMD3<Int32>>(minimumCapacity: occupancy.count)
        var clusters: [[simd_float3]] = []
        for key in occupancy.keys where !seen.contains(key) {
            var reached: [SIMD3<Int32>] = [key]
            seen.insert(key)
            var qi = 0
            while qi < reached.count {
                let c = reached[qi]; qi += 1
                for dx in Int32(-1)...1 {
                    for dy in Int32(-1)...1 {
                        for dz in Int32(-1)...1 where !(dx == 0 && dy == 0 && dz == 0) {
                            let n = SIMD3<Int32>(c.x + dx, c.y + dy, c.z + dz)
                            guard occupancy[n] != nil, !seen.contains(n) else { continue }
                            seen.insert(n)
                            reached.append(n)
                        }
                    }
                }
            }
            var cluster: [simd_float3] = []
            for c in reached { for i in occupancy[c] ?? [] { cluster.append(points[i]) } }
            clusters.append(cluster)
        }
        return clusters
    }

    // MARK: Islands → boxes

    /// Fit the gravity-aligned OBB: height straight from Y, footprint from the
    /// minimum-area rectangle over the footprint's convex hull.
    ///
    /// Rotating calipers rather than PCA, because PCA is density-weighted — the
    /// side of the object the customer happened to walk past twice would
    /// otherwise drag the box's orientation towards it.
    static func fit(_ points: [simd_float3]) -> OrientedBox? {
        guard points.count >= 8 else { return nil }

        let ys = points.map { $0.y }.sorted()
        let loY = ys[Int(Float(ys.count - 1) * 0.01)]
        let hiY = ys[Int(Float(ys.count - 1) * 0.99)]
        let height = hiY - loY
        guard height > 0.03 else { return nil }

        let footprint = hullXZ(points)
        guard footprint.count >= 3 else { return nil }

        var best: (area: Float, theta: Float, a: (Float, Float), b: (Float, Float))?
        for i in footprint.indices {
            let p = footprint[i], q = footprint[(i + 1) % footprint.count]
            let edge = simd_float2(q.x - p.x, q.y - p.y)
            guard simd_length(edge) > 1e-5 else { continue }
            let theta = atan2(edge.y, edge.x)
            let ct = cos(theta), st = sin(theta)
            var aLo = Float.greatestFiniteMagnitude, aHi = -Float.greatestFiniteMagnitude
            var bLo = Float.greatestFiniteMagnitude, bHi = -Float.greatestFiniteMagnitude
            for h in footprint {
                let a = h.x * ct + h.y * st
                let b = -h.x * st + h.y * ct
                aLo = min(aLo, a); aHi = max(aHi, a)
                bLo = min(bLo, b); bHi = max(bHi, b)
            }
            let area = (aHi - aLo) * (bHi - bLo)
            if best == nil || area < best!.area {
                best = (area, theta, (aLo, aHi), (bLo, bHi))
            }
        }
        guard let best else { return nil }

        let ct = cos(best.theta), st = sin(best.theta)
        let da = best.a.1 - best.a.0, db = best.b.1 - best.b.0
        let length = max(da, db), width = min(da, db)
        guard length > 0.04, width > 0.02 else { return nil }

        let ac = (best.a.0 + best.a.1) / 2, bc = (best.b.0 + best.b.1) / 2
        let center = simd_float3(ac * ct - bc * st, (loY + hiY) / 2, ac * st + bc * ct)
        // A node rotated by φ about world Y maps its local +X to (cos φ, 0, -sin φ).
        let yaw = da >= db ? -best.theta : -best.theta - .pi / 2
        return OrientedBox(center: center,
                           dims: simd_float3(length, width, height),
                           yaw: yaw)
    }

    /// Convex hull of the footprint (x, z), by Andrew's monotone chain.
    private static func hullXZ(_ points: [simd_float3]) -> [simd_float2] {
        var input = points.map { simd_float2($0.x, $0.z) }
        input.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard input.count >= 3 else { return input }
        func cross(_ o: simd_float2, _ a: simd_float2, _ b: simd_float2) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var hull: [simd_float2] = []
        for p in input {
            while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        let lowerCount = hull.count + 1
        for p in input.reversed() {
            while hull.count >= lowerCount, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        hull.removeLast()
        return hull
    }

    // MARK: Editing

    /// Fuse two objects the subtraction left apart — a table and the lamp on it,
    /// or a sofa whose chaise ARKit meshed as its own island.
    static func merged(_ a: RoomObject, _ b: RoomObject, id: Int) -> RoomObject? {
        let points = a.points + b.points
        guard let box = fit(points) else { return nil }
        let merged = RoomObject(id: id, points: points, box: box)
        merged.label = a.label.isEmpty ? b.label : a.label
        merged.frameIndex = a.frameIndex ?? b.frameIndex
        return merged
    }

    /// Split one object the clustering fused. Re-clustering at a finer
    /// resolution is tried first, because a fusion is usually two things joined
    /// through one thin bridge of voxels; only if the island really is solid do
    /// we fall back to cutting it down the middle of its long axis.
    static func split(_ object: RoomObject, startingID: Int) -> [RoomObject] {
        let fine = cluster(object.points, voxel: 0.04)
            .filter { $0.count >= minPoints }
        if fine.count >= 2 {
            let parts = fine.compactMap { points -> RoomObject? in
                guard let box = fit(points) else { return nil }
                return RoomObject(id: 0, points: points, box: box)
            }
            if parts.count >= 2 {
                for p in parts { p.frameIndex = object.frameIndex }
                return reindexed(parts, from: startingID)
            }
        }

        let yaw = object.box.yaw
        let axis = simd_float2(cos(-yaw), sin(-yaw))
        let centre = simd_float2(object.box.center.x, object.box.center.z)
        var left: [simd_float3] = [], right: [simd_float3] = []
        for p in object.points {
            let d = simd_dot(simd_float2(p.x, p.z) - centre, axis)
            if d < 0 { left.append(p) } else { right.append(p) }
        }
        guard left.count >= minPoints, right.count >= minPoints,
              let lb = fit(left), let rb = fit(right) else { return [object] }
        let parts = [RoomObject(id: 0, points: left, box: lb),
                     RoomObject(id: 0, points: right, box: rb)]
        for p in parts { p.frameIndex = object.frameIndex }
        return reindexed(parts, from: startingID)
    }

    private static func reindexed(_ objects: [RoomObject], from startingID: Int) -> [RoomObject] {
        objects.enumerated().map { offset, o in
            let copy = RoomObject(id: startingID + offset, points: o.points, box: o.box)
            copy.label = o.label
            copy.frameIndex = o.frameIndex
            return copy
        }
    }
}
