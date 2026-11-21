import Foundation

/// Panorama merge without learning, as Brown & Lowe's AutoStitch (2007):
/// 1. Every pair of photos is matched (Features: corners, patches, RANSAC homography); the pairs that
///    agree best join the photos into a tree around the best-connected one, the reference.
/// 2. The focal length comes from the homographies (as OpenCV estimates it), else from the lens, else a
///    typical phone's.
/// 3. Projection: Perspective keeps straight lines straight (the reference's plane, for narrow
///    panoramas); Cylindrical unrolls the view around an upright axis; Spherical also bends the
///    vertical, for wide and tall views.
/// 4. Exposure: one gain per photo makes their overlaps agree (least squares, as Brown & Lowe).
/// 5. Each output pixel takes the photo it is most central in; the seams are hidden by multi-band
///    blending (low frequencies mixed widely, fine detail near the seam only).
/// 6. Boundary Warp stretches the ragged edge out to the frame (columns, then rows); Fill Edges makes up
///    what is still empty with content-aware fill (Inpaint).
public enum Panorama {
    public enum Projection: String {
        case spherical, cylindrical, perspective
    }

    /// "panoramaProjection" option ids, in order; must match controls.json.
    public static let projections = ["spherical", "cylindrical", "perspective"]

    public struct Settings: Equatable {
        public var projection: Projection
        /// 0…1: how far the edge is stretched out to the frame.
        public var boundaryWarp: Double
        public var fillEdges: Bool

        public init(projection: Projection = .spherical, boundaryWarp: Double = 0, fillEdges: Bool = false) {
            self.projection = projection
            self.boundaryWarp = boundaryWarp
            self.fillEdges = fillEdges
        }
    }

    /// A stitched panorama: RGB on sRGB levels, and where a photo shows (1) or nothing does (0; the
    /// app shows those parts white).
    public struct Result {
        public var image: FloatImage
        public var coverage: [Float]
        /// How many of the photos were joined in.
        public var used: Int
    }

    /// How photos fit together: each one's homography into the reference photo (nil: matched none).
    public struct Registration {
        public var reference: Int
        public var transforms: [Homography?]
        /// The joined pairs (parent, child) and how many matches each had.
        public var links: [(parent: Int, child: Int, inliers: Int)]
    }

    /// Long side of the grey copies matched.
    static let registrationSide = 800.0

