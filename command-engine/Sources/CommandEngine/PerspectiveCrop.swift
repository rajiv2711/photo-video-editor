import Foundation

/// Perspective crop (as in Photoshop): four corners placed on a tilted plane in the photo (a page, a
/// painting, a façade) are mapped to a rectangle, which becomes the frame. The rectangle's sides are
/// the averages of the opposite sides of the four-cornered shape. The corners can be found from the
/// photo's straight lines: the largest four-sided shape whose sides lie along long lines.
public enum PerspectiveCrop {
    /// The transform taking the corners (normalized on a `width` × `height` photo: top-left, top-right,
    /// bottom-right, bottom-left) to an upright rectangle at the origin, and that rectangle's size; nil
    /// when the corners don't make a convex four-sided shape.
    public static func rectify(_ quad: [MaskPoint], width: Double, height: Double) -> (transform: Homography, width: Double, height: Double)? {
        guard quad.count == 4 else { return nil }
        let q = quad.map { Vec2($0.x * width, $0.y * height) }
        guard isConvex(q) else { return nil }
        let w = ((q[1] - q[0]).length + (q[2] - q[3]).length) / 2
        let h = ((q[3] - q[0]).length + (q[2] - q[1]).length) / 2
        guard w > 4, h > 4, let t = Homography.mapping(q, to: [Vec2(0, 0), Vec2(w, 0), Vec2(w, h), Vec2(0, h)]) else { return nil }
        return (t, w, h)
    }

    /// Whether four points in order make a convex shape turning clockwise on screen (top-left,
    /// top-right, bottom-right, bottom-left), with no side too short.
    public static func isConvex(_ q: [Vec2]) -> Bool {
        guard q.count == 4 else { return false }
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross <= 1e-9 || (b - a).length < 1e-6 { return false }
        }
        return true
    }

    /// The corners after dragging the one nearest to `start` (within `reach`, normalized) to `end`;
    /// unchanged when no corner is near.
    public static func drag(_ quad: [MaskPoint], from start: MaskPoint, to end: MaskPoint, reach: Double = 0.08) -> [MaskPoint] {
        guard quad.count == 4 else { return quad }
        let distances = quad.map { hypot($0.x - start.x, $0.y - start.y) }
        guard let i = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[i] <= reach else { return quad }
        var out = quad
        out[i] = MaskPoint(Swift.min(1, Swift.max(0, quad[i].x + end.x - start.x)), Swift.min(1, Swift.max(0, quad[i].y + end.y - start.y)))
        return out
    }

    /// A starting shape when none is found: the middle 70 % of the photo.
    public static let inset: [MaskPoint] = [MaskPoint(0.15, 0.15), MaskPoint(0.85, 0.15), MaskPoint(0.85, 0.85), MaskPoint(0.15, 0.85)]

    /// The largest convex four-sided shape whose sides lie along long lines of the photo (each side
    /// at least half covered by its line; pieces along one line count together), as normalized
    /// corners; nil when the lines don't make one.
    public static func detect(_ segments: [LineSegment], width: Double, height: Double) -> [MaskPoint]? {
        let long = Swift.max(width, height)
        // Each line: its ends (spanning its pieces) and how much of that span its pieces cover.
        typealias Line = (Vec2, Vec2, Double)
        let lines: [Line] = LineDetector.merged(segments, width: width, height: height).compactMap { s in
            let (a, b) = s.ends(width: width, height: height)
            let span = (b - a).length
            return s.length >= 0.1 * long && span > 0 ? (a, b, Swift.min(1, s.length / span)) : nil
        }
        let across = Array(lines.filter { abs(Straighten.deviation($0.0, $0.1)) <= 45 && abs(Upright.angleFromUpright($0.0, $0.1)) > 45 }
            .sorted { ($0.1 - $0.0).length * $0.2 > ($1.1 - $1.0).length * $1.2 }.prefix(14))
        let down = Array(lines.filter { abs(Upright.angleFromUpright($0.0, $0.1)) <= 45 }
            .sorted { ($0.1 - $0.0).length * $0.2 > ($1.1 - $1.0).length * $1.2 }.prefix(14))
        guard across.count >= 2, down.count >= 2 else { return nil }

        func meet(_ l: Line, _ m: Line) -> Vec2? {
            let d1 = l.1 - l.0, d2 = m.1 - m.0
            let den = d1.x * d2.y - d1.y * d2.x
            guard abs(den) > 1e-9 else { return nil }
            let t = ((m.0.x - l.0.x) * d2.y - (m.0.y - l.0.y) * d2.x) / den
            return l.0 + d1 * t
        }
        /// How much of the side a→b the line covers (0…1).
        func covered(_ a: Vec2, _ b: Vec2, by l: Line) -> Double {
            let d = b - a, len2 = d.x * d.x + d.y * d.y
            guard len2 > 0 else { return 0 }
            let t0 = ((l.0 - a).x * d.x + (l.0 - a).y * d.y) / len2, t1 = ((l.1 - a).x * d.x + (l.1 - a).y * d.y) / len2
            return Swift.max(0, Swift.min(1, Swift.max(t0, t1)) - Swift.max(0, Swift.min(t0, t1))) * l.2
        }
        var best: (area: Double, corners: [Vec2])?
        for i in 0..<across.count {
            for j in (i + 1)..<across.count {
                // Top is the one higher up in the middle.
                let midI = (across[i].0.y + across[i].1.y) / 2, midJ = (across[j].0.y + across[j].1.y) / 2
                let top = midI < midJ ? across[i] : across[j], bottom = midI < midJ ? across[j] : across[i]
                for k in 0..<down.count {
                    for m in (k + 1)..<down.count {
                        let midK = (down[k].0.x + down[k].1.x) / 2, midM = (down[m].0.x + down[m].1.x) / 2
                        let left = midK < midM ? down[k] : down[m], right = midK < midM ? down[m] : down[k]
                        guard let tl = meet(top, left), let tr = meet(top, right), let br = meet(bottom, right), let bl = meet(bottom, left) else {
                            continue
                        }
                        let corners = [tl, tr, br, bl]
                        guard isConvex(corners),
                              corners.allSatisfy({ $0.x >= -0.02 * width && $0.x <= 1.02 * width && $0.y >= -0.02 * height && $0.y <= 1.02 * height })
                        else { continue }
                        guard covered(tl, tr, by: top) >= 0.5, covered(bl, br, by: bottom) >= 0.5,
                              covered(tl, bl, by: left) >= 0.5, covered(tr, br, by: right) >= 0.5 else { continue }
                        let area = abs((tr.x - bl.x) * (br.y - tl.y) - (br.x - tl.x) * (tr.y - bl.y)) / 2
                        if area > (best?.area ?? 0.04 * width * height) { best = (area, corners) }
                    }
                }
            }
        }
        return best?.corners.map { MaskPoint(Swift.min(1, Swift.max(0, $0.x / width)), Swift.min(1, Swift.max(0, $0.y / height))) }
    }
}
