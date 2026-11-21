import Foundation

/// Lining up photos of the same scene taken one after another (hand-held brackets, bursts, focus
/// slices), without learning.
///
/// Translation by median threshold bitmaps (Ward 2003): each picture becomes black and white at its
/// own median brightness, which hardly changes with exposure, so a dark and a bright bracket give
/// nearly the same bitmap. (When over half of a bracket is clipped white or black, another
/// percentile both pictures still show is used instead of the median.) The shift that makes the
/// bitmaps disagree least is found coarse to fine on a pyramid (±1 pixel per level, doubled on the
/// way up), ignoring pixels too close to the threshold.
public enum Align {
    /// A shift in whole pixels: content at (x, y) in the picture is at (x + dx, y + dy) in the reference.
    public struct Shift: Equatable {
        public var dx: Int
        public var dy: Int

        public init(_ dx: Int, _ dy: Int) {
            self.dx = dx
            self.dy = dy
        }

        public static let zero = Shift(0, 0)
    }

    /// The shift that lines `image` up with `reference` (one-channel pictures of one size), up to
    /// about `maxShare` of the small side.
    public static func translation(reference: FloatImage, image: FloatImage, maxShare: Double = 0.06) -> Shift {
        guard reference.width == image.width, reference.height == image.height, reference.count > 0 else { return .zero }
        let side = Double(min(reference.width, reference.height))
        // Levels: each doubles the reach; the coarsest level stays at least 24 pixels across.
        var levels = 1
        while levels < 7, Double((1 << levels) - 1) < side * maxShare, side / Double(1 << levels) >= 24 { levels += 1 }
        var a = [reference.luma], b = [image.luma]
        for _ in 1..<levels {
            a.append(halved(a[a.count - 1]))
            b.append(halved(b[b.count - 1]))
        }
        let q = sharedQuantile(a[0], b[0])
        // The thresholds come from the part both pictures show, so they mark the same scene
        // brightness: first the whole pictures, then the overlap the shift found leaves (twice at most).
        var shift = Shift.zero
        for pass in 0..<3 {
            let ta = threshold(a[0], quantile: q, overlap: shift, moved: false)
            let tb = threshold(b[0], quantile: q, overlap: shift, moved: true)
            let found = search(a, b, thresholds: (ta, tb))
            if pass > 0, found == shift { break }
            shift = found
        }
        return shift
    }

    /// Coarse to fine: ±1 pixel per level around the shift found on the level above.
    static func search(_ a: [FloatImage], _ b: [FloatImage], thresholds: (Float, Float)) -> Shift {
        var shift = Shift.zero
        for level in stride(from: a.count - 1, through: 0, by: -1) {
            shift = level == a.count - 1 ? .zero : Shift(shift.dx * 2, shift.dy * 2)
            let ta = bitmaps(a[level], threshold: thresholds.0), tb = bitmaps(b[level], threshold: thresholds.1)
            var best = shift, bestError = Int.max
            for dy in -1...1 {
                for dx in -1...1 {
                    let candidate = Shift(shift.dx + dx, shift.dy + dy)
                    let error = disagreement(ta, tb, width: a[level].width, height: a[level].height, shift: candidate)
                    if error < bestError || (error == bestError && dx == 0 && dy == 0) {
                        bestError = error
                        best = candidate
                    }
                }
            }
            shift = best
        }
        return shift
    }