    /// Joins photos (sRGB levels; any sizes) into one. `focal`: the focal length in pixels of the
    /// photos as given, if known. Nil when fewer than two photos fit together.
    public static func stitch(_ photos: [FloatImage], settings: Settings, focal: Double? = nil, maxSide: Int = 8000) -> Result? {
        guard photos.count >= 2 else { return nil }
        let registration = register(photos)
        let used = registration.transforms.indices.filter { registration.transforms[$0] != nil }
        guard used.count >= 2 else { return nil }
        let ref = registration.reference
        let refPhoto = photos[ref]
        let guess = 0.75 * Double(max(refPhoto.width, refPhoto.height))
        let f = estimateFocal(registration, photos: photos) ?? focal ?? guess
        var mapper = Mapper(projection: settings.projection, f: f, cx: Double(refPhoto.width) / 2, cy: Double(refPhoto.height) / 2)
        var bounds = mapper.bounds(photos, registration.transforms)
        // A perspective panorama too wide to show sensibly (photos at 90° or more) becomes cylindrical.
        if settings.projection == .perspective,
           bounds == nil || (bounds!.maxU - bounds!.minU) * (bounds!.maxV - bounds!.minV) > 30 * Double(refPhoto.width * refPhoto.height) {
            mapper = Mapper(projection: .cylindrical, f: f, cx: mapper.cx, cy: mapper.cy)
            bounds = mapper.bounds(photos, registration.transforms)
        }
        guard let b = bounds else { return nil }
        let k = min(1, Double(maxSide) / max(b.maxU - b.minU, b.maxV - b.minV))
        let width = max(1, Int(((b.maxU - b.minU) * k).rounded(.up))), height = max(1, Int(((b.maxV - b.minV) * k).rounded(.up)))
        let canvas = Canvas(mapper: mapper, minU: b.minU, minV: b.minV, scale: k, width: width, height: height)

        // Which photo each pixel takes (the one it is most central in), and the overlaps for the gains.
        var label = [Int8](repeating: -1, count: width * height)
        var best = [Float](repeating: 0, count: width * height)
        var inverse: [Int: Homography] = [:]
        for i in used { inverse[i] = registration.transforms[i]!.inverse }
        var overlap = [[Double]](repeating: [Double](repeating: 0, count: photos.count), count: photos.count)
        var overlapCount = [[Double]](repeating: [Double](repeating: 0, count: photos.count), count: photos.count)
        for y in 0..<height {
            for x in 0..<width {
                var seen: [(Int, Float)] = []
                for i in used {
                    guard let p = canvas.source(x, y, inverse[i]!), let w = weight(p, photos[i]) else { continue }
                    if w > best[y * width + x] {
                        best[y * width + x] = w
                        label[y * width + x] = Int8(i)
                    }
                    if (x | y) & 3 == 0 { seen.append((i, luma(photos[i], p))) }
                }
                for a in seen {
                    for c in seen where c.0 != a.0 {
                        overlap[a.0][c.0] += Double(a.1)
                        overlapCount[a.0][c.0] += 1
                    }
                }
            }
        }
        let gains = gainCompensation(overlap, overlapCount, used: used)

        // Multi-band blend of the photos through their seams.
        let levels = Pyramid.levels(width: width, height: height, cap: 7)
        var sum = Pyramid.Accumulator(width: width, height: height, channels: 3, levels: levels)
        for i in used {
            let warped = canvas.warp(photos[i], inverse[i]!, gain: gains[i])
            let mask = label.map { $0 == Int8(i) ? Float(1) : 0 }
            sum.add(warped, weight: mask)
        }
        var image = sum.result()
        var coverage = label.map { $0 >= 0 ? Float(1) : 0 }
        for i in 0..<(width * height) {
            for c in 0..<3 { image.data[3 * i + c] = coverage[i] > 0 ? min(1, max(0, image.data[3 * i + c])) : 0 }
        }
        if settings.boundaryWarp > 0 {
            (image, coverage) = boundaryWarp(image, coverage: coverage, amount: settings.boundaryWarp)
        }
        if settings.fillEdges {
            (image, coverage) = fillEdges(image, coverage: coverage)
        }
        return Result(image: image, coverage: coverage, used: used.count)
    }

    // MARK: - Registration

