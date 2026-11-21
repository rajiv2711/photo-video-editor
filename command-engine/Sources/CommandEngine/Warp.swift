import Foundation

/// Warp and puppet warp: handles on the (cropped) picture are dragged, and the picture bends with them
/// as rigidly as it can, by moving least squares (Schaefer, McPhail & Warren 2006, the rigid kind):
/// around each point the handles are weighted by nearness, and the point follows the best rotation
/// and shift that carries the nearby handles to where they were dragged. Warp starts with a 4 × 4
/// grid of handles (the outer ones hold the edges); puppet warp adds pins where the photo is tapped.
///
/// The picture is drawn backwards (each output point reads from somewhere), so the map is worked out
/// with the roles swapped: from where the handles are now to where they started. It is exact at the
/// handles and smooth between them.
public enum Warp {
    /// The resting grid: 4 × 4 handles over the picture, corners and edges included.
    public static var lattice: [WarpPin] {
        var out: [WarpPin] = []
        for j in 0..<4 {
            for i in 0..<4 {
                let p = MaskPoint(Double(i) / 3, Double(j) / 3)
                out.append(WarpPin(anchor: p, position: p))
            }
        }
        return out
    }

    /// Whether any handle was moved.
    public static func moved(_ pins: [WarpPin]) -> Bool {
        pins.contains { abs($0.anchor.x - $0.position.x) > 1e-9 || abs($0.anchor.y - $0.position.y) > 1e-9 }
    }

    /// Rigid moving least squares: where `v` goes when handles at `p` move to `q` (pixels).
    public static func rigid(_ v: Vec2, from p: [Vec2], to q: [Vec2]) -> Vec2 {
        guard !p.isEmpty, p.count == q.count else { return v }
        var weights: [Double] = []
        for (i, pi) in p.enumerated() {
            let d2 = (pi.x - v.x) * (pi.x - v.x) + (pi.y - v.y) * (pi.y - v.y)
            if d2 < 1e-12 { return q[i] }
            weights.append(1 / d2)
        }
        let total = weights.reduce(0, +)
        var ps = Vec2(0, 0), qs = Vec2(0, 0)
        for i in p.indices {
            ps = ps + p[i] * weights[i]
            qs = qs + q[i] * weights[i]
        }
        ps = ps * (1 / total)
        qs = qs * (1 / total)
        let d = v - ps
        var f = Vec2(0, 0)
        for i in p.indices {
            let ph = p[i] - ps, qh = q[i] - qs, w = weights[i]
            // A = w · [p̂; −p̂⊥] · [d, −d⊥], with (x, y)⊥ = (−y, x); f += q̂ · A.
            let pPerp = Vec2(-ph.y, ph.x), dPerp = Vec2(-d.y, d.x)
            let m00 = ph.x * d.x + ph.y * d.y, m01 = -(ph.x * dPerp.x + ph.y * dPerp.y)
            let m10 = -(pPerp.x * d.x + pPerp.y * d.y), m11 = pPerp.x * dPerp.x + pPerp.y * dPerp.y
            f = f + Vec2(qh.x * m00 + qh.y * m10, qh.x * m01 + qh.y * m11) * w
        }
        let length = f.length
        guard length > 1e-12 else { return qs + d }
        return qs + f * (d.length / length)
    }

    /// The map (each point of the warped picture → where it reads on the picture before warping,
    /// normalized) for handles on a `width` × `height` picture, on a grid of about `cells` along the long
    /// side; nil when no handle moved.
    public static func map(_ pins: [WarpPin], width: Double, height: Double, cells: Int = 64) -> WarpMap? {
        guard moved(pins), width > 0, height > 0 else { return nil }
        let s = Double(cells) / Swift.max(width, height)
        let gw = Swift.max(4, Int((width * s).rounded())), gh = Swift.max(4, Int((height * s).rounded()))
        let now = pins.map { Vec2($0.position.x * width, $0.position.y * height) }
        let before = pins.map { Vec2($0.anchor.x * width, $0.anchor.y * height) }
        var positions = [Float](repeating: 0, count: gw * gh * 2)
        for y in 0..<gh {
            for x in 0..<gw {
                let v = Vec2((Double(x) + 0.5) / Double(gw) * width, (Double(y) + 0.5) / Double(gh) * height)
                let from = rigid(v, from: now, to: before)
                positions[(y * gw + x) * 2] = Float(from.x / width)
                positions[(y * gw + x) * 2 + 1] = Float(from.y / height)
            }
        }
        return WarpMap(width: gw, height: gh, positions: positions)
    }

    /// The handle nearest to `start` (by where it is now, within `reach`, normalized on a `width` ×
    /// `height` picture), if any.
    public static func nearest(_ pins: [WarpPin], to start: MaskPoint, width: Double, height: Double, reach: Double = 0.06) -> Int? {
        let long = Swift.max(width, height)
        let d = pins.map { hypot(($0.position.x - start.x) * width, ($0.position.y - start.y) * height) / long }
        guard let i = d.indices.min(by: { d[$0] < d[$1] }), d[i] <= reach else { return nil }
        return i
    }
}
