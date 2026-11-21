import Foundation

/// Upright: perspective correction worked out from the photo's straight lines (LineDetector), the
/// classical way. The lines that are nearly upright meet at a vanishing point, the nearly level ones
/// at another; the correction is the turn of the camera that would have made the upright lines
/// parallel (and, for Full, the level ones too), applied to the picture as a projective transform
/// K·R·K⁻¹ (K: a pinhole camera of focal length f, R: the turn). A turn of the camera never shears the
/// picture, so the result looks natural; the middle of the picture stays where it is, at the same scale.
///
/// Modes, as in Lightroom: level (turn about the middle only, levelling the horizontals), vertical
/// (upright lines made parallel and upright), full (vertical and horizontal perspective), auto
/// (vertical when the photo's upright lines agree and the correction stays moderate, else level),
/// guided (from up to four lines drawn by hand along edges that should be upright or level).
public enum Upright {
    /// Option ids of the "upright" choice; must match controls.json (unit-tested).
    public static let modes = ["off", "auto", "level", "vertical", "full", "guided"]

    /// Guided upright draws at most this many guides (a new one replaces the oldest).
    public static let maxGuides = 4

    /// A 3-vector (directions through the camera, homogeneous points and lines).
    struct V3 {
        var x, y, z: Double

        init(_ x: Double, _ y: Double, _ z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }

        static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
        static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
        static func * (a: V3, k: Double) -> V3 { V3(a.x * k, a.y * k, a.z * k) }
        func dot(_ b: V3) -> Double { x * b.x + y * b.y + z * b.z }
        func cross(_ b: V3) -> V3 { V3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
        var length: Double { dot(self).squareRoot() }
        var unit: V3 { let l = length; return l > 1e-15 ? self * (1 / l) : self }
    }

    /// The camera: focal length and the picture's middle, in pixels.
    struct Camera {
        let f: Double
        let cx: Double
        let cy: Double

        /// The direction a pixel looks along.
        func ray(_ p: Vec2) -> V3 { V3((p.x - cx) / f, (p.y - cy) / f, 1) }

        /// K·R·K⁻¹ for a camera turn R (rows), as a picture transform.
        func transform(_ r: [Double]) -> Homography {
            let k = Homography([f, 0, cx, 0, f, cy, 0, 0, 1])
            let kInv = Homography([1 / f, 0, -cx / f, 0, 1 / f, -cy / f, 0, 0, 1])
            return k * Homography(r) * kInv
        }
    }

    /// The default focal length: a moderately wide lens, 0.85 × the long side.
    static func defaultFocal(width: Double, height: Double) -> Double { 0.85 * Swift.max(width, height) }

