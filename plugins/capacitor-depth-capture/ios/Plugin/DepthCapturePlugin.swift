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

// MARK: - Measurement

/// One reading of the fused point cloud: the box we draw and the numbers we show.
private struct Measurement {
    /// Loading volume in m³ (geometric OBB × packing factor).
    let volume: Float
    /// [length, width, height] in metres. Length ≥ width; height is along gravity.
    let dims: simd_float3
    let confidence: Float
    /// OBB centre in ARKit world space.
    let center: simd_float3
    /// Rotation about world Y that aligns the box's local +X with `dims.x`.
    let yaw: Float
}

// MARK: - ObjectLock

/// The one object this measurement is about, tracked in world space.
///
/// Without it the segmentation re-decides what it is looking at on every frame
/// ("whatever is in the middle"), and the fused cloud only ever grows — pan
/// across a bed once and the bed is in the volume forever. The lock turns the
/// sweep into *tracking a specific thing*: the seed is projected from `anchor`
/// rather than taken from the reticle, and points outside the gate are dropped
/// instead of accumulated.
///
/// The gate is a cylinder, not a sphere: furniture is tall-and-thin or
/// wide-and-flat far more often than it is round, and an isotropic radius big
/// enough for a standing fan's height is also big enough to swallow the bed
/// next to it.
private struct ObjectLock {
    var anchor: simd_float3
    /// Half-extent in the horizontal plane (XZ).
    var horizontalRadius: Float
    /// Half-extent along gravity (Y).
    var halfHeight: Float

    /// How far the object can reach from `anchor` in any direction — used to
    /// sanity-check the seed depth against the distance to the anchor.
    var reach: Float { max(horizontalRadius, halfHeight) }

    func contains(_ p: simd_float3) -> Bool {
        let dxz = simd_length(simd_float2(p.x - anchor.x, p.z - anchor.z))
        return dxz <= horizontalRadius && abs(p.y - anchor.y) <= halfHeight
    }
}

/// What one frame did to the model.
private enum IngestOutcome {
    case accepted
    /// Frame carried no usable depth. Says nothing about tracking.
    case unusable
    /// The locked object is not where it should be. `centerWorld` is whatever
    /// the reticle is on now, so the caller can decide whether the customer has
    /// moved on to a different item.
    case lostObject(centerWorld: simd_float3?)
}

// MARK: - VolumeAccumulator
//
// On-device volume estimation for LiDAR devices. The first frame acquires an
// object from the reticle; from then on the object is *tracked*: its anchor is
// projected into each new frame to place the seed, the depth map is region-grown
// from there, and every back-projected point must fall inside the lock's gate to
// join the cloud. `measure()` keeps only the cloud component connected to the
// anchor, trims it (2–98 percentile per axis) and fits a gravity-aligned
// oriented bounding box (ARKit world: -Y is gravity).
//
// Points are ingested on the SceneKit render thread and measured on a
// background queue, so every access to the cloud is behind `lock`. Measuring
// copies the cloud out and computes off-lock — the render thread must never
// block on a full OBB fit.
private final class VolumeAccumulator {

    /// Subsample stride over the 256×192 depth grid.
    private static let stride = 2
    /// Depth continuity threshold for region growing: max(4 cm, 2% of depth).
    private static let depthJump: Float = 0.04
    /// Acquisition only: how far the first frame's region may reach from its
    /// seed. Kept tight — the gate can widen later, but an over-wide first frame
    /// sizes the lock around the room.
    private static let acquisitionRadius: Float = 0.85
    /// A flood that swallows this fraction of the grid hit the walls/floor — discard frame.
    private static let maxRegionFraction = 0.45
    /// Loading volume includes handling space around the raw geometric OBB.
    static let packingFactor: Float = 1.2
    /// Cloud size ceiling. Beyond it the cloud is halved — a live box that
    /// updates several times a second matters more than the last few points.
    private static let maxPoints = 40_000

    /// The gate may only creep outwards this far per frame. Real furniture does
    /// not grow; a jump this big is a segmentation leak, and letting it through
    /// once is what lets the next frame leak further.
    private static let maxGateGrowthPerFrame: Float = 0.04
    private static let maxHorizontalRadius: Float = 1.5
    private static let maxHalfHeight: Float = 1.3
    /// The anchor follows the cloud slowly, so a few bad points can't walk the
    /// gate onto the neighbouring furniture.
    private static let anchorSmoothing: Float = 0.05

    private let lock = NSLock()
    private var worldPoints: [simd_float3] = []
    private var pointSum = simd_float3(repeating: 0)
    private var framesUsedStorage = 0
    private var seedDepthStorage: Float?
    private var lockStorage: ObjectLock?

    var framesUsed: Int {
        lock.lock(); defer { lock.unlock() }
        return framesUsedStorage
    }

    /// The tracked object, once acquired.
    var objectLock: ObjectLock? {
        lock.lock(); defer { lock.unlock() }
        return lockStorage
    }

    /// Anchor of the tracked object — what the customer orbits around.
    var centroid: simd_float3? {
        lock.lock(); defer { lock.unlock() }
        return lockStorage?.anchor
    }

    /// Depth of the object at the seed in the most recent ingested frame.
    /// Drives the "step back" hint. nil until the first frame lands.
    var lastSeedDepth: Float? {
        lock.lock(); defer { lock.unlock() }
        return seedDepthStorage
    }