    /// Matches every pair of photos and joins the best pairs into a tree (largest number of matches
    /// first), rooted at the photo with the most matches.
    public static func register(_ photos: [FloatImage]) -> Registration {
        let n = photos.count
        var points: [[Features.Corner]] = [], descriptors: [[[Float]?]] = [], scales: [Double] = []
        for photo in photos {
            let s = min(1, registrationSide / Double(max(photo.width, photo.height)))
            let grey = resized(photo.luma, width: max(1, Int(Double(photo.width) * s)), height: max(1, Int(Double(photo.height) * s)))
            let found = Features.corners(grey)
            points.append(found)
            descriptors.append(Features.describe(grey, found))
            scales.append(s)
        }
        // Pairwise: the homography taking photo j into photo i (full-size pixels).
        var pair: [Int: (h: Homography, inliers: Int)] = [:]
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                let matches = Features.match(descriptors[i], descriptors[j])
                guard matches.count >= 12 else { continue }
                let from = matches.map { Vec2(points[j][$0.1].x, points[j][$0.1].y) }
                let to = matches.map { Vec2(points[i][$0.0].x, points[i][$0.0].y) }
                let size = (Double(photos[j].width) * scales[j], Double(photos[j].height) * scales[j])
                guard let found = Features.homography(from: from, to: to, size: size, threshold: 2.5) else { continue }
                // Enough of the matches agree (chance matches between unrelated photos rarely do).
                guard found.inliers.count >= 15, Double(found.inliers.count) >= 0.2 * Double(matches.count) else { continue }
                let h = Homography.scale(1 / scales[i], 1 / scales[i]) * found.h * Homography.scale(scales[j], scales[j])
                pair[i * n + j] = (h.normalized, found.inliers.count)
            }
        }
        // The tree: grown from the best-connected photo along the strongest links (Prim).
        var strength = [Int](repeating: 0, count: n)
        for (key, value) in pair {
            strength[key / n] += value.inliers
            strength[key % n] += value.inliers
        }
        let reference = strength.indices.max { strength[$0] < strength[$1] } ?? 0
        var transforms = [Homography?](repeating: nil, count: n)
        transforms[reference] = .identity
        var links: [(parent: Int, child: Int, inliers: Int)] = []
        while true {
            var bestLink: (parent: Int, child: Int, h: Homography, inliers: Int)?
            for (key, value) in pair {
                let i = key / n, j = key % n
                // i is in the tree and j is not (h takes j into i), or the other way round.
                if transforms[i] != nil, transforms[j] == nil, value.inliers > (bestLink?.inliers ?? 0) {
                    bestLink = (i, j, value.h, value.inliers)
                } else if transforms[j] != nil, transforms[i] == nil, value.inliers > (bestLink?.inliers ?? 0) {
                    bestLink = (j, i, value.h.inverse, value.inliers)
                }
            }
            guard let link = bestLink, let parent = transforms[link.parent] else { break }
            transforms[link.child] = (parent * link.h).normalized
            links.append((link.parent, link.child, link.inliers))
        }
        return Registration(reference: reference, transforms: transforms, links: links)
    }

    /// The focal length (pixels) the photos' homographies imply, as OpenCV's focalsFromHomography
    /// works it out for a camera turning about its centre; the median over the links. Nil when they
    /// don't say (a camera that moved sideways, or too little turn).
    static func estimateFocal(_ registration: Registration, photos: [FloatImage]) -> Double? {
        var estimates: [Double] = []
        for link in registration.links {
            guard let hp = registration.transforms[link.parent], let hc = registration.transforms[link.child] else { continue }
            let p = photos[link.parent], c = photos[link.child]
            // Child → parent, about each photo's centre.
            let centred = (Homography.translation(-Double(p.width) / 2, -Double(p.height) / 2) * hp.inverse * hc
                           * Homography.translation(Double(c.width) / 2, Double(c.height) / 2)).normalized
            if let f = focal(from: centred), f > 0.3 * Double(max(c.width, c.height)), f < 6 * Double(max(c.width, c.height)) {
                estimates.append(f)
            }
        }
        guard !estimates.isEmpty else { return nil }
        return estimates.sorted()[estimates.count / 2]
    }

    /// OpenCV's focalsFromHomography: √(f0 f1) from a homography between two views of a turning camera.
    static func focal(from h: Homography) -> Double? {
        let m = h.m
        // Of the two candidates (some are 0 ÷ 0 for a pure turn), the larger when d1 is the bigger divisor.
        func solve(_ d1: Double, _ d2: Double, _ v1: Double, _ v2: Double) -> Double? {
            let ok = [v1, v2].filter { $0.isFinite && $0 > 0 }
            if ok.count == 2 { return (abs(d1) > abs(d2) ? ok.max()! : ok.min()!).squareRoot() }
            return ok.first?.squareRoot()
        }
        var d1 = m[6] * m[7], d2 = (m[7] - m[6]) * (m[7] + m[6])
        guard abs(d1) > 1e-14 || abs(d2) > 1e-14 else { return nil }
        guard let f1 = solve(d1, d2, -(m[0] * m[1] + m[3] * m[4]) / d1, (m[0] * m[0] + m[3] * m[3] - m[1] * m[1] - m[4] * m[4]) / d2) else {
            return nil
        }
        d1 = m[0] * m[3] + m[1] * m[4]
        d2 = m[0] * m[0] + m[1] * m[1] - m[3] * m[3] - m[4] * m[4]
        guard let f0 = solve(d1, d2, -m[2] * m[5] / d1, (m[5] * m[5] - m[2] * m[2]) / d2) else { return nil }
        let f = (f0 * f1).squareRoot()
        return f.isFinite ? f : nil
    }

    // MARK: - Projection

    /// Where things land: a point on the reference photo's plane is a ray from the camera; the ray
    /// gives the output position (u, v) by the projection, in pixels at the reference's scale.
    struct Mapper {
        let projection: Projection
        let f: Double
        let cx: Double
        let cy: Double

        /// The ray through a point of the reference plane given as (X, Y, W) (homogeneous: W < 0 is behind).
        func ray(_ p: (Double, Double, Double)) -> (Double, Double, Double) {
            (p.0 - cx * p.2, p.1 - cy * p.2, f * p.2)
        }

        /// The output position of a ray (nil when the projection can't show it).
        func uv(_ r: (Double, Double, Double)) -> (Double, Double)? {
            switch projection {
            case .perspective:
                guard r.2 > 1e-9 else { return nil }
                return (f * r.0 / r.2, f * r.1 / r.2)
            case .cylindrical:
                let across = (r.0 * r.0 + r.2 * r.2).squareRoot()
                guard across > 1e-12 else { return nil }
                return (f * atan2(r.0, r.2), f * r.1 / across)
            case .spherical:
                let across = (r.0 * r.0 + r.2 * r.2).squareRoot()
                return (f * atan2(r.0, r.2), f * atan2(r.1, across))
            }
        }

        /// The ray an output position shows.
        func ray(u: Double, v: Double) -> (Double, Double, Double) {
            let theta = u / f
            switch projection {
            case .perspective: return (u / f, v / f, 1)
            case .cylindrical: return (sin(theta), v / f, cos(theta))
            case .spherical:
                let phi = v / f
                return (sin(theta) * cos(phi), sin(phi), cos(theta) * cos(phi))
            }
        }

        /// The point of the reference plane a ray goes through (homogeneous).
        func plane(_ r: (Double, Double, Double)) -> (Double, Double, Double) {
            (f * r.0 + cx * r.2, f * r.1 + cy * r.2, r.2)
        }

        /// The output box the photos' edges fill (nil when one can't be shown).
        func bounds(_ photos: [FloatImage], _ transforms: [Homography?]) -> (minU: Double, maxU: Double, minV: Double, maxV: Double)? {
            var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
            for (photo, h) in zip(photos, transforms) {
                guard let h else { continue }
                let w = Double(photo.width), hh = Double(photo.height)
                var edge: [Vec2] = []
                for k in 0...32 {
                    let t = Double(k) / 32
                    edge += [Vec2(t * w, 0), Vec2(t * w, hh), Vec2(0, t * hh), Vec2(w, t * hh)]
                }
                for p in edge {
                    let m = h.m
                    let q = (m[0] * p.x + m[1] * p.y + m[2], m[3] * p.x + m[4] * p.y + m[5], m[6] * p.x + m[7] * p.y + m[8])
                    guard let (u, v) = uv(ray(q)) else { return nil }
                    minU = min(minU, u)
                    maxU = max(maxU, u)
                    minV = min(minV, v)
                    maxV = max(maxV, v)
                }
            }
            guard minU.isFinite, maxU > minU, maxV > minV else { return nil }
            return (minU, maxU, minV, maxV)
        }
    }

    /// The output picture's grid: pixel (x, y) is at (minU + x ÷ scale, minV + y ÷ scale).
    struct Canvas {
        let mapper: Mapper
        let minU: Double
        let minV: Double
        let scale: Double
        let width: Int
        let height: Int

        /// Where output pixel (x, y) is on a photo (`inverse`: the reference plane → the photo); nil
        /// when the photo faces away from it.
        func source(_ x: Int, _ y: Int, _ inverse: Homography) -> Vec2? {
            let r = mapper.ray(u: minU + (Double(x) + 0.5) / scale, v: minV + (Double(y) + 0.5) / scale)
            let p = mapper.plane(r)
            let m = inverse.m
            let z = m[6] * p.0 + m[7] * p.1 + m[8] * p.2
            guard z > 1e-12 else { return nil }
            return Vec2((m[0] * p.0 + m[1] * p.1 + m[2] * p.2) / z, (m[3] * p.0 + m[4] * p.1 + m[5] * p.2) / z)
        }

        /// A photo drawn onto the output grid (its edge colours carried on beyond it, so blending near
        /// its border doesn't pull in black), its linear light × `gain`.
        func warp(_ photo: FloatImage, _ inverse: Homography, gain: Double) -> FloatImage {
            var out = FloatImage(width: width, height: height, channels: 3)
            let w = photo.width, h = photo.height
            let g = Float(gain)
            for y in 0..<height {
                for x in 0..<width {
                    guard let p = source(x, y, inverse) else { continue }
                    let sx = min(max(p.x - 0.5, 0), Double(w - 1)), sy = min(max(p.y - 0.5, 0), Double(h - 1))
                    let x0 = Int(sx), y0 = Int(sy), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                    let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                    for c in 0..<3 {
                        let a = photo.data[(y0 * w + x0) * 3 + c], b = photo.data[(y0 * w + x1) * 3 + c]
                        let d = photo.data[(y1 * w + x0) * 3 + c], e = photo.data[(y1 * w + x1) * 3 + c]
                        let v = (a * (1 - fx) + b * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy
                        out.data[(y * width + x) * 3 + c] = g == 1 ? v : SRGB.encoded(min(1, SRGB.linear(v) * g))
                    }
                }
            }
            return out
        }
    }

    /// How central a point is in a photo (1 in the middle, falling to 0 at its edges); nil outside it.
    static func weight(_ p: Vec2, _ photo: FloatImage) -> Float? {
        let w = Double(photo.width), h = Double(photo.height)
        guard p.x >= 0, p.y >= 0, p.x <= w, p.y <= h else { return nil }
        return Float((1 - abs(2 * p.x / w - 1)) * (1 - abs(2 * p.y / h - 1))) + 1e-6
    }

    /// Linear brightness of a photo at a point (nearest pixel).
    static func luma(_ photo: FloatImage, _ p: Vec2) -> Float {
        let x = min(max(Int(p.x), 0), photo.width - 1), y = min(max(Int(p.y), 0), photo.height - 1)
        let i = (y * photo.width + x) * 3
        return SRGB.linear(0.2126 * photo.data[i] + 0.7152 * photo.data[i + 1] + 0.0722 * photo.data[i + 2])
    }

    /// One gain per photo so overlaps agree, kept near 1 (Brown & Lowe's least squares). `sum[i][j]`:
    /// photo i's brightness summed over its overlap with j; `count[i][j]`: that overlap's size.
    static func gainCompensation(_ sum: [[Double]], _ count: [[Double]], used: [Int]) -> [Double] {
        let n = sum.count
        var gains = [Double](repeating: 1, count: n)
        guard used.count >= 2 else { return gains }
        let sigmaN = 0.03, sigmaG = 0.1
        var rows = [[Double]](repeating: [Double](repeating: 0, count: used.count + 1), count: used.count)
        for (a, i) in used.enumerated() {
            rows[a][a] = 1e-9
            for (b, j) in used.enumerated() where i != j && count[i][j] > 0 {
                let nij = count[i][j]
                let iij = sum[i][j] / nij, iji = sum[j][i] / max(count[j][i], 1)
                rows[a][a] += nij * (iij * iij / (sigmaN * sigmaN) + 1 / (sigmaG * sigmaG))
                rows[a][b] -= nij * iij * iji / (sigmaN * sigmaN)
                rows[a][used.count] += nij / (sigmaG * sigmaG)
            }
            if rows[a][used.count] == 0 { rows[a][a] = 1; rows[a][used.count] = 1 }
        }
        if let solved = Homography.solve(rows) {
            for (a, i) in used.enumerated() where solved[a].isFinite && solved[a] > 0.2 && solved[a] < 5 { gains[i] = solved[a] }
        }
        return gains
    }

    // MARK: - Edges

    /// Stretches each column so its covered part reaches the top and bottom, then each row so it
    /// reaches the sides, by `amount` (0…1). The covered span is first narrowed a little where it dips
    /// (so the stretch never pulls empty corners in) and smoothed.
    public static func boundaryWarp(_ image: FloatImage, coverage: [Float], amount: Double) -> (FloatImage, [Float]) {
        let a = min(1, max(0, amount))
        guard a > 0 else { return (image, coverage) }
        var (img, cov) = stretch(image, coverage: coverage, amount: a, vertical: true)
        (img, cov) = stretch(img, coverage: cov, amount: a, vertical: false)
        return (img, cov)
    }

    /// One direction of boundaryWarp: columns (`vertical`) or rows.
    static func stretch(_ image: FloatImage, coverage: [Float], amount: Double, vertical: Bool) -> (FloatImage, [Float]) {
        let w = image.width, h = image.height
        let lines = vertical ? w : h, length = vertical ? h : w
        func index(_ line: Int, _ t: Int) -> Int { vertical ? t * w + line : line * w + t }
        // The covered span of each line.
        var start = [Float](repeating: 0, count: lines), end = [Float](repeating: Float(length - 1), count: lines)
        var known = [Bool](repeating: false, count: lines)
        for line in 0..<lines {
            var first = -1, last = -1
            for t in 0..<length where coverage[index(line, t)] > 0.5 {
                if first < 0 { first = t }
                last = t
            }
            if first >= 0, last > first {
                start[line] = Float(first)
                end[line] = Float(last)
                known[line] = true
            }
        }
        guard known.contains(true) else { return (image, coverage) }
        // Lines with nothing take their nearest neighbour's span.
        for line in 0..<lines where !known[line] {
            let near = (0..<lines).filter { known[$0] }.min { abs($0 - line) < abs($1 - line) }!
            start[line] = start[near]
            end[line] = end[near]
        }
        // A smooth curve just inside the span (so the stretch bends the picture gently and pulls no
        // empty corner in): smoothed again and again, never below the span's start (above its end).
        let r = max(1, lines / 12)
        var top = start, bottom = end
        for _ in 0..<10 {
            top = Grid.blur(zip(top, start).map { max($0, $1) }, width: lines, height: 1, radius: r)
            bottom = Grid.blur(zip(bottom, end).map { min($0, $1) }, width: lines, height: 1, radius: r)
        }
        start = zip(top, start).map { max($0, $1) }
        end = zip(bottom, end).map { min($0, $1) }
        start = Grid.blur(start, width: lines, height: 1, radius: 2)
        end = Grid.blur(end, width: lines, height: 1, radius: 2)
        var out = image, cov = coverage
        let k = Float(amount)
        let channels = image.channels
        for line in 0..<lines {
            let s = start[line], e = end[line]
            for t in 0..<length {
                let target = Float(t)
                let from = (1 - k) * target + k * (s + target * (e - s) / Float(max(length - 1, 1)))
                let t0 = min(max(Int(from), 0), length - 1), t1 = min(t0 + 1, length - 1)
                let f = min(max(from - Float(t0), 0), 1)
                let i = index(line, t), i0 = index(line, t0), i1 = index(line, t1)
                for c in 0..<channels { out.data[i * channels + c] = image.data[i0 * channels + c] * (1 - f) + image.data[i1 * channels + c] * f }
                cov[i] = coverage[i0] * (1 - f) + coverage[i1] * f
            }
        }
        return (out, cov)
    }

    /// Makes up the empty parts with content-aware fill (on a copy of at most about 120 000 pixels,
    /// enlarged into the gaps and blended in over a few pixels).
    public static func fillEdges(_ image: FloatImage, coverage: [Float]) -> (FloatImage, [Float]) {
        let w = image.width, h = image.height
        guard coverage.contains(where: { $0 < 0.5 }), coverage.contains(where: { $0 >= 0.5 }) else { return (image, coverage) }
        let factor = max(1, Int((Double(w * h) / 120_000).squareRoot().rounded(.up)))
        let sw = max(1, w / factor), sh = max(1, h / factor)
        // The small copy: each cell the average of its covered pixels; a gap where most are empty.
        var small = RGBBuffer(width: sw, height: sh, pixels: [Float](repeating: 0, count: sw * sh * 3))
        var hole = [Bool](repeating: false, count: sw * sh)
        for sy in 0..<sh {
            for sx in 0..<sw {
                var sum: (Float, Float, Float) = (0, 0, 0)
                var n: Float = 0, cells: Float = 0
                for y in (sy * factor)..<min(h, (sy + 1) * factor) {
                    for x in (sx * factor)..<min(w, (sx + 1) * factor) {
                        cells += 1
                        guard coverage[y * w + x] >= 0.5 else { continue }
                        let i = (y * w + x) * 3
                        sum = (sum.0 + image.data[i], sum.1 + image.data[i + 1], sum.2 + image.data[i + 2])
                        n += 1
                    }
                }
                let j = sy * sw + sx
                hole[j] = n < cells * 0.5
                if n > 0 { (small.pixels[3 * j], small.pixels[3 * j + 1], small.pixels[3 * j + 2]) = (sum.0 / n, sum.1 / n, sum.2 / n) }
            }
        }
        let filled = Inpaint.fill(small, hole: hole)
        // Blend the fill in where coverage is missing, over a soft edge a few pixels wide.
        let soft = Grid.blur(coverage, width: w, height: h, radius: 2)
        var out = image
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let keep = min(coverage[i], soft[i])
                guard keep < 1 else { continue }
                let c = filled.bilinear(x: (Double(x) + 0.5) / Double(factor) - 0.5, y: (Double(y) + 0.5) / Double(factor) - 0.5)
                let fill = [c.0, c.1, c.2]
                for ch in 0..<3 { out.data[i * 3 + ch] = out.data[i * 3 + ch] * keep + fill[ch] * (1 - keep) }
            }
        }
        return (out, [Float](repeating: 1, count: w * h))
    }

    /// A grey picture resized (halved by 2 × 2 averages while it is over twice too big, then bilinear).
    static func resized(_ grey: FloatImage, width: Int, height: Int) -> FloatImage {
        var g = grey
        while g.width >= 2 * width, g.height >= 2 * height { g = Align.halved(g) }
        guard g.width != width || g.height != height else { return g }
        var out = FloatImage(width: width, height: height, channels: 1)
        let sx = Double(g.width) / Double(width), sy = Double(g.height) / Double(height)
        for y in 0..<height {
            for x in 0..<width {
                let fx = min(max((Double(x) + 0.5) * sx - 0.5, 0), Double(g.width - 1))
                let fy = min(max((Double(y) + 0.5) * sy - 0.5, 0), Double(g.height - 1))
                let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, g.width - 1), y1 = min(y0 + 1, g.height - 1)
                let ax = Float(fx - Double(x0)), ay = Float(fy - Double(y0))
                let top = g.data[y0 * g.width + x0] * (1 - ax) + g.data[y0 * g.width + x1] * ax
                let bottom = g.data[y1 * g.width + x0] * (1 - ax) + g.data[y1 * g.width + x1] * ax
                out.data[y * width + x] = top * (1 - ay) + bottom * ay
            }
        }
        return out
    }
}