    /// The Upright transform for `mode`, in pixels of a `width` × `height` photo (the frame keeps its
    /// size; the middle stays). Identity when the photo has no lines to go by.
    public static func transform(mode: String, segments: [LineSegment], width: Double, height: Double,
                                 guides: [[MaskPoint]] = []) -> Homography {
        guard mode != "off", width > 0, height > 0 else { return .identity }
        if mode == "guided" { return guided(guides, width: width, height: height) }
        var camera = Camera(f: defaultFocal(width: width, height: height), cx: width / 2, cy: height / 2)
        let lines = segments.map { s -> (Vec2, Vec2, Double) in
            let (a, b) = s.ends(width: width, height: height)
            return (a, b, (b - a).length)
        }
        let long = Swift.max(width, height)
        let uprights = lines.filter { abs(angleFromUpright($0.0, $0.1)) <= 30 }
        let levels = lines.filter { abs(Straighten.deviation($0.0, $0.1)) <= 45 && abs(angleFromUpright($0.0, $0.1)) > 30 }
        let vertical = vanishingDirection(uprights, camera: camera, minSupport: 0.15 * long)
        let horizontal = mode == "full" ? vanishingDirection(levels, camera: camera, minSupport: 0.15 * long) : nil
        // Two vanishing points at right angles tell the focal length: f² = −(v1 − c)·(v2 − c).
        if let v = vertical, let h = horizontal, abs(v.z) > 1e-6, abs(h.z) > 1e-6 {
            let pv = Vec2(v.x / v.z, v.y / v.z), ph = Vec2(h.x / h.z, h.y / h.z)  // in units of f, from the middle
            let f2 = -(pv.x * ph.x + pv.y * ph.y) * camera.f * camera.f
            if f2 > 0, f2.squareRoot() > 0.4 * long, f2.squareRoot() < 3 * long {
                camera = Camera(f: f2.squareRoot(), cx: camera.cx, cy: camera.cy)
            }
        }
        // The vanishing directions in the (maybe updated) camera.
        let dv = vanishingDirection(uprights, camera: camera, minSupport: 0.15 * long)
        let dh = mode == "full" ? vanishingDirection(levels, camera: camera, minSupport: 0.15 * long) : nil

        func level() -> Homography {
            let flat = Straighten.autoAngle(segmentsOf(levels, width: width, height: height), width: width, height: height)
                ?? Straighten.autoAngle(segments, width: width, height: height) ?? 0
            return Homography.translation(width / 2, height / 2) * Homography.rotation(degrees: flat)
                * Homography.translation(-width / 2, -height / 2)
        }

        var turn: [Double]?
        switch mode {
        case "level":
            return level()
        case "vertical", "auto":
            if let dv { turn = rotation(taking: upward(dv), to: V3(0, 1, 0)) }
            if mode == "auto", let r = turn, angle(of: r) > 25 * Double.pi / 180 { turn = nil }
        case "full":
            if let dv, let dh {
                let r2 = upward(dv)
                var r1 = rightward(dh)
                r1 = (r1 - r2 * r1.dot(r2)).unit
                let r3 = r1.cross(r2)
                turn = [r1.x, r1.y, r1.z, r2.x, r2.y, r2.z, r3.x, r3.y, r3.z]
            } else if let dv {
                turn = rotation(taking: upward(dv), to: V3(0, 1, 0))
            } else if let dh {
                turn = rotation(taking: rightward(dh), to: V3(1, 0, 0))
            }
        default:
            return .identity
        }
        guard let r = turn, angle(of: r) < 45 * Double.pi / 180 else { return level() }
        let g = camera.transform(r)
        // Every corner must stay in front of the camera, or the picture would fold over.
        for corner in [Vec2(0, 0), Vec2(width, 0), Vec2(width, height), Vec2(0, height)] {
            let m = g.m
            if m[6] * corner.x + m[7] * corner.y + m[8] <= 0.05 { return level() }
        }
        return centred(g, width: width, height: height)
    }

    /// Guided upright: guides within 45° of upright should become upright, the others level. Two or
    /// more of a kind give a vanishing point, made to lie at infinity straight down (or sideways) by
    /// the smallest camera turn; a single guide of the other kind then sets the remaining turn (yaw or
    /// pitch); with no more than one guide of each kind the photo only turns about its middle.
    public static func guided(_ guides: [[MaskPoint]], width: Double, height: Double) -> Homography {
        let lines = guides.compactMap { g -> (Vec2, Vec2, Double)? in
            guard g.count >= 2 else { return nil }
            let a = Vec2(g[0].x * width, g[0].y * height), b = Vec2(g[g.count - 1].x * width, g[g.count - 1].y * height)
            return (b - a).length > 1 ? (a, b, (b - a).length) : nil
        }
        guard !lines.isEmpty else { return .identity }
        let camera = Camera(f: defaultFocal(width: width, height: height), cx: width / 2, cy: height / 2)
        let uprights = lines.filter { abs(angleFromUpright($0.0, $0.1)) <= 45 }
        let levels = lines.filter { abs(angleFromUpright($0.0, $0.1)) > 45 }
        func normal(_ l: (Vec2, Vec2, Double)) -> V3 { camera.ray(l.0).cross(camera.ray(l.1)).unit }
        func meeting(_ ls: [(Vec2, Vec2, Double)]) -> V3? {
            guard ls.count >= 2 else { return nil }
            var m = [Double](repeating: 0, count: 9)
            for l in ls {
                let n = normal(l), a = [n.x, n.y, n.z]
                for r in 0..<3 { for c in 0..<3 { m[r * 3 + c] += a[r] * a[c] } }
            }
            return smallestEigenvector(m)
        }
        let dv = meeting(uprights), dh = meeting(levels)
        var turn: [Double]?
        if let dv, let dh {
            let r2 = upward(dv)
            let r1 = (rightward(dh) - r2 * rightward(dh).dot(r2)).unit
            let r3 = r1.cross(r2)
            turn = [r1.x, r1.y, r1.z, r2.x, r2.y, r2.z, r3.x, r3.y, r3.z]
        } else if let dv {
            var r = rotation(taking: upward(dv), to: V3(0, 1, 0))
            if let one = levels.first {
                // Yaw (about the upright axis) until the level guide is level: its plane's normal has no x.
                let n = apply(r, normal(one))
                if abs(n.z) > 1e-9 {
                    let yaw = atan(-n.x / n.z)
                    r = multiply([cos(yaw), 0, sin(yaw), 0, 1, 0, -sin(yaw), 0, cos(yaw)], r)
                }
            }
            turn = r
        } else if let dh {
            var r = rotation(taking: rightward(dh), to: V3(1, 0, 0))
            if let one = uprights.first {
                // Pitch (about the level axis) until the upright guide is upright: its normal has no y.
                let n = apply(r, normal(one))
                if abs(n.z) > 1e-9 {
                    let pitch = atan(n.y / n.z)
                    r = multiply([1, 0, 0, 0, cos(pitch), -sin(pitch), 0, sin(pitch), cos(pitch)], r)
                }
            }
            turn = r
        }
        func roll() -> Homography {
            let angles = lines.map { Straighten.angle(levelling: $0.0, $0.1) }
            let mean = angles.reduce(0, +) / Double(angles.count)
            return Homography.translation(width / 2, height / 2) * Homography.rotation(degrees: mean)
                * Homography.translation(-width / 2, -height / 2)
        }
        guard let r = turn, angle(of: r) < 50 * Double.pi / 180 else { return roll() }
        let g = camera.transform(r)
        for corner in [Vec2(0, 0), Vec2(width, 0), Vec2(width, height), Vec2(0, height)] {
            if g.m[6] * corner.x + g.m[7] * corner.y + g.m[8] <= 0.05 { return roll() }
        }
        return centred(g, width: width, height: height)
    }