    /// Segment the tracked object out of one depth frame and fuse its points
    /// into the world-space cloud. `intrinsics` and `imageSize` describe the RGB
    /// image the depth map is registered to. `confidenceMap`, when present, is
    /// ARKit's per-pixel `ARConfidenceLevel` — low-confidence depth around thin
    /// edges is exactly the noise that used to inflate the box.
    @discardableResult
    func ingest(depthMap: CVPixelBuffer,
                confidenceMap: CVPixelBuffer?,
                intrinsics k: simd_float3x3,
                imageSize: CGSize,
                cameraTransform: simd_float4x4) -> IngestOutcome {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(depthMap) else { return .unusable }
        let rowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let ptr = base.bindMemory(to: Float32.self, capacity: rowStride * h)

        // Confidence is a separate 8-bit plane at the same resolution.
        var confPtr: UnsafeMutablePointer<UInt8>?
        var confRowStride = 0
        if let cm = confidenceMap,
           CVPixelBufferGetWidth(cm) == w, CVPixelBufferGetHeight(cm) == h {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            confRowStride = CVPixelBufferGetBytesPerRow(cm)
            confPtr = CVPixelBufferGetBaseAddress(cm)?.bindMemory(to: UInt8.self, capacity: confRowStride * h)
        }
        defer {
            if confPtr != nil, let cm = confidenceMap { CVPixelBufferUnlockBaseAddress(cm, .readOnly) }
        }

        // Intrinsics are for the full RGB resolution — rescale to the depth grid.
        let sx = Float(w) / Float(imageSize.width)
        let sy = Float(h) / Float(imageSize.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy
        let cx = k[2][0] * sx, cy = k[2][1] * sy
        guard fx > 0, fy > 0 else { return .unusable }

        let s = Self.stride
        let gw = w / s, gh = h / s
        guard gw > 4, gh > 4 else { return .unusable }

        func depthAt(_ gx: Int, _ gy: Int) -> Float {
            ptr[(gy * s) * rowStride + gx * s]
        }
        /// ARConfidenceLevel.low (0) is discarded; medium and high are kept.
        func confidentAt(_ gx: Int, _ gy: Int) -> Bool {
            guard let cp = confPtr else { return true }
            return cp[(gy * s) * confRowStride + gx * s] > 0
        }
        func backProject(_ gx: Int, _ gy: Int, _ d: Float) -> simd_float3 {
            let u = Float(gx * s), v = Float(gy * s)
            let xc = (u - cx) * d / fx
            let yc = -(v - cy) * d / fy
            let world = cameraTransform * simd_float4(xc, yc, -d, 1)
            return simd_float3(world.x, world.y, world.z)
        }
        /// Median depth of a window, so a single bad pixel can't define the seed.
        func medianDepth(around gx: Int, _ gy: Int, half: Int) -> Float? {
            var samples: [Float] = []
            for y in max(0, gy - half)...min(gh - 1, gy + half) {
                for x in max(0, gx - half)...min(gw - 1, gx + half) {
                    let d = depthAt(x, y)
                    if d.isFinite, d > 0.2, d < 6.0, confidentAt(x, y) { samples.append(d) }
                }
            }
            guard samples.count >= 20 else { return nil }
            samples.sort()
            return samples[samples.count / 2]
        }

        let currentLock = objectLock
        let camPos = simd_float3(cameraTransform.columns.3.x,
                                 cameraTransform.columns.3.y,
                                 cameraTransform.columns.3.z)

        // ── Seed placement ────────────────────────────────────────────────
        // Acquisition seeds from the reticle. After that the seed follows the
        // object, not the phone: the anchor is projected back into this frame.
        var seedX = gw / 2, seedY = gh / 2
        if let l = currentLock {
            let cam = simd_inverse(cameraTransform) * simd_float4(l.anchor, 1)
            let dist = -cam.z
            guard dist > 0.15 else { return .lostObject(centerWorld: nil) }
            let u = cam.x * fx / dist + cx
            let v = -cam.y * fy / dist + cy
            let px = Int(u) / s, py = Int(v) / s
            guard px >= 0, px < gw, py >= 0, py < gh else {
                return .lostObject(centerWorld: centerWorldPoint(gw: gw, gh: gh,
                                                                 medianDepth: medianDepth,
                                                                 backProject: backProject))
            }
            seedX = px; seedY = py
        }

        guard let seedDepth = medianDepth(around: seedX, seedY, half: 6) else {
            return currentLock == nil
                ? .unusable
                : .lostObject(centerWorld: centerWorldPoint(gw: gw, gh: gh,
                                                            medianDepth: medianDepth,
                                                            backProject: backProject))
        }

        // The seed must be at roughly the distance the anchor sits at. If the
        // object moved out of view and something else is behind it, this fails
        // — which is precisely the "we lost it" signal.
        if let l = currentLock {
            let expected = simd_distance(camPos, l.anchor)
            guard abs(seedDepth - expected) <= l.reach + 0.30 else {
                return .lostObject(centerWorld: centerWorldPoint(gw: gw, gh: gh,
                                                                 medianDepth: medianDepth,
                                                                 backProject: backProject))
            }
        }

        lock.lock(); seedDepthStorage = seedDepth; lock.unlock()

        // ── Region grow (BFS, 4-neighbour) across depth-continuous pixels ──
        let seedRaw = depthAt(seedX, seedY)
        guard seedRaw.isFinite, abs(seedRaw - seedDepth) < 0.3 else {
            return currentLock == nil ? .unusable : .lostObject(centerWorld: nil)
        }
        let seedWorld = backProject(seedX, seedY, seedRaw)
        if let l = currentLock, !l.contains(seedWorld) {
            return .lostObject(centerWorld: seedWorld)
        }

        var visited = [Bool](repeating: false, count: gw * gh)
        var region: [simd_float3] = []
        var queue: [(Int, Int, Float)] = [(seedX, seedY, seedRaw)]
        visited[seedY * gw + seedX] = true
        let maxRegion = Int(Double(gw * gh) * Self.maxRegionFraction)

        var qi = 0
        while qi < queue.count {
            let (gx, gy, d) = queue[qi]
            qi += 1
            region.append(backProject(gx, gy, d))
            if region.count > maxRegion { return .unusable }  // flooded into the room

            for (nx, ny) in [(gx - 1, gy), (gx + 1, gy), (gx, gy - 1), (gx, gy + 1)] {
                guard nx >= 0, nx < gw, ny >= 0, ny < gh, !visited[ny * gw + nx] else { continue }
                visited[ny * gw + nx] = true
                let nd = depthAt(nx, ny)
                guard nd.isFinite, nd > 0.2, nd < 6.0, confidentAt(nx, ny),
                      abs(nd - d) < max(Self.depthJump, 0.02 * d)
                else { continue }
                // The gate — the whole point of the lock. Anything reaching past
                // the tracked object stops here instead of joining the cloud.
                let world = backProject(nx, ny, nd)
                if let l = currentLock {
                    guard l.contains(world) else { continue }
                } else {
                    guard simd_distance(world, seedWorld) < Self.acquisitionRadius else { continue }
                }
                queue.append((nx, ny, nd))
            }
        }
        guard region.count >= 150 else {
            return currentLock == nil ? .unusable : .lostObject(centerWorld: seedWorld)
        }

        // Fuse into the world cloud, capped per frame.
        let cap = 6000
        let keepEvery = max(1, region.count / cap)
        var fresh: [simd_float3] = []
        fresh.reserveCapacity(min(region.count, cap) + 1)
        for (i, p) in region.enumerated() where i % keepEvery == 0 { fresh.append(p) }
        guard !fresh.isEmpty else { return .unusable }

        lock.lock()
        worldPoints.append(contentsOf: fresh)
        for p in fresh { pointSum += p }
        framesUsedStorage += 1
        lockStorage = Self.updatedLock(lockStorage, from: fresh)
        if worldPoints.count > Self.maxPoints { halveLocked() }
        lock.unlock()
        return .accepted
    }

    /// World point under the reticle, regardless of the lock — the caller uses
    /// it to tell "lost the object" from "moved on to a different object".
    private func centerWorldPoint(gw: Int, gh: Int,
                                  medianDepth: (Int, Int, Int) -> Float?,
                                  backProject: (Int, Int, Float) -> simd_float3) -> simd_float3? {
        guard let d = medianDepth(gw / 2, gh / 2, 6) else { return nil }
        return backProject(gw / 2, gh / 2, d)
    }

    /// Pull the gate in to fit the box we actually measured.
    ///
    /// Acquisition has to be generous — we don't know the object yet — and a
    /// generous gate on frame one would otherwise persist for the whole sweep,
    /// since growth is the only other adjustment. The measured OBB comes from
    /// the anchor-connected component, so it is the best available statement of
    /// "this is the object", and feeding it back makes the gate converge.
    /// Only ever shrinks; widening stays on the slow per-frame path.
    func tightenGate(to m: Measurement, minFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        guard var l = lockStorage, framesUsedStorage >= minFrames else { return }
        // Margin is deliberately fat: early in a sweep the box only covers the
        // side seen so far, and clamping to that would lock out the rest.
        let margin: Float = 0.25
        let horizontal = 0.5 * simd_length(simd_float2(m.dims.x, m.dims.y)) + margin
        let vertical = 0.5 * m.dims.z + margin
        l.anchor += (m.center - l.anchor) * 0.30
        l.horizontalRadius = max(0.30, min(l.horizontalRadius, horizontal))
        l.halfHeight = max(0.30, min(l.halfHeight, vertical))
        lockStorage = l
    }

    /// Acquire the gate on the first frame, then let it creep outwards slowly.
    private static func updatedLock(_ existing: ObjectLock?, from points: [simd_float3]) -> ObjectLock? {
        guard !points.isEmpty else { return existing }
        var mean = simd_float3(repeating: 0)
        for p in points { mean += p }
        mean /= Float(points.count)

        // 95th percentile extents, so a few stragglers don't size the gate.
        var horizontal = points.map { simd_length(simd_float2($0.x - mean.x, $0.z - mean.z)) }
        var vertical = points.map { abs($0.y - mean.y) }
        horizontal.sort(); vertical.sort()
        let idx = max(0, Int(Float(points.count - 1) * 0.95))
        let wantH = min(Self.maxHorizontalRadius, horizontal[idx] + 0.12)
        let wantV = min(Self.maxHalfHeight, vertical[idx] + 0.12)

        guard var l = existing else {
            return ObjectLock(anchor: mean,
                              horizontalRadius: max(0.20, wantH),
                              halfHeight: max(0.20, wantV))
        }
        l.anchor += (mean - l.anchor) * Self.anchorSmoothing
        l.horizontalRadius = min(Self.maxHorizontalRadius,
                                 max(l.horizontalRadius,
                                     min(wantH, l.horizontalRadius + Self.maxGateGrowthPerFrame)))
        l.halfHeight = min(Self.maxHalfHeight,
                           max(l.halfHeight,
                               min(wantV, l.halfHeight + Self.maxGateGrowthPerFrame)))
        return l
    }

    /// Drop every second point. Called under `lock`.
    private func halveLocked() {
        var out: [simd_float3] = []
        out.reserveCapacity(worldPoints.count / 2 + 1)
        var sum = simd_float3(repeating: 0)
        for (i, p) in worldPoints.enumerated() where i % 2 == 0 {
            out.append(p)
            sum += p
        }
        worldPoints = out
        pointSum = sum
    }

    /// Copy the cloud out so the caller can measure it off the render thread.
    func snapshot() -> (points: [simd_float3], frames: Int, anchor: simd_float3?) {
        lock.lock(); defer { lock.unlock() }
        return (worldPoints, framesUsedStorage, lockStorage?.anchor)
    }

    /// Keep only the part of the cloud that is physically connected to the
    /// anchor, at 6 cm voxel resolution.
    ///
    /// The gate stops *new* leaks, this cleans up whatever got in before the
    /// lock tightened. Percentile trimming can't: it assumes outliers are a thin
    /// tail, and a bed is not a thin tail — it is a second dense blob that drags
    /// the box over both.
    private static func componentContainingAnchor(_ anchor: simd_float3?,
                                                  points: [simd_float3]) -> [simd_float3] {
        guard let anchor, points.count > 50 else { return points }
        let voxel: Float = 0.06
        func cell(_ p: simd_float3) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32(floor(p.x / voxel)), Int32(floor(p.y / voxel)), Int32(floor(p.z / voxel)))
        }

        var occupancy: [SIMD3<Int32>: [Int]] = [:]
        occupancy.reserveCapacity(points.count / 4)
        for (i, p) in points.enumerated() { occupancy[cell(p), default: []].append(i) }

        // Start at the anchor's cell; if the anchor sits in a hollow (it is a
        // centroid, not a surface point), start from the nearest occupied cell.
        var start = cell(anchor)
        if occupancy[start] == nil {
            var bestDistance = Float.greatestFiniteMagnitude
            for key in occupancy.keys {
                let c = simd_float3(Float(key.x), Float(key.y), Float(key.z)) * voxel
                let d = simd_distance(c, anchor)
                if d < bestDistance { bestDistance = d; start = key }
            }
            guard bestDistance < 1.0 else { return points }
        }

