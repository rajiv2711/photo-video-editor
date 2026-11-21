import Foundation

/// A straight line segment found on a picture, normalized (0…1 of the width and height from the
/// top-left), with its length in pixels of the picture it was found on.
public struct LineSegment: Hashable {
    public var a: MaskPoint
    public var b: MaskPoint
    public var length: Double

    public init(_ a: MaskPoint, _ b: MaskPoint, length: Double) {
        self.a = a
        self.b = b
        self.length = length
    }

    /// The ends in pixels of a `width` × `height` picture.
    public func ends(width: Double, height: Double) -> (Vec2, Vec2) {
        (Vec2(a.x * width, a.y * height), Vec2(b.x * width, b.y * height))
    }
}

/// Finds straight edges on a picture, the classical way (no learning): Sobel gradients, thin edges
/// (non-maximum suppression), then neighbouring edge pixels whose edge direction agrees are grown into
/// regions and each long, thin region is fitted with a line (as the LSD line segment detector does).
/// Upright and Auto Straighten read their angles from these lines.
public enum LineDetector {
    /// Segments on a grey picture (`pixels`: brightness 0…1, row by row from the top). Segments shorter
    /// than `minLength` (share of the long side) are left out.
    public static func detect(_ pixels: [Float], width: Int, height: Int, minLength: Double = 0.04) -> [LineSegment] {
        guard width > 8, height > 8, pixels.count >= width * height else { return [] }
        let n = width * height
        // A light blur (1-2-1 both ways) so noise and JPEG blocks don't make edges.
        var smooth = [Float](repeating: 0, count: n)
        var tmp = [Float](repeating: 0, count: n)
        for y in 0..<height {
            for x in 0..<width {
                let l = pixels[y * width + Swift.max(x - 1, 0)], c = pixels[y * width + x], r = pixels[y * width + Swift.min(x + 1, width - 1)]
                tmp[y * width + x] = (l + 2 * c + r) / 4
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let u = tmp[Swift.max(y - 1, 0) * width + x], c = tmp[y * width + x], d = tmp[Swift.min(y + 1, height - 1) * width + x]
                smooth[y * width + x] = (u + 2 * c + d) / 4
            }
        }
        // Sobel gradients.
        var gx = [Float](repeating: 0, count: n), gy = [Float](repeating: 0, count: n), mag = [Float](repeating: 0, count: n)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                func p(_ dx: Int, _ dy: Int) -> Float { smooth[(y + dy) * width + x + dx] }
                let sx = (p(1, -1) + 2 * p(1, 0) + p(1, 1)) - (p(-1, -1) + 2 * p(-1, 0) + p(-1, 1))
                let sy = (p(-1, 1) + 2 * p(0, 1) + p(1, 1)) - (p(-1, -1) + 2 * p(0, -1) + p(1, -1))
                let i = y * width + x
                gx[i] = sx
                gy[i] = sy
                mag[i] = (sx * sx + sy * sy).squareRoot()
            }
        }
        // Edge pixels: strong enough (a step of about 4 % brightness) and the strongest across the edge.
        let threshold: Float = 0.16
        var edge = [Bool](repeating: false, count: n)
        var seeds: [Int] = []
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let i = y * width + x
                let m = mag[i]
                guard m >= threshold else { continue }
                // Neighbours along the gradient, its direction rounded to 45°.
                let angle = atan2(gy[i], gx[i])
                let octant = Int(((angle + .pi) / (.pi / 4)).rounded()) % 4
                let step = [(1, 0), (1, 1), (0, 1), (-1, 1)][octant]
                let a = mag[(y + step.1) * width + x + step.0], b = mag[(y - step.1) * width + x - step.0]
                if m >= a && m > b {
                    edge[i] = true
                    seeds.append(i)
                }
            }
        }
        seeds.sort { mag[$0] > mag[$1] }
        // The edge's own direction (along it), 0…π.
        func direction(_ i: Int) -> Float {
            var d = atan2(gx[i], -gy[i])
            if d < 0 { d += .pi }
            if d >= .pi { d -= .pi }
            return d
        }
        let tolerance: Float = .pi / 8
        var used = [Bool](repeating: false, count: n)
        var out: [LineSegment] = []
        let longSide = Double(Swift.max(width, height))
        let shortest = Swift.max(8, minLength * longSide)
        for seed in seeds where !used[seed] {
            // Grow a region of connected edge pixels pointing the same way (doubled angles average
            // directions that wrap around at π).
            var region = [seed]
            used[seed] = true
            var c2 = cos(2 * direction(seed)), s2 = sin(2 * direction(seed))
            var k = 0
            while k < region.count {
                let i = region[k]
                k += 1
                let x = i % width, y = i / width
                let mean = atan2(s2, c2) / 2
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let j = ny * width + nx
                        guard edge[j], !used[j] else { continue }
                        var diff = abs(direction(j) - mean)
                        diff = Swift.min(diff, abs(diff - .pi), abs(diff + .pi))
                        guard diff <= tolerance else { continue }
                        used[j] = true
                        region.append(j)
                        c2 += cos(2 * direction(j))
                        s2 += sin(2 * direction(j))
                    }
                }
            }
            guard Double(region.count) >= shortest * 0.7 else { continue }
            if let segment = fit(region, width: width, height: height, weights: mag), segment.length >= shortest {
                out.append(segment)
            }
        }
        return out.sorted { $0.length > $1.length }
    }

    /// Pieces lying along the same straight line (within `degrees` of each other and `reach` × the
    /// long side of it) joined into one segment spanning them all; its `length` is the pieces' total,
    /// so gaps don't count. A long edge broken at every corner it meets (a page's border along its
    /// patches) becomes one line again.
    public static func merged(_ segments: [LineSegment], width: Double, height: Double, degrees: Double = 1.5,
                              reach: Double = 0.004) -> [LineSegment] {
        let near = reach * Swift.max(width, height)
        var groups: [(a: Vec2, b: Vec2, support: Double)] = []
        for s in segments.sorted(by: { $0.length > $1.length }) {
            let (p, q) = s.ends(width: width, height: height)
            var joined = false
            for i in groups.indices {
                let g = groups[i]
                let d = g.b - g.a, len = d.length
                guard len > 0 else { continue }
                let u = d * (1 / len)
                // Same direction, and both ends close to the group's line.
                let cross = abs(u.x * (q - p).y - u.y * (q - p).x) / Swift.max((q - p).length, 1e-9)
                guard asin(Swift.min(1, cross)) <= degrees * .pi / 180 else { continue }
                func off(_ v: Vec2) -> Double { abs(u.x * (v - g.a).y - u.y * (v - g.a).x) }
                guard off(p) <= near, off(q) <= near else { continue }
                // Grow the span along the group's direction.
                func t(_ v: Vec2) -> Double { (v - g.a).x * u.x + (v - g.a).y * u.y }
                let lo = Swift.min(0, t(p), t(q)), hi = Swift.max(len, t(p), t(q))
                groups[i] = (g.a + u * lo, g.a + u * hi, g.support + s.length)
                joined = true
                break
            }
            if !joined { groups.append((p, q, s.length)) }
        }
        return groups.map {
            LineSegment(MaskPoint($0.a.x / width, $0.a.y / height), MaskPoint($0.b.x / width, $0.b.y / height), length: $0.support)
        }.sorted { $0.length > $1.length }
    }

    /// A line through a region of pixels (principal axis, weighted by edge strength): nil when the
    /// region is not long and thin, or has gaps.
    static func fit(_ region: [Int], width: Int, height: Int, weights: [Float]) -> LineSegment? {
        var sw = 0.0, sx = 0.0, sy = 0.0
        for i in region {
            let w = Double(weights[i])
            sw += w
            sx += w * Double(i % width)
            sy += w * Double(i / width)
        }
        guard sw > 0 else { return nil }
        let mx = sx / sw, my = sy / sw
        var cxx = 0.0, cxy = 0.0, cyy = 0.0
        for i in region {
            let w = Double(weights[i]), dx = Double(i % width) - mx, dy = Double(i / width) - my
            cxx += w * dx * dx
            cxy += w * dx * dy
            cyy += w * dy * dy
        }
        cxx /= sw
        cxy /= sw
        cyy /= sw
        // Eigenvalues of the 2 × 2 spread: along (large) and across (small) the line.
        let tr = cxx + cyy, det = cxx * cyy - cxy * cxy
        let gap = ((tr * tr / 4 - det).squareRoot())
        let along = tr / 2 + gap, across = Swift.max(0, tr / 2 - gap)
        guard along > 0, across / along < 0.02 else { return nil }
        let angle = 0.5 * atan2(2 * cxy, cxx - cyy)
        let ux = cos(angle), uy = sin(angle)
        var lo = Double.infinity, hi = -Double.infinity
        for i in region {
            let t = (Double(i % width) - mx) * ux + (Double(i / width) - my) * uy
            lo = Swift.min(lo, t)
            hi = Swift.max(hi, t)
        }
        let length = hi - lo
        // Mostly unbroken: at least 60 % of its length covered.
        guard length > 0, Double(region.count) >= 0.6 * length else { return nil }
        let w = Double(width), h = Double(height)
        return LineSegment(MaskPoint((mx + lo * ux + 0.5) / w, (my + lo * uy + 0.5) / h),
                           MaskPoint((mx + hi * ux + 0.5) / w, (my + hi * uy + 0.5) / h), length: length)
    }
}