    static func apply(_ r: [Double], _ v: V3) -> V3 {
        V3(r[0] * v.x + r[1] * v.y + r[2] * v.z, r[3] * v.x + r[4] * v.y + r[5] * v.z, r[6] * v.x + r[7] * v.y + r[8] * v.z)
    }

    /// `a · b` for rotation matrices (rows): first b, then a.
    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        (Homography(a) * Homography(b)).m
    }

    /// `g` moved and scaled so the picture's middle stays in place at its own size.
    static func centred(_ g: Homography, width: Double, height: Double) -> Homography {
        let c = Vec2(width / 2, height / 2), e = 0.01 * Swift.max(width, height)
        let gc = g.apply(c)
        let jx = (g.apply(c + Vec2(e, 0)) - g.apply(c - Vec2(e, 0))) * (1 / (2 * e))
        let jy = (g.apply(c + Vec2(0, e)) - g.apply(c - Vec2(0, e))) * (1 / (2 * e))
        let det = abs(jx.x * jy.y - jx.y * jy.x)
        let s = det > 1e-12 ? 1 / det.squareRoot() : 1
        return Homography.translation(c.x, c.y) * Homography.scale(s, s) * Homography.translation(-gc.x, -gc.y) * g
    }

    /// Degrees from upright of a line (−90…90).
    static func angleFromUpright(_ a: Vec2, _ b: Vec2) -> Double {
        var angle = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
        while angle > 90 { angle -= 180 }
        while angle <= -90 { angle += 180 }
        return angle
    }

    static func segmentsOf(_ lines: [(Vec2, Vec2, Double)], width: Double, height: Double) -> [LineSegment] {
        lines.map { LineSegment(MaskPoint($0.0.x / width, $0.0.y / height), MaskPoint($0.1.x / width, $0.1.y / height), length: $0.2) }
    }

    /// The vanishing direction pointing down the picture (y > 0).
    static func upward(_ d: V3) -> V3 { (d.y < 0 ? d * -1 : d).unit }

    /// The vanishing direction pointing right (x > 0).
    static func rightward(_ d: V3) -> V3 { (d.x < 0 ? d * -1 : d).unit }