        var reached: Set<SIMD3<Int32>> = [start]
        var queue = [start]
        var qi = 0
        while qi < queue.count {
            let c = queue[qi]; qi += 1
            for dx in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dz in Int32(-1)...1 where !(dx == 0 && dy == 0 && dz == 0) {
                        let n = SIMD3<Int32>(c.x + dx, c.y + dy, c.z + dz)
                        guard occupancy[n] != nil, !reached.contains(n) else { continue }
                        reached.insert(n)
                        queue.append(n)
                    }
                }
            }
        }

        var kept: [simd_float3] = []
        kept.reserveCapacity(points.count)
        for c in reached {
            for i in occupancy[c] ?? [] { kept.append(points[i]) }
        }
        return kept
    }

    /// Fit the gravity-aligned OBB. Pure — safe to call on any thread.
    static func measure(points rawPoints: [simd_float3],
                        framesUsed: Int,
                        anchor: simd_float3?) -> Measurement? {
        let points = componentContainingAnchor(anchor, points: rawPoints)
        guard framesUsed >= 1, points.count >= 400 else { return nil }

        func trimmedExtent(_ values: [Float]) -> (lo: Float, hi: Float) {
            let sorted = values.sorted()
            let lo = sorted[Int(Float(sorted.count - 1) * 0.02)]
            let hi = sorted[Int(Float(sorted.count - 1) * 0.98)]
            return (lo, hi)
        }

        // Trim outliers per world axis, keeping points inside the trimmed box.
        let ex = trimmedExtent(points.map { $0.x })
        let ey = trimmedExtent(points.map { $0.y })
        let ez = trimmedExtent(points.map { $0.z })
        let pts = points.filter {
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

        // Box centre: midpoint in the rotated footprint frame, mapped back to world.
        let ac = (a.lo + a.hi) / 2, bc = (b.lo + b.hi) / 2
        let center = simd_float3(mx + ac * ct - bc * st,
                                 (ey.lo + ey.hi) / 2,
                                 mz + ac * st + bc * ct)

        // A node rotated by φ about world Y maps its local +X to (cos φ, 0, -sin φ).
        // The long footprint axis is `a` = (ct, 0, st) when da ≥ db, else `b`.
        let yaw = da >= db ? -theta : -theta - .pi / 2

        // More usable frames and denser clouds → higher confidence.
        let confidence = min(0.9, 0.5 + 0.08 * Float(framesUsed) + 0.00001 * Float(pts.count))
        return Measurement(volume: volume,
                           dims: simd_float3(length, width, height),
                           confidence: confidence,
                           center: center,
                           yaw: yaw)
    }

    func reset() {
        lock.lock()
        worldPoints.removeAll(keepingCapacity: true)
        pointSum = simd_float3(repeating: 0)
        framesUsedStorage = 0
        seedDepthStorage = nil
        lockStorage = nil
        lock.unlock()
    }
}

// MARK: - Guidance

/// What the user has to do next to finish the measurement. Exactly one
/// instruction at a time — a screen full of hints is a screen nobody reads.
private enum Guidance {
    /// No depth lock yet: the reticle isn't on an object.
    case aim
    /// Had the object, lost sight of it. The model is kept — pointing back at it
    /// resumes rather than restarts.
    case reacquire
    /// Standing too close for the depth camera to see the whole item.
    case stepBack
    /// Walk around the item; `left` is the on-screen direction to move.
    case orbit(left: Bool)
    /// Non-LiDAR devices: no measurement, just photos from a few angles.
    case photoSweep
    /// Enough angles, waiting for the box to settle.
    case hold
    case done
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
        CAPPluginMethod(name: "getAllItems",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearItems",     returnType: CAPPluginReturnPromise),
    ]

    // ── AR ────────────────────────────────────────────────────────────────
    private var arView: ARSCNView?
    private var frameCounter = 0
    private let yoloEveryNFrames = 12
    private var hasLidar = false
    private var sessionIntrinsics: simd_float3x3?

    // ── YOLO (silent) ─────────────────────────────────────────────────────
    private var visionModel: VNCoreMLModel?
    private var furnitureLabels: [String: String] = [:]
    /// Best guess for whatever is in the reticle right now. Never drawn — it
    /// only pre-fills the name field after a measurement, where the user can
    /// clear it. Empty means "let the backend name it from the photo".
    private var silentLabelGuess = ""

    // ── Measurement session ───────────────────────────────────────────────
    private var scanActive = false
    /// YOLO's guess frozen at the moment the sweep finished.
    private var scanSuggestedLabel = ""
    private var scanFrames: [ItemFrame] = []
    private let scanVolume = VolumeAccumulator()

    /// Viewing angles around the object, as 15° buckets of the camera's bearing
    /// from the object centroid. Coverage — not elapsed rotation — is what makes
    /// an OBB trustworthy, so it is what drives both progress and completion.
    private static let bucketCount = 24
    private static let requiredBuckets = 5      // ≈ 75° of orbit
    private static let requiredFrames = 6
    private static let maxFrames = 16
    private var capturedBuckets = Set<Int>()
    private var currentBucket: Int?

    /// Object-tracking state. Losing the lock briefly is normal and silent;
    /// losing it onto a clearly different object restarts the measurement.
    private var lostFrames = 0
    private var objectLost = false
    private var refocusFrames = 0
    private var refocusTarget: simd_float3?
    /// ~0.4 s at 60 fps before we admit the object is gone.
    private static let lostFrameThreshold = 24
    /// ~0.75 s locked onto something else before restarting on it.
    private static let refocusFrameThreshold = 45
    /// How far past the gate a candidate must sit to count as a different item.
    private static let refocusMargin: Float = 0.45

    /// Last few volume readings — the box has settled when they agree.
    private var volumeHistory: [Float] = []
    private static let stabilityWindow = 4
    private static let stabilityTolerance: Float = 0.10

    /// Cached OBB, refreshed off the render thread a few times a second.
    private var lastMeasurement: Measurement?
    private var measuring = false
    private var lastMeasureTime: TimeInterval = 0
    private static let measureInterval: TimeInterval = 0.25
    private let measureQueue = DispatchQueue(label: "aust.depthcapture.measure", qos: .userInitiated)

    /// Orbit span in degrees, reported with the item. Non-LiDAR devices have no
    /// centroid to orbit, so there the sweep is driven by camera rotation.
    private var scanRefQuaternion: simd_quatf?
    private var scanPrevQuaternion: simd_quatf?
    private var scanAccumulatedDeg: Float = 0
    private var scanLastCapturedDeg: Float = -Float.greatestFiniteMagnitude
    private static let photoSweepEveryDeg: Float = 4
    private static let photoSweepFrames = 8

    // ── Live box ──────────────────────────────────────────────────────────
    private var boxNode: SCNNode?

    // ── Items ─────────────────────────────────────────────────────────────
    private var savedItems: [SavedItem] = []
    /// Finished measurement awaiting confirmation in the review card.
    /// Nothing reaches `savedItems` until the user taps "Sichern".
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
        ov.canMeasure = hasLidar

        ov.onClose = { [weak self] in
            self?.teardownAll()
            self?.notifyListeners("sessionCancelled", data: [:])
        }
        ov.onFinish = { [weak self] in
            guard let self else { return }
            self.notifyListeners("sessionComplete", data: ["itemCount": self.savedItems.count])
        }
        ov.onMeasureRequested = { [weak self] in
            self?.beginMeasurement()
        }
        ov.onCancelMeasurement = { [weak self] in
            self?.abortScan()
        }
        // "Good enough" — take whatever has been measured so far.
        ov.onAcceptEarly = { [weak self] in
            self?.finalizeScan()
        }
        ov.onSaveItem = { [weak self] label in
            self?.commitPendingItem(label: label)
        }
        ov.onRemeasure = { [weak self] in
            guard let self else { return }
            let suggestion = self.pendingItem?.label ?? ""
            self.pendingItem = nil
            self.beginMeasurement(suggestedLabel: suggestion)
        }
        ov.onManualRequested = { [weak self] in
            self?.beginManualEntry()
        }
        ov.onManualSubmit = { [weak self] entry in
            self?.commitManualItem(entry)
        }
        ov.onManualCancel = { [weak self] in
            self?.abortScan()
        }

