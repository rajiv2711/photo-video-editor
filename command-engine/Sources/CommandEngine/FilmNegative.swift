import Foundation

/// Film negative conversion: turns a scanned colour negative into a positive. Shared by the iPad
/// renderer and the Linux tests.
///
/// Each channel is inverted and stretched between its own darkest and brightest levels (0.5 % and
/// 99.5 % of the pixels, on sRGB levels). Stretching each channel on its own also takes out the
/// film's orange mask.
///
///     let t = FilmNegative.transfer(red: rHist, green: gHist, blue: bHist)
///     // positive level = negative level × t.scale + t.bias, per channel
public enum FilmNegative {
    /// Per-channel multiplier (negative) and offset. Histograms: share of pixels per level bin, darkest first.
    public static func transfer(red: [Double], green: [Double], blue: [Double]) -> (scale: RGB, bias: RGB) {
        func channel(_ histogram: [Double]) -> (Double, Double) {
            let lo = percentile(histogram, 0.005), hi = percentile(histogram, 0.995)
            let span = Swift.max(hi - lo, 0.02)
            return (-1 / span, hi / span)
        }
        let r = channel(red), g = channel(green), b = channel(blue)
        return (RGB(r.0, g.0, b.0), RGB(r.1, g.1, b.1))
    }

    /// The level (0…1, bin centre) below which a share `p` of the pixels lies.
    static func percentile(_ histogram: [Double], _ p: Double) -> Double {
        let total = histogram.reduce(0, +)
        guard total > 0, histogram.count > 1 else { return p }
        var sum = 0.0
        for (i, count) in histogram.enumerated() {
            sum += count / total
            if sum >= p { return (Double(i) + 0.5) / Double(histogram.count) }
        }
        return 1
    }
}