    /// The camera direction where most of these lines meet (their vanishing point; it may be at
    /// infinity when they are parallel), found by trying the meeting points of pairs of the longest
    /// lines and keeping the one most lines (by length) point at within 2°, then refined over those
    /// lines by least squares. Nil without at least two agreeing lines of `minSupport` total length.
    static func vanishingDirection(_ lines: [(Vec2, Vec2, Double)], camera: Camera, minSupport: Double) -> V3? {
        let longest = Array(lines.sorted { $0.2 > $1.2 }.prefix(40))
        guard longest.count >= 2 else { return nil }
        // Each line as the plane through the camera that holds it (its unit normal).
        let normals = longest.map { camera.ray($0.0).cross(camera.ray($0.1)).unit }
        func agrees(_ k: Int, _ v: V3) -> Bool {
            let (a, b, _) = longest[k]
            let m = (a + b) * 0.5
            // The vanishing point as a picture point (homogeneous), and the direction to it from the line's middle.
            let px = camera.f * v.x + camera.cx * v.z, py = camera.f * v.y + camera.cy * v.z
            let to = Vec2(px - m.x * v.z, py - m.y * v.z)
            let along = b - a
            let cross = abs(along.x * to.y - along.y * to.x), dot = abs(along.x * to.x + along.y * to.y)
            return atan2(cross, dot) < 2 * Double.pi / 180
        }
        var best: (support: Double, members: [Int])?
        for i in 0..<longest.count {
            for j in (i + 1)..<longest.count {
                let v = normals[i].cross(normals[j])
                guard v.length > 1e-9 else { continue }
                let members = longest.indices.filter { agrees($0, v.unit) }
                let support = members.reduce(0) { $0 + longest[$1].2 }
                if support > (best?.support ?? 0) { best = (support, members) }
            }
        }
        guard let best, best.members.count >= 2, best.support >= minSupport else { return nil }
        // Least squares: the direction most at right angles to all the members' plane normals.
        var m = [Double](repeating: 0, count: 9)
        for k in best.members {
            let n = normals[k], w = longest[k].2
            let a = [n.x, n.y, n.z]
            for r in 0..<3 { for c in 0..<3 { m[r * 3 + c] += w * a[r] * a[c] } }
        }
        return smallestEigenvector(m)
    }

    /// The unit eigenvector of a symmetric 3 × 3 matrix with the smallest eigenvalue (Jacobi rotations).
    static func smallestEigenvector(_ input: [Double]) -> V3 {
        var a = input
        var v: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for _ in 0..<50 {
            var off = 0.0
            for (p, q) in [(0, 1), (0, 2), (1, 2)] { off += a[p * 3 + q] * a[p * 3 + q] }
            if off < 1e-24 { break }
            for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                let apq = a[p * 3 + q]
                if abs(apq) < 1e-30 { continue }
                let theta = (a[q * 3 + q] - a[p * 3 + p]) / (2 * apq)
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<3 {
                    let akp = a[k * 3 + p], akq = a[k * 3 + q]
                    a[k * 3 + p] = c * akp - s * akq
                    a[k * 3 + q] = s * akp + c * akq
                }
                for k in 0..<3 {
                    let apk = a[p * 3 + k], aqk = a[q * 3 + k]
                    a[p * 3 + k] = c * apk - s * aqk
                    a[q * 3 + k] = s * apk + c * aqk
                }
                for k in 0..<3 {
                    let vkp = v[k * 3 + p], vkq = v[k * 3 + q]
                    v[k * 3 + p] = c * vkp - s * vkq
                    v[k * 3 + q] = s * vkp + c * vkq
                }
            }
        }
        let i = [0, 1, 2].min { a[$0 * 3 + $0] < a[$1 * 3 + $1] }!
        return V3(v[i], v[3 + i], v[6 + i]).unit
    }

    /// The smallest camera turn (rows of a rotation matrix) taking unit direction `a` to `b`.
    static func rotation(taking a: V3, to b: V3) -> [Double] {
        let axis = a.cross(b), s = axis.length, c = a.dot(b)
        guard s > 1e-12 else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        let k = axis * (1 / s)
        let t = 1 - c
        return [t * k.x * k.x + c, t * k.x * k.y - s * k.z, t * k.x * k.z + s * k.y,
                t * k.x * k.y + s * k.z, t * k.y * k.y + c, t * k.y * k.z - s * k.x,
                t * k.x * k.z - s * k.y, t * k.y * k.z + s * k.x, t * k.z * k.z + c]
    }

    /// How far a rotation turns (radians).
    static func angle(of r: [Double]) -> Double {
        acos(Swift.min(1, Swift.max(-1, (r[0] + r[4] + r[8] - 1) / 2)))
    }
}