        window.addSubview(ov)
        overlay = ov
    }

    private func teardownAll() {
        overlay?.removeFromSuperview()
        overlay = nil
        removeBoxNode()
        arView?.session.pause()
        arView?.removeFromSuperview()
        arView = nil
        scanActive = false
        bridge?.webView?.isHidden = false
    }

    // MARK: - Measurement session

    private func beginMeasurement(suggestedLabel: String? = nil) {
        scanSuggestedLabel = suggestedLabel ?? silentLabelGuess
        scanFrames = []
        scanVolume.reset()
        capturedBuckets.removeAll()
        currentBucket = nil
        volumeHistory.removeAll()
        lastMeasurement = nil
        lostFrames = 0
        objectLost = false
        refocusFrames = 0
        refocusTarget = nil
        scanRefQuaternion = nil
        scanPrevQuaternion = nil
        scanAccumulatedDeg = 0
        scanLastCapturedDeg = -Float.greatestFiniteMagnitude
        scanActive = true
        DispatchQueue.main.async { [weak self] in
            self?.overlay?.setState(.measuring)
            self?.overlay?.updateGuidance(self?.hasLidar == true ? .aim : .photoSweep,
                                          volumeM3: nil, progress: 0)
        }
    }

    private func abortScan() {
        scanActive = false
        scanFrames = []
        scanVolume.reset()
        pendingItem = nil
        lastMeasurement = nil
        removeBoxNode()
        DispatchQueue.main.async { [weak self] in
            self?.overlay?.setState(.idle)
        }
    }

    private func processScanFrame(_ frame: ARFrame) {
        guard scanActive else { return }

        // Orbit span, for reporting (and the only progress signal without LiDAR).
        let quat = simd_quatf(frame.camera.transform)
        if scanRefQuaternion == nil { scanRefQuaternion = quat; scanPrevQuaternion = quat }
        if let prev = scanPrevQuaternion {
            scanAccumulatedDeg += quaternionAngularDistance(prev, quat)
            scanPrevQuaternion = quat
        }

        guard hasLidar else { return processPhotoSweepFrame(frame) }
        guard let sceneDepth = frame.sceneDepth else { return }

        // Always fuse depth — the cloud is what we are building. Only the
        // (expensive) JPEG encode is gated on covering a new viewing angle.
        let outcome = scanVolume.ingest(depthMap: sceneDepth.depthMap,
                                        confidenceMap: sceneDepth.confidenceMap,
                                        intrinsics: frame.camera.intrinsics,
                                        imageSize: frame.camera.imageResolution,
                                        cameraTransform: frame.camera.transform)
        handleTracking(outcome)
        guard !objectLost || scanVolume.objectLock == nil else {
            // Off the object: keep tracking state and guidance alive, but do not
            // capture frames — a photo of the wall is worse than no photo.
            refreshMeasurement(frame)
            return
        }

        let camPos = simd_float3(frame.camera.transform.columns.3.x,
                                 frame.camera.transform.columns.3.y,
                                 frame.camera.transform.columns.3.z)
        if let c = scanVolume.centroid {
            let bucket = bearingBucket(camera: camPos, centroid: c)
            currentBucket = bucket
            if !capturedBuckets.contains(bucket) && scanFrames.count < Self.maxFrames {
                capturedBuckets.insert(bucket)
                captureFrame(frame, depth: sceneDepth.depthMap)
            } else if scanFrames.isEmpty {
                captureFrame(frame, depth: sceneDepth.depthMap)
            }
        } else if scanFrames.isEmpty {
            captureFrame(frame, depth: sceneDepth.depthMap)
        }

        refreshMeasurement(frame)
    }

    /// Track whether we still have the object, and decide when the customer has
    /// simply moved on to a different one.
    ///
    /// Losing the object for a moment is normal — a hand passes, the phone
    /// swings wide. Only a sustained lock on something clearly elsewhere counts
    /// as a new object, and then the measurement restarts rather than silently
    /// fusing two pieces of furniture into one box.
    private func handleTracking(_ outcome: IngestOutcome) {
        switch outcome {
        case .accepted:
            lostFrames = 0
            refocusFrames = 0
            refocusTarget = nil
            if objectLost {
                objectLost = false
                DispatchQueue.main.async { [weak self] in self?.overlay?.hideToast() }
            }

        case .unusable:
            break  // says nothing about tracking

        case .lostObject(let centerWorld):
            lostFrames += 1
            if lostFrames >= Self.lostFrameThreshold && !objectLost {
                objectLost = true
            }
            guard let candidate = centerWorld, let lock = scanVolume.objectLock else { return }
            // A different object means "clearly somewhere else", not "just
            // outside the gate" — otherwise the far side of a wardrobe would
            // count as a new item.
            let displacement = simd_distance(candidate, lock.anchor)
            guard displacement > lock.reach + Self.refocusMargin else {
                refocusFrames = 0
                return
            }
            if let target = refocusTarget, simd_distance(target, candidate) < 0.35 {
                refocusFrames += 1
                refocusTarget = target + (candidate - target) * 0.2
            } else {
                refocusTarget = candidate
                refocusFrames = 1
            }
            if refocusFrames >= Self.refocusFrameThreshold { refocusOnNewObject() }
        }
    }

    /// Start over on whatever the customer is now looking at. Everything tied to
    /// the old object goes — cloud, lock, coverage, frames — because a half
    /// measurement of a fan must not become part of a bed.
    private func refocusOnNewObject() {
        scanVolume.reset()
        scanFrames = []
        capturedBuckets.removeAll()
        currentBucket = nil
        volumeHistory.removeAll()
        lastMeasurement = nil
        lostFrames = 0
        refocusFrames = 0
        refocusTarget = nil
        objectLost = false
        DispatchQueue.main.async { [weak self] in
            self?.removeBoxNode()
            self?.overlay?.showToast("Anderes Objekt erkannt — Messung neu gestartet")
        }
    }

    /// Non-LiDAR fallback: no cloud, no box — just photos from a few angles.
    private func processPhotoSweepFrame(_ frame: ARFrame) {
        if scanAccumulatedDeg - scanLastCapturedDeg >= Self.photoSweepEveryDeg || scanFrames.isEmpty {
            scanLastCapturedDeg = scanAccumulatedDeg
            captureFrame(frame, depth: nil)
        }
        let progress = Float(scanFrames.count) / Float(Self.photoSweepFrames)
        DispatchQueue.main.async { [weak self] in
            self?.overlay?.updateGuidance(.photoSweep, volumeM3: nil, progress: min(1, progress))
        }
        if scanFrames.count >= Self.photoSweepFrames { finalizeScan() }
    }

    private func captureFrame(_ frame: ARFrame, depth: CVPixelBuffer?) {
        let imageBase64 = pixelBufferToJPEGBase64(frame.capturedImage)
        let depthBase64 = depth.flatMap { depthMapToBase64PNG($0) }
        scanFrames.append(ItemFrame(imageBase64: imageBase64,
                                    depthMapBase64: depthBase64,
                                    pose: transformToFloatArray(frame.camera.transform)))
    }

    /// Camera bearing around the object, bucketed. Bearing is measured in the
    /// horizontal plane only — how far the user has walked around the item.
    private func bearingBucket(camera: simd_float3, centroid c: simd_float3) -> Int {
        let bearing = atan2(camera.x - c.x, camera.z - c.z)   // [-π, π]
        let norm = (bearing + .pi) / (2 * .pi)                // [0, 1]
        return min(Self.bucketCount - 1, max(0, Int(norm * Float(Self.bucketCount))))
    }

    /// Re-fit the OBB off the render thread, at most a few times a second, then
    /// push the box + numbers + next instruction to the UI.
    private func refreshMeasurement(_ frame: ARFrame) {
        let now = CACurrentMediaTime()
        guard !measuring, now - lastMeasureTime >= Self.measureInterval else {
            // Between fits, keep the box glued to the world by re-projecting the
            // cached measurement against the current camera pose.
            updateBox(with: lastMeasurement, frame: frame)
            return
        }
        measuring = true
        lastMeasureTime = now
        let snap = scanVolume.snapshot()
        measureQueue.async { [weak self] in
            let m = VolumeAccumulator.measure(points: snap.points,
                                              framesUsed: snap.frames,
                                              anchor: snap.anchor)
            DispatchQueue.main.async {
                guard let self, self.scanActive else { self?.measuring = false; return }
                self.measuring = false
                self.lastMeasurement = m
                if let m {
                    self.recordVolume(m.volume)
                    self.scanVolume.tightenGate(to: m, minFrames: Self.requiredFrames)
                }
                self.publishGuidance()
            }
        }
        updateBox(with: lastMeasurement, frame: frame)
    }

    private func recordVolume(_ v: Float) {
        volumeHistory.append(v)
        if volumeHistory.count > Self.stabilityWindow { volumeHistory.removeFirst() }
    }

    /// True once the last few readings agree — a box that still grows every
    /// frame has not seen the whole object yet.
    private var volumeIsStable: Bool {
        guard volumeHistory.count >= Self.stabilityWindow,
              let lo = volumeHistory.min(), let hi = volumeHistory.max(), lo > 0 else { return false }
        return (hi - lo) / lo <= Self.stabilityTolerance
    }

    /// Decide the single next instruction, push it to the overlay, and finish
    /// the measurement once nothing is left to ask for.
    private func publishGuidance() {
        guard scanActive, let frame = arView?.session.currentFrame else { return }

        let coverage = min(1, Float(capturedBuckets.count) / Float(Self.requiredBuckets))
        let progress = lastMeasurement == nil ? 0 : coverage * (volumeIsStable ? 1.0 : 0.85)

        guard let m = lastMeasurement, let c = scanVolume.centroid else {
            overlay?.updateGuidance(.aim, volumeM3: nil, progress: 0)
            return
        }

        // Lost sight of it: the model stays, so this is "point back at it", not
        // "start again". Never finish a measurement from a stale box.
        if objectLost {
            overlay?.updateGuidance(.reacquire, volumeM3: m.volume, progress: progress)
            return
        }

        if let d = scanVolume.lastSeedDepth, d < 0.6 {
            overlay?.updateGuidance(.stepBack, volumeM3: m.volume, progress: progress)
            return
        }

        if capturedBuckets.count < Self.requiredBuckets || scanFrames.count < Self.requiredFrames {
            let camPos = simd_float3(frame.camera.transform.columns.3.x,
                                     frame.camera.transform.columns.3.y,
                                     frame.camera.transform.columns.3.z)
            let left = orbitDirectionIsLeft(camera: camPos, centroid: c, frame: frame)
            overlay?.updateGuidance(.orbit(left: left), volumeM3: m.volume, progress: progress)
            return
        }

        guard volumeIsStable else {
            overlay?.updateGuidance(.hold, volumeM3: m.volume, progress: progress)
            return
        }

        overlay?.updateGuidance(.done, volumeM3: m.volume, progress: 1)
        finalizeScan()
    }

    /// Which way to walk to reach the nearest viewing angle we still lack.
    /// Resolved by projecting the target standpoint into the camera's own
    /// portrait-oriented space, so the arrow can't come out mirrored.
    private func orbitDirectionIsLeft(camera: simd_float3, centroid c: simd_float3, frame: ARFrame) -> Bool {
        let here = currentBucket ?? bearingBucket(camera: camera, centroid: c)
        var target = here
        var bestDistance = Int.max
        for offset in 1...(Self.bucketCount / 2) {
            for candidate in [(here + offset) % Self.bucketCount,
                              (here - offset + Self.bucketCount) % Self.bucketCount] {
                if !capturedBuckets.contains(candidate) && offset < bestDistance {
                    bestDistance = offset
                    target = candidate
                }
            }
            if bestDistance < Int.max { break }
        }

        let radius = simd_length(simd_float2(camera.x - c.x, camera.z - c.z))
        let beta = (Float(target) + 0.5) / Float(Self.bucketCount) * 2 * .pi - .pi
        let standpoint = simd_float3(c.x + radius * sin(beta), camera.y, c.z + radius * cos(beta))
        let inCamera = frame.camera.viewMatrix(for: .portrait) * simd_float4(standpoint, 1)
        return inCamera.x < 0
    }

    // MARK: - Live box

    /// Draw the measured object as a wireframe box and hand the overlay the
    /// screen positions of its L/W/H edges, so the numbers sit on the edges
    /// they describe.
    private func updateBox(with m: Measurement?, frame: ARFrame) {
        guard let arView else { return }
        guard let m else {
            DispatchQueue.main.async { [weak self] in self?.setBoxHidden(true) }
            return
        }

        let node = boxNode ?? makeBoxNode()
        node.isHidden = false
        node.simdPosition = m.center
        node.simdOrientation = simd_quatf(angle: m.yaw, axis: simd_float3(0, 1, 0))
        node.scale = SCNVector3(m.dims.x, m.dims.z, m.dims.y)  // local X=length, Y=height, Z=width

        /// Project a point in the box's local unit space to screen coordinates.
        /// nil when it falls behind the camera.
        func project(_ local: simd_float3) -> CGPoint? {
            let world = node.simdConvertPosition(local, to: nil)
            let p = arView.projectPoint(SCNVector3(world))
            guard p.z > 0, p.z < 1 else { return nil }
            return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        }

        // Edge midpoints of the unit box, one per dimension.
        let anchors: [(simd_float3, String, Float)] = [
            (simd_float3(0, -0.5, 0.5), "L", m.dims.x),
            (simd_float3(0.5, -0.5, 0), "B", m.dims.y),
            (simd_float3(0.5, 0, 0.5), "H", m.dims.z),
        ]
        var tags: [DimensionTag] = []
        for (local, prefix, metres) in anchors {
            guard let point = project(local) else { continue }
            tags.append(DimensionTag(point: point,
                                     text: "\(prefix) \(Int((metres * 100).rounded())) cm"))
        }

        // Focus silhouette: the convex hull of the eight projected corners.
        // Everything outside it gets dimmed, so the customer can see at a glance
        // what is inside the measurement — and, more usefully, when something
        // that shouldn't be has crept in.
        var corners: [CGPoint] = []
        for sx in [Float(-0.5), 0.5] {
            for sy in [Float(-0.5), 0.5] {
                for sz in [Float(-0.5), 0.5] {
                    if let p = project(simd_float3(sx, sy, sz)) { corners.append(p) }
                }
            }
        }
        let hull = corners.count >= 3 ? Self.convexHull(corners) : []

        DispatchQueue.main.async { [weak self] in
            self?.overlay?.updateDimensionTags(tags)
            self?.overlay?.updateFocusSilhouette(hull)
        }
    }

    /// Andrew's monotone chain. Small n (≤8), so the sort dominates and this is
    /// nowhere near hot enough to matter.
    private static func convexHull(_ input: [CGPoint]) -> [CGPoint] {
        let points = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard points.count >= 3 else { return points }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var hull: [CGPoint] = []
        for p in points {
            while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        let lowerCount = hull.count + 1
        for p in points.reversed() {
            while hull.count >= lowerCount, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        hull.removeLast()
        return hull
    }

    private func makeBoxNode() -> SCNNode {
        let container = SCNNode()

        // Unit box, scaled per measurement — mutating geometry every fit would
        // rebuild the mesh several times a second.
        //
        // The 12 edges are drawn as explicit line primitives. An SCNBox with
        // `fillMode = .lines` wireframes the *triangulated* mesh instead, which
        // puts a diagonal across every face — that reads as a mess, not as the
        // outline of the thing being measured.
        let wireMat = SCNMaterial()
        wireMat.diffuse.contents = UIColor.white
        wireMat.emission.contents = UIColor.white
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

        let fill = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        let fillMat = SCNMaterial()
        fillMat.diffuse.contents = UIColor(red: 252/255, green: 96/255, blue: 24/255, alpha: 0.16)
        fillMat.lightingModel = .constant
        fillMat.isDoubleSided = true
        fillMat.writesToDepthBuffer = false
        fillMat.readsFromDepthBuffer = false
        fill.materials = [fillMat]
        container.addChildNode(SCNNode(geometry: fill))

        container.renderingOrder = 100
        arView?.scene.rootNode.addChildNode(container)
        boxNode = container
        return container
    }

    private func setBoxHidden(_ hidden: Bool) {
        boxNode?.isHidden = hidden
        if hidden {
            overlay?.updateDimensionTags([])
            overlay?.updateFocusSilhouette([])
        }
    }

    private func removeBoxNode() {
        boxNode?.removeFromParentNode()
        boxNode = nil
        overlay?.updateDimensionTags([])
        overlay?.updateFocusSilhouette([])
    }

    // MARK: - Finishing

    /// End the measurement and hand it to the review card. Nothing is saved yet.
    private func finalizeScan() {
        guard scanActive else { return }
        scanActive = false
        let snap = scanVolume.snapshot()
        let measured = VolumeAccumulator.measure(points: snap.points,
                                                 framesUsed: snap.frames,
                                                 anchor: snap.anchor) ?? lastMeasurement
        let spanDeg = Float(capturedBuckets.count) * (360.0 / Float(Self.bucketCount))
        pendingItem = SavedItem(label: scanSuggestedLabel,
                                frames: scanFrames,
                                arcDegrees: hasLidar ? spanDeg : scanAccumulatedDeg,
                                hasDepth: scanFrames.contains { $0.depthMapBase64 != nil },
                                volumeM3: measured?.volume,
                                dims: measured?.dims,
                                deviceConfidence: measured?.confidence)
        // Unpack the OBB here: `measured?.dims.map { … }` would chain onto the
        // unwrapped simd_float3 (whose `map` hands out Floats), not the Optional.
        let dimsArray: [Float]? = measured.map { [$0.dims.x, $0.dims.y, $0.dims.z] }
        let suggestion = scanSuggestedLabel
        let measurable = hasLidar
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.removeBoxNode()
            self.overlay?.showReview(volumeM3: measured?.volume,
                                     dims: dimsArray,
                                     suggestedLabel: suggestion,
                                     measurable: measurable)
        }
    }

    /// Save the reviewed item. `label` may be empty — the backend names it from
    /// the photo, so a blank name never costs a measurement.
    private func commitPendingItem(label: String) {
        guard var item = pendingItem else { return }
        item.label = label.trimmingCharacters(in: .whitespaces)
        pendingItem = nil
        savedItems.append(item)
        announceSaved(item)
    }

    // MARK: - Manual entry

    /// Escape hatch for items the depth camera can't handle — glass, mirrors,
    /// black leather, anything wedged into a corner. Keeps one photo so the
    /// item still has something the backend can look at.
    private func beginManualEntry() {
        if scanFrames.isEmpty, let frame = arView?.session.currentFrame {
            captureFrame(frame, depth: nil)
        }
        scanActive = false
        removeBoxNode()
        let suggestion = scanSuggestedLabel.isEmpty ? silentLabelGuess : scanSuggestedLabel
        DispatchQueue.main.async { [weak self] in
            self?.overlay?.showManualEntry(suggestedLabel: suggestion)
        }
    }

    private func commitManualItem(_ entry: ManualEntry) {
        let frames = scanFrames
        scanFrames = []
        scanVolume.reset()
        let item = SavedItem(label: entry.label.trimmingCharacters(in: .whitespaces),
                             frames: frames,
                             arcDegrees: 0,
                             hasDepth: false,
                             volumeM3: entry.volumeM3,
                             dims: entry.dims,
                             // Customer-stated numbers: trusted, but not more
                             // than a clean on-device measurement.
                             deviceConfidence: 0.85)
        savedItems.append(item)
        announceSaved(item)
    }

    private func announceSaved(_ item: SavedItem) {
        var eventData: [String: Any] = [
            "label": item.label, "frameCount": item.frames.count,
            "arcDegrees": item.arcDegrees, "hasDepth": item.hasDepth,
        ]
        if let v = item.volumeM3 { eventData["volumeM3"] = v }
        notifyListeners("itemSaved", data: eventData)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanFrames = []
            self.overlay?.updateItemCount(self.savedItems.count)
            self.overlay?.showSavedFlash(label: item.label, volumeM3: item.volumeM3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.overlay?.setState(.idle)
            }
        }
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

        if scanActive {
            processScanFrame(frame)
        } else if pendingItem == nil {
            // Keep a name suggestion warm for the review card. Nothing is drawn.
            frameCounter += 1
            if frameCounter % yoloEveryNFrames == 0 {
                let buf = frame.capturedImage
                DispatchQueue.global(qos: .utility).async { [weak self] in self?.runYOLO(on: buf) }
            }
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

// MARK: - ScanOverlayView (100% native UI)
//
// Guided measurement UI. One instruction at a time, the measured box drawn in
// place with its L/B/H on the matching edges, and a manual escape hatch for
// objects LiDAR can't see. Detection is never drawn — it only pre-fills a name.

private class ScanOverlayView: UIView {

    enum State { case idle, measuring, review, manual, itemSaved }

    // Callbacks
    var onClose: (() -> Void)?
    var onFinish: (() -> Void)?
    /// Measure whatever is in the reticle — no name required.
    var onMeasureRequested: (() -> Void)?
    var onCancelMeasurement: (() -> Void)?
    /// Take the current measurement without covering every remaining angle.
    var onAcceptEarly: (() -> Void)?
    /// Save the reviewed item; empty means "let the backend name it".
    var onSaveItem: ((String) -> Void)?
    var onRemeasure: (() -> Void)?
    var onManualRequested: (() -> Void)?
    var onManualSubmit: ((ManualEntry) -> Void)?
    var onManualCancel: (() -> Void)?

    /// False on devices without LiDAR — the copy then promises photos, not metres.
    var canMeasure = true { didSet { updateHint() } }

    private var state: State = .idle
    private var itemCount = 0
    private var hasLiveVolume = false

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

    // ── Reticle ──────────────────────────────────────────────────────────
    // Segmentation seeds from the frame centre, so "what's in the middle gets
    // measured" is a hard rule of the pipeline — the UI has to say it.
    private let reticle = UIView()
    private let reticleLayer = CAShapeLayer()

    // ── Idle bottom bar ──────────────────────────────────────────────────
    private let bottomBar = UIView()
    private let measureBtn = UIButton(type: .custom)
    private let measureRing = CAShapeLayer()
    private let finishBtn = UIButton(type: .system)
    private let manualBtn = UIButton(type: .system)
    private let hintLabel = UILabel()

    // ── Measuring HUD ────────────────────────────────────────────────────
    private let hud = UIView()
    private let guidanceCard = UIView()
    private let guidanceArrow = UILabel()
    private let guidanceText = UILabel()
    private let volumePill = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressValue: Float = 0
    private let hudCancel = UIButton(type: .system)
    private let hudManual = UIButton(type: .system)
    private let hudAccept = UIButton(type: .system)
    /// One label per dimension, positioned over the box edge it describes.
    private var dimLabels: [UILabel] = []
    /// Dims everything outside the measured box, so what is (and isn't) part of
    /// the measurement is visible rather than inferred.
    private let focusScrim = CAShapeLayer()

    // ── Toast ────────────────────────────────────────────────────────────
    private let toastLabel = UILabel()
    private var toastHideWork: DispatchWorkItem?

    // ── Review card ──────────────────────────────────────────────────────
    private let reviewCard = UIView()
    private let reviewTitle = UILabel()
    private let reviewVolume = UILabel()
    private let reviewDims = UILabel()
    private let reviewField = UITextField()
    private let reviewFieldHint = UILabel()
    private let reviewSave = UIButton(type: .system)
    private let reviewRemeasure = UIButton(type: .system)

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
        buildHUD()
        buildReviewCard()
        buildManualCard()
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

        hintLabel.textColor = UIColor.white.withAlphaComponent(0.85)
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

        manualBtn.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        manualBtn.layer.cornerRadius = 12
        manualBtn.setTitle("Manuell", for: .normal)
        manualBtn.setTitleColor(.white, for: .normal)
        manualBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        manualBtn.addTarget(self, action: #selector(manualTapped), for: .touchUpInside)
        bottomBar.addSubview(manualBtn)

        finishBtn.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        finishBtn.layer.cornerRadius = 12
        finishBtn.setTitle("Fertig", for: .normal)
        finishBtn.setTitleColor(.white, for: .normal)
        finishBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        finishBtn.alpha = 0.4
        finishBtn.isEnabled = false
        finishBtn.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
        bottomBar.addSubview(finishBtn)
    }

    private func buildHUD() {
        hud.isHidden = true
        addSubview(hud)

        // Even-odd fill: the full screen minus the box silhouette.
        focusScrim.fillRule = .evenOdd
        focusScrim.fillColor = UIColor.black.withAlphaComponent(0.42).cgColor
        focusScrim.isHidden = true
        hud.layer.addSublayer(focusScrim)

        // The instruction — one at a time, arrow first because that is the part
        // people act on without reading.
        guidanceCard.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        guidanceCard.layer.cornerRadius = 20
        hud.addSubview(guidanceCard)

        guidanceArrow.font = .systemFont(ofSize: 30, weight: .bold)
        guidanceArrow.textColor = Self.orange
        guidanceArrow.textAlignment = .center
        guidanceCard.addSubview(guidanceArrow)

        guidanceText.font = .systemFont(ofSize: 15, weight: .semibold)
        guidanceText.textColor = .white
        guidanceText.numberOfLines = 2
        guidanceCard.addSubview(guidanceText)

        volumePill.font = .systemFont(ofSize: 26, weight: .bold)
        volumePill.textColor = .white
        volumePill.textAlignment = .center
        volumePill.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        volumePill.layer.cornerRadius = 22
        volumePill.clipsToBounds = true
        hud.addSubview(volumePill)

        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        progressTrack.layer.cornerRadius = 3
        progressTrack.clipsToBounds = true
        hud.addSubview(progressTrack)
        progressFill.backgroundColor = Self.orange
        progressTrack.addSubview(progressFill)

        hudCancel.setTitle("Abbrechen", for: .normal)
        hudCancel.setTitleColor(.white, for: .normal)
        hudCancel.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        hudCancel.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        hudCancel.layer.cornerRadius = 12
        hudCancel.addTarget(self, action: #selector(cancelMeasurementTapped), for: .touchUpInside)
        hud.addSubview(hudCancel)

        hudManual.setTitle("Manuell", for: .normal)
        hudManual.setTitleColor(.white, for: .normal)
        hudManual.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        hudManual.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        hudManual.layer.cornerRadius = 12
        hudManual.addTarget(self, action: #selector(manualTapped), for: .touchUpInside)
        hud.addSubview(hudManual)

        // Escape from a measurement that is "good enough" without walking the
        // last few degrees. Enabled as soon as there is any volume at all.
        hudAccept.setTitle("Übernehmen", for: .normal)
        hudAccept.setTitleColor(.white, for: .normal)
        hudAccept.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        hudAccept.backgroundColor = Self.orange
        hudAccept.layer.cornerRadius = 12
        hudAccept.alpha = 0.35
        hudAccept.isEnabled = false
        hudAccept.addTarget(self, action: #selector(acceptEarlyTapped), for: .touchUpInside)
        hud.addSubview(hudAccept)

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

    private func buildReviewCard() {
        reviewCard.backgroundColor = Self.cardBg
        reviewCard.layer.cornerRadius = 24
        reviewCard.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        reviewCard.isHidden = true
        addSubview(reviewCard)

        reviewTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        reviewTitle.textColor = Self.subtle
        reviewCard.addSubview(reviewTitle)

        reviewVolume.font = .systemFont(ofSize: 40, weight: .bold)
        reviewVolume.textColor = Self.navy
        reviewCard.addSubview(reviewVolume)

        reviewDims.font = .systemFont(ofSize: 14, weight: .regular)
        reviewDims.textColor = Self.subtle
        reviewDims.numberOfLines = 2
        reviewCard.addSubview(reviewDims)

        styleField(reviewField, placeholder: "Bezeichnung (optional)")
        reviewCard.addSubview(reviewField)

        reviewFieldHint.text = "Ohne Bezeichnung erkennen wir das Objekt automatisch."
        reviewFieldHint.font = .systemFont(ofSize: 12)
        reviewFieldHint.textColor = UIColor(red: 142/255, green: 145/255, blue: 152/255, alpha: 1)
        reviewFieldHint.numberOfLines = 2
        reviewCard.addSubview(reviewFieldHint)

        styleSecondary(reviewRemeasure, title: "Erneut messen")
        reviewRemeasure.addTarget(self, action: #selector(remeasureTapped), for: .touchUpInside)
        reviewCard.addSubview(reviewRemeasure)

        stylePrimary(reviewSave, title: "Sichern")
        reviewSave.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        reviewCard.addSubview(reviewSave)
    }

    private func buildManualCard() {
        manualCard.backgroundColor = Self.cardBg
        manualCard.layer.cornerRadius = 24
        manualCard.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        manualCard.isHidden = true
        addSubview(manualCard)

        manualTitle.text = "Manuell eintragen"
        manualTitle.font = .systemFont(ofSize: 20, weight: .bold)
        manualTitle.textColor = Self.navy
        manualCard.addSubview(manualTitle)

        manualSubtitle.text = "Für Objekte, die sich nicht messen lassen — Glas, Spiegel, dunkles Leder."
        manualSubtitle.font = .systemFont(ofSize: 13)
        manualSubtitle.textColor = Self.subtle
        manualSubtitle.numberOfLines = 2
        manualCard.addSubview(manualSubtitle)

        styleField(manualName, placeholder: "Bezeichnung (optional)")
        manualCard.addSubview(manualName)

        manualMode.selectedSegmentIndex = 0
        manualMode.addTarget(self, action: #selector(manualModeChanged), for: .valueChanged)
        manualCard.addSubview(manualMode)

        for (field, placeholder) in [(manualL, "Länge cm"), (manualW, "Breite cm"), (manualH, "Höhe cm")] {
            styleField(field, placeholder: placeholder)
            field.keyboardType = .decimalPad
            field.textAlignment = .center
            manualCard.addSubview(field)
        }
        styleField(manualVolume, placeholder: "Volumen in m³, z. B. 1,2")
        manualVolume.keyboardType = .decimalPad
        manualVolume.isHidden = true
        manualCard.addSubview(manualVolume)

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
        field.backgroundColor = Self.fieldBg
        field.layer.cornerRadius = 12
        field.autocapitalizationType = .sentences
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        field.leftViewMode = .always
    }

    private func stylePrimary(_ button: UIButton, title: String) {
        button.backgroundColor = Self.navy
        button.layer.cornerRadius = 12
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
    }

    private func styleSecondary(_ button: UIButton, title: String) {
        button.backgroundColor = Self.fieldBg
        button.layer.cornerRadius = 12
        button.setTitle(title, for: .normal)
        button.setTitleColor(UIColor(red: 67/255, green: 71/255, blue: 78/255, alpha: 1), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
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
        let h = bounds.height

        // Top bar
        countPill.frame = CGRect(x: 20, y: safe.top + 8, width: 130, height: 32)
        countDot.frame = CGRect(x: 12, y: 12, width: 8, height: 8)
        countLabel.frame = CGRect(x: 28, y: 0, width: 96, height: 32)
        closeBtn.frame = CGRect(x: w - 60, y: safe.top + 4, width: 40, height: 40)

        // Reticle: centred square with corner brackets
        let side: CGFloat = min(w, h) * 0.6
        let cy = h / 2 - 40
        reticle.frame = CGRect(x: (w - side) / 2, y: cy - side / 2, width: side, height: side)
        reticleLayer.frame = reticle.bounds
        reticleLayer.path = cornerBracketPath(in: reticle.bounds, arm: side * 0.18, radius: 14).cgPath

        // Idle bottom bar
        let bbH: CGFloat = 150
        bottomBar.frame = CGRect(x: 0, y: h - bbH - safe.bottom, width: w, height: bbH)
        hintLabel.frame = CGRect(x: (w - 320) / 2, y: 8, width: 320, height: 28)
        let btn: CGFloat = 78
        measureBtn.frame = CGRect(x: (w - btn) / 2, y: 52, width: btn, height: btn)
        measureRing.frame = measureBtn.bounds
        measureRing.path = UIBezierPath(ovalIn: measureBtn.bounds.insetBy(dx: 8, dy: 8)).cgPath
        let sideBtnY = 52 + (btn - 44) / 2
        manualBtn.frame = CGRect(x: 20, y: sideBtnY, width: 92, height: 44)
        finishBtn.frame = CGRect(x: w - 112 - 20, y: sideBtnY, width: 112, height: 44)

        // Measuring HUD
        hud.frame = bounds
        focusScrim.frame = bounds
        toastLabel.frame = CGRect(x: 24, y: safe.top + 140, width: w - 48, height: 44)
        let gcW = w - 40
        guidanceCard.frame = CGRect(x: 20, y: safe.top + 56, width: gcW, height: 72)
        guidanceArrow.frame = CGRect(x: 16, y: 16, width: 44, height: 40)
        guidanceText.frame = CGRect(x: 68, y: 12, width: gcW - 84, height: 48)

        let hudBtnY = h - safe.bottom - 66
        volumePill.frame = CGRect(x: (w - 200) / 2, y: hudBtnY - 92, width: 200, height: 44)
        progressTrack.frame = CGRect(x: 40, y: hudBtnY - 34, width: w - 80, height: 6)
        layoutProgressFill()
        let hudBtnW = (w - 40 - 24) / 3
        hudCancel.frame = CGRect(x: 20, y: hudBtnY, width: hudBtnW, height: 50)
        hudManual.frame = CGRect(x: 20 + hudBtnW + 12, y: hudBtnY, width: hudBtnW, height: 50)
        hudAccept.frame = CGRect(x: 20 + 2 * (hudBtnW + 12), y: hudBtnY, width: hudBtnW, height: 50)

        // Review card
        let reviewH: CGFloat = 330 + safe.bottom
        reviewCard.frame = CGRect(x: 0, y: h - reviewH - cardKeyboardShift, width: w, height: reviewH)
        reviewTitle.frame = CGRect(x: 24, y: 24, width: w - 48, height: 18)
        reviewVolume.frame = CGRect(x: 24, y: 44, width: w - 48, height: 48)
        reviewDims.frame = CGRect(x: 24, y: 94, width: w - 48, height: 34)
        reviewField.frame = CGRect(x: 24, y: 134, width: w - 48, height: 48)
        reviewFieldHint.frame = CGRect(x: 24, y: 188, width: w - 48, height: 32)
        let rbW = (w - 60) / 2
        reviewRemeasure.frame = CGRect(x: 24, y: 232, width: rbW, height: 50)
        reviewSave.frame = CGRect(x: 24 + rbW + 12, y: 232, width: rbW, height: 50)

        // Manual card
        let manualCardH: CGFloat = 400 + safe.bottom
        manualCard.frame = CGRect(x: 0, y: h - manualCardH - cardKeyboardShift, width: w, height: manualCardH)
        manualTitle.frame = CGRect(x: 24, y: 22, width: w - 48, height: 26)
        manualSubtitle.frame = CGRect(x: 24, y: 50, width: w - 48, height: 34)
        manualName.frame = CGRect(x: 24, y: 92, width: w - 48, height: 46)
        manualMode.frame = CGRect(x: 24, y: 148, width: w - 48, height: 34)
        let triW = (w - 48 - 20) / 3
        manualL.frame = CGRect(x: 24, y: 194, width: triW, height: 46)
        manualW.frame = CGRect(x: 24 + triW + 10, y: 194, width: triW, height: 46)
        manualH.frame = CGRect(x: 24 + 2 * (triW + 10), y: 194, width: triW, height: 46)
        manualVolume.frame = CGRect(x: 24, y: 194, width: w - 48, height: 46)
        manualHint.frame = CGRect(x: 24, y: 248, width: w - 48, height: 32)
        manualCancelBtn.frame = CGRect(x: 24, y: 292, width: rbW, height: 50)
        manualSaveBtn.frame = CGRect(x: 24 + rbW + 12, y: 292, width: rbW, height: 50)

        // Flash
        flashView.frame = bounds
        flashCheck.frame = CGRect(x: (w - 80) / 2, y: h / 2 - 80, width: 80, height: 80)
        flashLabel.frame = CGRect(x: 20, y: h / 2 + 16, width: w - 40, height: 30)
        flashSub.frame = CGRect(x: 20, y: h / 2 + 50, width: w - 40, height: 20)
    }

    private func layoutProgressFill() {
        progressFill.frame = CGRect(x: 0, y: 0,
                                    width: progressTrack.bounds.width * CGFloat(progressValue),
                                    height: progressTrack.bounds.height)
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
        bottomBar.isHidden = !idle
        // During measuring the AR box replaces the reticle — the object is
        // already identified, so a second frame around it would just be noise.
        reticle.isHidden = newState != .idle
        hud.isHidden = newState != .measuring
        flashView.isHidden = newState != .itemSaved
        if newState != .review { reviewCard.isHidden = true }
        if newState != .manual { manualCard.isHidden = true }
        if newState != .review && newState != .manual {
            endEditing(true)
            cardKeyboardShift = 0
        }
        if newState != .measuring {
            updateDimensionTags([])
            updateFocusSilhouette([])
            hideToast()
            hasLiveVolume = false
            setAcceptEnabled(false)
        }
        updateHint()
        setNeedsLayout()
    }

    func updateItemCount(_ count: Int) {
        itemCount = count
        countLabel.text = "\(count) \(count == 1 ? "Objekt" : "Objekte")"
        countDot.backgroundColor = count > 0
            ? UIColor(red: 74/255, green: 222/255, blue: 128/255, alpha: 1)
            : UIColor.white.withAlphaComponent(0.3)
        finishBtn.isEnabled = count > 0
        finishBtn.alpha = count > 0 ? 1.0 : 0.4
        finishBtn.setTitle(count > 0 ? "Fertig (\(count))" : "Fertig", for: .normal)
    }

    // MARK: - Measuring feedback

    /// One instruction, the live volume, and how far along we are. Called a few
    /// times a second while measuring.
    func updateGuidance(_ guidance: Guidance, volumeM3: Float?, progress: Float) {
        switch guidance {
        case .aim:
            guidanceArrow.text = "◎"
            guidanceText.text = "Objekt mittig anvisieren und ruhig halten"
        case .reacquire:
            guidanceArrow.text = "◎"
            guidanceText.text = "Objekt aus dem Blick verloren — wieder anvisieren"
        case .stepBack:
            guidanceArrow.text = "↔"
            guidanceText.text = "Etwas zurücktreten — das Objekt passt nicht ganz ins Bild"
        case .orbit(let left):
            guidanceArrow.text = left ? "←" : "→"
            guidanceText.text = left
                ? "Langsam nach links um das Objekt gehen"
                : "Langsam nach rechts um das Objekt gehen"
        case .photoSweep:
            guidanceArrow.text = "↻"
            guidanceText.text = "Langsam um das Objekt gehen — wir sammeln Fotos aus mehreren Winkeln"
        case .hold:
            guidanceArrow.text = "✓"
            guidanceText.text = "Fast fertig — Objekt noch einen Moment im Blick behalten"
        case .done:
            guidanceArrow.text = "✓"
            guidanceText.text = "Messung abgeschlossen"
        }

        if let v = volumeM3 {
            volumePill.text = "≈ \(Self.formatVolume(v)) m³"
            volumePill.isHidden = false
            hasLiveVolume = true
        } else {
            volumePill.isHidden = !canMeasure
            volumePill.text = "– m³"
            hasLiveVolume = false
        }
        setAcceptEnabled(hasLiveVolume)

        progressValue = max(0, min(1, progress))
        UIView.animate(withDuration: 0.2) { self.layoutProgressFill() }
    }

    private func setAcceptEnabled(_ enabled: Bool) {
        hudAccept.isEnabled = enabled
        hudAccept.alpha = enabled ? 1.0 : 0.35
    }

    /// Position the L/B/H readouts over the box edges they belong to. Labels are
    /// pooled — the tag count changes every frame as edges rotate out of view.
    func updateDimensionTags(_ tags: [DimensionTag]) {
        while dimLabels.count < tags.count {
            let label = UILabel()
            label.font = .systemFont(ofSize: 13, weight: .bold)
            label.textColor = .white
            label.textAlignment = .center
            label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
            label.layer.cornerRadius = 11
            label.clipsToBounds = true
            hud.addSubview(label)
            dimLabels.append(label)
        }
        for (i, label) in dimLabels.enumerated() {
            guard i < tags.count else { label.isHidden = true; continue }
            let tag = tags[i]
            label.isHidden = false
            label.text = tag.text
            let size = CGSize(width: 92, height: 22)
            label.frame = CGRect(x: tag.point.x - size.width / 2,
                                 y: tag.point.y - size.height / 2,
                                 width: size.width, height: size.height)
        }
    }

    /// Dim everything outside the measured box. An empty hull clears it.
    func updateFocusSilhouette(_ hull: [CGPoint]) {
        guard hull.count >= 3 else {
            focusScrim.isHidden = true
            return
        }
        let path = UIBezierPath(rect: bounds)
        let cutout = UIBezierPath()
        cutout.move(to: hull[0])
        for p in hull.dropFirst() { cutout.addLine(to: p) }
        cutout.close()
        path.append(cutout)
        // No implicit animation: the scrim has to track the box frame-for-frame,
        // and a quarter-second default animation on every update reads as lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusScrim.path = path.cgPath
        focusScrim.isHidden = false
        CATransaction.commit()
    }

    // MARK: - Toast

    /// Brief, non-blocking notice. Used when the measurement restarts on a
    /// different object — the customer needs to know it happened, but stopping
    /// them to confirm it would be worse than the restart itself.
    func showToast(_ text: String) {
        toastLabel.text = text
        toastHideWork?.cancel()
        bringSubviewToFront(toastLabel)
        UIView.animate(withDuration: 0.2) { self.toastLabel.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.toastLabel.alpha = 0 }
        }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    func hideToast() {
        toastHideWork?.cancel()
        guard toastLabel.alpha > 0 else { return }
        UIView.animate(withDuration: 0.25) { self.toastLabel.alpha = 0 }
    }

    // MARK: - Review

    /// Present the finished measurement for confirmation. `volumeM3 == nil` means
    /// the sweep produced no usable measurement (or the device has no LiDAR) —
    /// the photos are still worth keeping, the backend estimates from them.
    func showReview(volumeM3: Float?, dims: [Float]?, suggestedLabel: String, measurable: Bool) {
        if let v = volumeM3 {
            reviewTitle.text = "GEMESSENES VOLUMEN"
            reviewVolume.text = "≈ \(Self.formatVolume(v)) m³"
            reviewVolume.textColor = Self.navy
            if let d = dims, d.count == 3 {
                reviewDims.text = "\(Self.formatCm(d[0])) × \(Self.formatCm(d[1])) × \(Self.formatCm(d[2])) cm  ·  inkl. Ladespielraum"
            } else {
                reviewDims.text = "inkl. Ladespielraum"
            }
            reviewSave.setTitle("Sichern", for: .normal)
        } else if measurable {
            reviewTitle.text = "MESSUNG UNVOLLSTÄNDIG"
            reviewVolume.text = "Kein Volumen"
            reviewVolume.textColor = Self.orange
            reviewDims.text = "Erneut messen — oder die Maße von Hand eintragen."
            reviewSave.setTitle("Trotzdem sichern", for: .normal)
        } else {
            reviewTitle.text = "AUFNAHME GESPEICHERT"
            reviewVolume.text = "Fotos erfasst"
            reviewVolume.textColor = Self.navy
            reviewDims.text = "Dieses Gerät misst nicht — wir berechnen das Volumen aus den Fotos."
            reviewSave.setTitle("Sichern", for: .normal)
        }
        reviewField.text = suggestedLabel

        setState(.review)
        reviewCard.isHidden = false
        presentCard(reviewCard)
    }

    func showSavedFlash(label: String, volumeM3: Float? = nil) {
        flashLabel.text = volumeM3.map { "≈ \(Self.formatVolume($0)) m³" } ?? "Gespeichert"
        flashSub.text = label.isEmpty ? "wird automatisch benannt" : label
        setState(.itemSaved)
    }

    // MARK: - Manual entry

    func showManualEntry(suggestedLabel: String) {
        manualName.text = suggestedLabel
        manualL.text = ""; manualW.text = ""; manualH.text = ""; manualVolume.text = ""
        manualMode.selectedSegmentIndex = 0
        updateManualMode()
        setState(.manual)
        manualCard.isHidden = false
        presentCard(manualCard)
    }

    private func presentCard(_ card: UIView) {
        // Lay out first: on the very first present the card still has a zero
        // frame, and sliding in from zero is just a pop.
        layoutIfNeeded()
        card.transform = CGAffineTransform(translationX: 0, y: card.bounds.height)
        UIView.animate(withDuration: 0.28) { card.transform = .identity }
    }

    @objc private func manualModeChanged() { updateManualMode() }

    private func updateManualMode() {
        let byDims = manualMode.selectedSegmentIndex == 0
        manualL.isHidden = !byDims
        manualW.isHidden = !byDims
        manualH.isHidden = !byDims
        manualVolume.isHidden = byDims
        manualHint.text = byDims
            ? "Außenmaße in Zentimetern. Ladespielraum rechnen wir dazu."
            : "Volumen in Kubikmetern, so wie Sie es angeben."
    }

    /// Accepts both German and English decimal separators — the numeric keypad
    /// shows whichever the device locale prefers.
    private static func parseNumber(_ text: String?) -> Float? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return Float(raw.replacingOccurrences(of: ",", with: "."))
    }

    // MARK: - Private

    private func updateHint() {
        guard state == .idle else { return }
        if !canMeasure {
            hintLabel.text = "  Objekt in den Rahmen nehmen und aufnehmen  "
        } else if itemCount == 0 {
            hintLabel.text = "  Objekt in den Rahmen nehmen und messen  "
        } else {
            hintLabel.text = "  Nächstes Objekt messen oder abschließen  "
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
        guard let card = activeCard,
              let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        // Lift the card just enough to keep its buttons above the keyboard.
        let keyboardTop = bounds.height - frameValue.cgRectValue.height
        let cardBottom = card.frame.maxY + cardKeyboardShift
        cardKeyboardShift = max(0, cardBottom - keyboardTop + 12)
        animateCardShift()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        guard cardKeyboardShift != 0 else { return }
        cardKeyboardShift = 0
        animateCardShift()
    }

    private var activeCard: UIView? {
        switch state {
        case .review: return reviewCard
        case .manual: return manualCard
        default: return nil
        }
    }

    private func animateCardShift() {
        setNeedsLayout()
        UIView.animate(withDuration: 0.25) { self.layoutIfNeeded() }
    }

    // MARK: - Actions

    @objc private func closeTapped() { onClose?() }
    @objc private func finishTapped() { onFinish?() }
    @objc private func measureTapped() { onMeasureRequested?() }
    @objc private func cancelMeasurementTapped() { onCancelMeasurement?() }
    @objc private func acceptEarlyTapped() { onAcceptEarly?() }
    @objc private func manualTapped() { onManualRequested?() }
    @objc private func manualCancelTapped() { endEditing(true); onManualCancel?() }

    @objc private func saveTapped() {
        endEditing(true)
        onSaveItem?(reviewField.text?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    @objc private func remeasureTapped() {
        endEditing(true)
        onRemeasure?()
    }

    @objc private func manualSaveTapped() {
        endEditing(true)
        let label = manualName.text?.trimmingCharacters(in: .whitespaces) ?? ""

        if manualMode.selectedSegmentIndex == 0 {
            guard let l = Self.parseNumber(manualL.text),
                  let b = Self.parseNumber(manualW.text),
                  let hh = Self.parseNumber(manualH.text),
                  l > 0, b > 0, hh > 0 else {
                flagManual([manualL, manualW, manualH])
                return
            }
            let dims = simd_float3(l / 100, b / 100, hh / 100)
            // Same packing factor the measured path applies, so a typed sofa and
            // a scanned sofa price the same.
            let volume = dims.x * dims.y * dims.z * VolumeAccumulator.packingFactor
            guard volume.isFinite, volume >= 0.005, volume <= 12.0 else {
                flagManual([manualL, manualW, manualH])
                return
            }
            onManualSubmit?(ManualEntry(label: label, volumeM3: volume, dims: dims))
        } else {
            guard let v = Self.parseNumber(manualVolume.text),
                  v.isFinite, v >= 0.005, v <= 12.0 else {
                flagManual([manualVolume])
                return
            }
            onManualSubmit?(ManualEntry(label: label, volumeM3: v, dims: nil))
        }
    }

    /// Nudge the offending fields rather than throwing up an alert.
    private func flagManual(_ fields: [UITextField]) {
        for field in fields where !field.isHidden {
            field.layer.borderColor = Self.orange.cgColor
            field.layer.borderWidth = 1.5
        }
        UIView.animate(withDuration: 0.25, delay: 1.4, options: []) {
            for field in fields { field.layer.borderWidth = 0 }
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let card = activeCard else { return }
        // Tapping outside the open card just dismisses the keyboard.
        if !card.frame.contains(gesture.location(in: self)) { endEditing(true) }
    }
}

// MARK: - UITextFieldDelegate

extension ScanOverlayView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