    /// The value at `quantile` of the part of a picture the other one also shows, given `overlap`
    /// (the shift; `moved`: this is the picture being moved).
    static func threshold(_ g: FloatImage, quantile: Float, overlap shift: Shift, moved: Bool) -> Float {
        let dx = moved ? -shift.dx : shift.dx, dy = moved ? -shift.dy : shift.dy
        let x0 = max(0, dx), x1 = min(g.width, g.width + dx), y0 = max(0, dy), y1 = min(g.height, g.height + dy)
        guard x0 < x1, y0 < y1 else { return 0.5 }
        let step = max(1, Int(Double((x1 - x0) * (y1 - y0) / 20_000).squareRoot()))
        var sample: [Float] = []
        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) { sample.append(g.data[y * g.width + x]) }
        }
        sample.sort()
        return sample.isEmpty ? 0.5 : sample[Int(quantile * Float(sample.count - 1))]
    }

    /// Half size by 2 × 2 averages.
    static func halved(_ g: FloatImage) -> FloatImage {
        let w = max(1, g.width / 2), h = max(1, g.height / 2)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let x0 = min(2 * x, g.width - 1), x1 = min(2 * x + 1, g.width - 1)
                let y0 = min(2 * y, g.height - 1), y1 = min(2 * y + 1, g.height - 1)
                out[y * w + x] = (g.data[y0 * g.width + x0] + g.data[y0 * g.width + x1] + g.data[y1 * g.width + x0] + g.data[y1 * g.width + x1]) / 4
            }
        }
        return FloatImage(width: w, height: h, channels: 1, data: out)
    }

    /// Some of a picture's values, sorted (at most about 20 000).
    static func sortedSample(_ g: FloatImage) -> [Float] {
        stride(from: 0, to: g.data.count, by: max(1, g.data.count / 20_000)).map { g.data[$0] }.sorted()
    }

    /// The share of pixels to threshold at: the median, or the nearest percentile that is neither
    /// clipped white nor black in both pictures.
    static func sharedQuantile(_ a: FloatImage, _ b: FloatImage) -> Float {
        let sa = sortedSample(a), sb = sortedSample(b)
        guard !sa.isEmpty, !sb.isEmpty else { return 0.5 }
        for q: Float in [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8, 0.12, 0.88, 0.06, 0.94] {
            let va = sa[Int(q * Float(sa.count - 1))], vb = sb[Int(q * Float(sb.count - 1))]
            if va > 0.03, va < 0.97, vb > 0.03, vb < 0.97 { return q }
        }
        return 0.5
    }

    /// Above the threshold (1) or not (0), and whether a pixel is far enough from it to count.
    static func bitmaps(_ g: FloatImage, threshold median: Float) -> (bits: [UInt8], counts: [UInt8]) {
        // About 4 levels of 255, as Ward suggests, relative to the picture's own spread.
        let band: Float = 4 / 255 * max(0.25, min(1, median * 4))
        var bits = [UInt8](repeating: 0, count: g.count), counts = [UInt8](repeating: 0, count: g.count)
        for i in 0..<g.count {
            let v = g.data[i]
            bits[i] = v > median ? 1 : 0
            counts[i] = abs(v - median) > band ? 1 : 0
        }
        return (bits, counts)
    }

    /// How many counted pixels differ when `b` is moved by `shift` onto `a`.
    static func disagreement(_ a: (bits: [UInt8], counts: [UInt8]), _ b: (bits: [UInt8], counts: [UInt8]),
                             width w: Int, height h: Int, shift: Shift) -> Int {
        var errors = 0
        let x0 = max(0, shift.dx), x1 = min(w, w + shift.dx)
        let y0 = max(0, shift.dy), y1 = min(h, h + shift.dy)
        guard x0 < x1, y0 < y1 else { return Int.max }
        a.bits.withUnsafeBufferPointer { ab in
            a.counts.withUnsafeBufferPointer { ac in
                b.bits.withUnsafeBufferPointer { bb in
                    b.counts.withUnsafeBufferPointer { bc in
                        for y in y0..<y1 {
                            let row = y * w, other = (y - shift.dy) * w - shift.dx
                            for x in x0..<x1 {
                                let i = row + x, j = other + x
                                errors += Int((ab[i] ^ bb[j]) & ac[i] & bc[j])
                            }
                        }
                    }
                }
            }
        }
        // Per counted overlap, so big shifts (less overlap) don't win by default.
        let overlap = (x1 - x0) * (y1 - y0)
        return errors * (w * h) / max(1, overlap)
    }

    /// `image` moved by `shift` (edges repeated), and which pixels came from inside it (1) or are
    /// repeated edge (0).
    public static func shifted(_ image: FloatImage, by shift: Shift) -> (image: FloatImage, valid: [Float]) {
        let w = image.width, h = image.height, c = image.channels
        guard shift != .zero else { return (image, [Float](repeating: 1, count: w * h)) }
        var out = image
        var valid = [Float](repeating: 1, count: w * h)
        for y in 0..<h {
            let sy = y - shift.dy
            for x in 0..<w {
                let sx = x - shift.dx
                if sx < 0 || sy < 0 || sx >= w || sy >= h { valid[y * w + x] = 0 }
                let cx = min(max(sx, 0), w - 1), cy = min(max(sy, 0), h - 1)
                for ch in 0..<c { out.data[(y * w + x) * c + ch] = image.data[(cy * w + cx) * c + ch] }
            }
        }
        return (out, valid)
    }
}
