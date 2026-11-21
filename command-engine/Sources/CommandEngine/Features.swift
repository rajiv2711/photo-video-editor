import Foundation

/// Matching points between two photos of the same scene, the classical way (no learning):
/// Harris corners (Harris & Stephens 1988), each described by a small normalized patch of the blurred
/// picture around it (like the MOPS descriptors of Brown, Szeliski & Winder 2005, without rotation),
/// matched by nearest neighbour with Lowe's ratio test, both ways; then the homography that most
/// matches agree with, by RANSAC (Fischler & Bolles 1981), refined by least squares on its inliers.
public enum Features {
    /// A corner: where (pixels from the top-left) and how strong.
    public struct Corner: Equatable {
        public var x: Double
        public var y: Double
        public var score: Float
    }

    /// Patches are `side` × `side` samples, `spacing` pixels apart (on the picture blurred by about that much).
    static let side = 8
    static let spacing = 2

    /// The strongest Harris corners of a grey picture, at least 4 pixels apart and spread over a 6 × 6
    /// grid of cells (so a busy corner of the photo can't take them all), at most `count`.
    public static func corners(_ g: FloatImage, count: Int = 600) -> [Corner] {
        let w = g.width, h = g.height
        guard w > 24, h > 24 else { return [] }
        let smooth = Grid.blur(g.data, width: w, height: h, radius: 1)
        var ixx = [Float](repeating: 0, count: w * h), iyy = ixx, ixy = ixx
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = (smooth[i - w + 1] + 2 * smooth[i + 1] + smooth[i + w + 1]) - (smooth[i - w - 1] + 2 * smooth[i - 1] + smooth[i + w - 1])
                let gy = (smooth[i + w - 1] + 2 * smooth[i + w] + smooth[i + w + 1]) - (smooth[i - w - 1] + 2 * smooth[i - w] + smooth[i - w + 1])
                ixx[i] = gx * gx
                iyy[i] = gy * gy
                ixy[i] = gx * gy
            }
        }
        ixx = Grid.blur(ixx, width: w, height: h, radius: 1)
        iyy = Grid.blur(iyy, width: w, height: h, radius: 1)
        ixy = Grid.blur(ixy, width: w, height: h, radius: 1)
        var response = [Float](repeating: 0, count: w * h)
        var top: Float = 0
        for i in 0..<(w * h) {
            let r = ixx[i] * iyy[i] - ixy[i] * ixy[i] - 0.05 * (ixx[i] + iyy[i]) * (ixx[i] + iyy[i])
            response[i] = r
            top = max(top, r)
        }
        guard top > 0 else { return [] }
        // Local maxima within 4 pixels, away from the border (patches must fit), above 0.5 % of the strongest.
        let margin = side / 2 * spacing + 2
        let peaks = Grid.dilate(response, width: w, height: h, radius: 4)
        var found: [Corner] = []
        for y in margin..<max(margin, h - margin) {
            for x in margin..<max(margin, w - margin) {
                let r = response[y * w + x]
                if r > 0.005 * top, r >= peaks[y * w + x] { found.append(Corner(x: Double(x), y: Double(y), score: r)) }
            }
        }
        // Spread: the best few of each cell first, then the strongest of the rest.
        let cells = 6
        var byCell = [[Corner]](repeating: [], count: cells * cells)
        for c in found {
            let cx = min(cells - 1, Int(c.x) * cells / w), cy = min(cells - 1, Int(c.y) * cells / h)
            byCell[cy * cells + cx].append(c)
        }
        let share = max(1, count / (cells * cells))
        var chosen: [Corner] = [], rest: [Corner] = []
        for list in byCell {
            let sorted = list.sorted { $0.score > $1.score }
            chosen += sorted.prefix(share)
            rest += sorted.dropFirst(share)
        }
        chosen += rest.sorted { $0.score > $1.score }.prefix(max(0, count - chosen.count))
        return chosen
    }

    /// One descriptor per corner: the blurred picture's samples around it, minus their mean, scaled to
    /// length 1 (so brightness and contrast changes between photos don't matter). Flat patches get none.
    public static func describe(_ g: FloatImage, _ corners: [Corner]) -> [[Float]?] {
        let w = g.width, h = g.height
        let blurred = Grid.blur(g.data, width: w, height: h, radius: spacing / 2 + 1)
        return corners.map { c in
            var v = [Float](repeating: 0, count: side * side)
            var mean: Float = 0
            for j in 0..<side {
                for i in 0..<side {
                    let x = min(w - 1, max(0, Int(c.x) + (i - side / 2) * spacing + spacing / 2))
                    let y = min(h - 1, max(0, Int(c.y) + (j - side / 2) * spacing + spacing / 2))
                    v[j * side + i] = blurred[y * w + x]
                    mean += v[j * side + i]
                }
            }
            mean /= Float(side * side)
            var norm: Float = 0
            for k in v.indices {
                v[k] -= mean
                norm += v[k] * v[k]
            }
            norm = sqrtf(norm)
            guard norm > 1e-3 else { return nil }
            return v.map { $0 / norm }
        }
    }

    /// Pairs (index in `a`, index in `b`) that are each other's nearest and clearly nearer than the
    /// next best (distance ratio under `ratio`).
    public static func match(_ a: [[Float]?], _ b: [[Float]?], ratio: Float = 0.8) -> [(Int, Int)] {
        func nearest(_ from: [[Float]?], _ to: [[Float]?]) -> [(index: Int, ok: Bool)?] {
            from.map { d -> (index: Int, ok: Bool)? in
                guard let d else { return nil }
                var best = Float.infinity, second = Float.infinity, index = -1
                for (j, e) in to.enumerated() {
                    guard let e else { continue }
                    var dot: Float = 0
                    for k in 0..<d.count { dot += d[k] * e[k] }
                    let distance = max(0, 2 - 2 * dot)  // squared distance of unit vectors
                    if distance < best {
                        second = best
                        best = distance
                        index = j
                    } else if distance < second {
                        second = distance
                    }
                }
                guard index >= 0 else { return nil }
                return (index, best < ratio * ratio * second)
            }
        }
        let ab = nearest(a, b), ba = nearest(b, a)
        var out: [(Int, Int)] = []
        for (i, m) in ab.enumerated() {
            guard let m, m.ok, let back = ba[m.index], back.index == i else { continue }
            out.append((i, m.index))
        }
        return out
    }

    /// The homography taking `from` points (on a picture of `size`) to `to` points that the most pairs
    /// agree with (within `threshold` pixels), and those pairs; nil when fewer than `minimum` agree.
    public static func homography(from: [Vec2], to: [Vec2], size: (width: Double, height: Double), threshold: Double, minimum: Int = 12,
                                  iterations: Int = 500, seed: UInt64 = 0x2545_F491_4F6C_DD1D) -> (h: Homography, inliers: [Int])? {
        let n = from.count
        guard n >= 4, to.count == n else { return nil }
        var random = seed
        func next(_ bound: Int) -> Int {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((random >> 33) % UInt64(bound))
        }
        func inliers(_ h: Homography) -> [Int] {
            (0..<n).filter { k in (h.apply(from[k]) - to[k]).length < threshold }
        }
        var best: [Int] = []
        for _ in 0..<iterations {
            var pick: [Int] = []
            while pick.count < 4 {
                let k = next(n)
                if !pick.contains(k) { pick.append(k) }
            }
            guard let h = Homography.mapping(pick.map { from[$0] }, to: pick.map { to[$0] }), plausible(h, size: size) else { continue }
            let found = inliers(h)
            if found.count > best.count { best = found }
        }
        guard best.count >= minimum else { return nil }
        // Refine on all inliers, then once more on the inliers of the refined one.
        var h = fit(best.map { from[$0] }, best.map { to[$0] }) ?? Homography.identity
        for _ in 0..<2 {
            let found = inliers(h)
            guard found.count >= minimum, let better = fit(found.map { from[$0] }, found.map { to[$0] }), plausible(better, size: size) else { break }
            h = better
            best = found
        }
        return (h.normalized, inliers(h))
    }

    /// The picture's corners stay in front, in order (a convex shape, not folded) and the picture
    /// keeps between a tenth and ten times its area: a guard against chance fits of four points.
    static func plausible(_ h: Homography, size: (width: Double, height: Double)) -> Bool {
        let w = size.width, hh = size.height
        let corners = [Vec2(0, 0), Vec2(w, 0), Vec2(w, hh), Vec2(0, hh)]
        let m = h.m
        for c in corners where m[6] * c.x + m[7] * c.y + m[8] <= 0 { return false }
        let q = corners.map { h.apply($0) }
        var sign = 0.0, area = 0.0
        for k in 0..<4 {
            let a = q[k], b = q[(k + 1) % 4], c = q[(k + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if sign == 0 { sign = cross } else if cross * sign <= 0 { return false }
            area += a.x * b.y - b.x * a.y
        }
        let ratio = abs(area / 2) / max(w * hh, 1e-9)
        return ratio > 0.1 && ratio < 10
    }

    /// Least-squares homography through many pairs (Hartley-normalized direct linear transform).
    public static func fit(_ from: [Vec2], _ to: [Vec2]) -> Homography? {
        guard from.count >= 4 else { return nil }
        func normalizer(_ p: [Vec2]) -> Homography {
            let cx = p.map(\.x).reduce(0, +) / Double(p.count), cy = p.map(\.y).reduce(0, +) / Double(p.count)
            let d = p.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / Double(p.count)
            let s = d > 1e-9 ? 2.0.squareRoot() / d : 1
            return Homography([s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1])
        }
        let na = normalizer(from), nb = normalizer(to)
        let a = from.map { na.apply($0) }, b = to.map { nb.apply($0) }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for (p, q) in zip(a, b) {
            let rows: [[Double]] = [[p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y, q.x],
                                    [0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y, q.y]]
            for row in rows {
                for r in 0..<8 {
                    for c in 0..<9 { ata[r][c] += row[r] * row[c] }
                }
            }
        }
        guard let h = Homography.solve(ata) else { return nil }
        return (nb.inverse * Homography(h + [1]) * na).normalized
    }
}