/// Straighten: angles that level a photo.
public enum Straighten {
    /// How far a line is from the nearest of level or upright, degrees in −45…45: positive when it is
    /// turned clockwise on screen (y down).
    public static func deviation(_ a: Vec2, _ b: Vec2) -> Double {
        var angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        while angle > 45 { angle -= 90 }
        while angle <= -45 { angle += 90 }
        return angle
    }

    /// The Straighten angle that levels this line (drawn on the photo as `transform` shows it before
    /// straightening): the line turns level, or upright if it is nearer to that.
    public static func angle(levelling a: Vec2, _ b: Vec2) -> Double {
        Swift.min(45, Swift.max(-45, -deviation(a, b)))
    }

    /// Auto Straighten: the angle that levels the photo's lines (those within 15° of level or upright,
    /// longer ones counting more; the weighted median, so a few slanted lines don't pull it), after
    /// `transform` (upright and the manual transform). Nil when the photo has no such lines.
    public static func autoAngle(_ segments: [LineSegment], width: Double, height: Double, transform: Homography = .identity) -> Double? {
        var items: [(dev: Double, weight: Double)] = []
        for s in segments {
            let (p, q) = s.ends(width: width, height: height)
            let a = transform.apply(p), b = transform.apply(q)
            let length = (b - a).length
            let dev = deviation(a, b)
            if abs(dev) <= 15, length > 0 { items.append((dev, length * length)) }
        }
        let total = items.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        items.sort { $0.dev < $1.dev }
        var sum = 0.0
        for item in items {
            sum += item.weight
            if sum >= total / 2 { return Swift.min(45, Swift.max(-45, -item.dev)) }
        }
        return nil
    }
}