extension Grid {
    /// Largest (`grow`) or smallest value within `radius` along a line of numbers.
    static func dilate1D(_ values: [Float], radius: Int, grow: Bool) -> [Float] {
        values.indices.map { i in
            let part = values[max(0, i - radius)...min(values.count - 1, i + radius)]
            return (grow ? part.max() : part.min()) ?? values[i]
        }
    }
}

/// HDR panorama: brackets shot at each position of a panorama, picked in order (all of one position's
/// brackets, then the next position's), merged by HDRMerge position by position and then stitched.
public enum HDRPanorama {
    /// How many brackets each position has: the group size whose exposure pattern repeats best from
    /// group to group (log brightness at each place in the group varies least across groups), with a
    /// real exposure spread inside a group. Nil when no size fits.
    public static func bracketSize(_ brightness: [Float]) -> Int? {
        let n = brightness.count
        guard n >= 4 else { return nil }
        let logs = brightness.map { log(max($0, 1e-5)) }
        let mean = logs.reduce(0, +) / Float(n)
        let total = logs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(n)
        guard total > 1e-6 else { return nil }
        var best: (size: Int, score: Float)?
        for size in 2...(n / 2) where n % size == 0 {
            var within: Float = 0
            for place in 0..<size {
                let values = stride(from: place, to: n, by: size).map { logs[$0] }
                let m = values.reduce(0, +) / Float(values.count)
                within += values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
            }
            let score = within / Float(n) / total
            // Inside each group the exposures must differ (at least 1.4 × from darkest to brightest).
            let spread = stride(from: 0, to: n, by: size).allSatisfy { start in
                let group = logs[start..<(start + size)]
                return (group.max() ?? 0) - (group.min() ?? 0) > log(1.4)
            }
            if spread, score < 0.35, score < (best?.score ?? .infinity) - 1e-4 { best = (size, score) }
        }
        return best?.size
    }

    /// Merges each position's brackets, then stitches the merged pictures. The result is on sRGB
    /// levels for Fusion; for Radiance it is linear light (`linear` true), brought into 0…1 for the
    /// stitch and back. Nil when the brackets can't be told apart or the positions don't fit together.
    public static func merge(_ photos: [FloatImage], deghost: Int, output: HDRMerge.Output, settings: Panorama.Settings,
                             focal: Double? = nil, maxSide: Int = 8000) -> (result: Panorama.Result, linear: Bool)? {
        let brightness = photos.map { $0.luma.map(SRGB.linear).mean }
        guard let size = bracketSize(brightness) else { return nil }
        var merged: [FloatImage] = []
        for start in stride(from: 0, to: photos.count, by: size) {
            let group = Array(photos[start..<(start + size)])
            // A position's brackets share the first one's size.
            let first = group[0]
            let same = group.allSatisfy { $0.width == first.width && $0.height == first.height }
            guard same else { return nil }
            merged.append(HDRMerge.merge(group, deghost: deghost, output: output))
        }
        // (`used` then counts photos: every bracket of each position joined in.)
        guard output == .radiance else {
            guard var result = Panorama.stitch(merged, settings: settings, focal: focal, maxSide: maxSide) else { return nil }
            result.used *= size
            return (result, false)
        }
        // Radiance: every position ÷ the brightest level, on sRGB levels for the stitch, then back.
        let peak = max(1e-6, merged.map { $0.data.max() ?? 1 }.max() ?? 1)
        let encoded = merged.map { $0.map { SRGB.encoded(min(1, max(0, $0 / peak))) } }
        guard var result = Panorama.stitch(encoded, settings: settings, focal: focal, maxSide: maxSide) else { return nil }
        result.image = result.image.map { SRGB.linear($0) * peak }
        result.used *= size
        return (result, true)
    }
}
