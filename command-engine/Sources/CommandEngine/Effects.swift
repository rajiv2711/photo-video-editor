import Foundation

/// Math for the Effects and Detail panels that the iPad renderer turns into Core Image passes:
/// lookup tables (masks and tone steps). Tested on Linux.
///
/// A table lists output levels for evenly spaced inputs over 0…1:
///
///     Effects.table(count: 3) { $0 * $0 }   → [0, 0.25, 1]
public enum Effects {
    /// Smooth 0 → 1 ramp between `low` and `high` (0 below, 1 above).
    public static func smoothstep(_ low: Double, _ high: Double, _ x: Double) -> Double {
        guard high > low else { return x < low ? 0 : 1 }
        let t = Swift.min(Swift.max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// `f` sampled at `count` evenly spaced inputs over 0…1.
    public static func table(count: Int = 256, _ f: (Double) -> Double) -> [Double] {
        (0..<count).map { f(Double($0) / Double(count - 1)) }
    }

    /// Negative Texture: how much of a blurred copy to use, by the local brightness range around a
    /// pixel (brightest − darkest nearby, sRGB levels). Fine detail is smoothed by `amount` (0…1);
    /// strong edges (range above 0.3) stay sharp.
    public static func textureSmoothing(amount: Double) -> [Double] {
        table(count: 64) { range in amount * 0.85 * (1 - smoothstep(0.12, 0.3, range)) }
    }

    /// Clarity: how much of the change to keep at each brightness (sRGB luma): all of it in the
    /// midtones (0.35…0.65), fading out towards black and white so those don't clip.
    public static func midtones() -> [Double] {
        table(count: 64) { l in smoothstep(0.02, 0.35, l) * (1 - smoothstep(0.65, 0.98, l)) }
    }

    // MARK: - Dehaze (dark channel prior)

    /// Lowest transmission positive Dehaze divides by (stronger would blow up noise).
    public static let dehazeFloor = 0.25

    /// The haze colour ("airlight"): each channel's 99.5th percentile level, from histograms of sRGB
    /// levels (share of pixels per bin, darkest first). At least 0.5, so a dark photo isn't read as haze.
    public static func airlight(red: [Double], green: [Double], blue: [Double]) -> RGB {
        func percentile(_ bins: [Double]) -> Double {
            let total = bins.reduce(0, +)
            guard total > 0, bins.count > 1 else { return 1 }
            var sum = 0.0
            for (i, share) in bins.enumerated() {
                sum += share / total
                if sum >= 0.995 { return Swift.max(0.5, Double(i) / Double(bins.count - 1)) }
            }
            return 1
        }
        return RGB(percentile(red), percentile(green), percentile(blue))
    }

    /// Positive Dehaze, per dark-channel level d (0…1; the darkest channel of colour ÷ airlight, taken
    /// over a neighbourhood): `dehazeFloor` ÷ t, where the transmission t = max(floor, 1 − strength·d).
    /// Kept within 0…1 so it fits a lookup table; the renderer divides by the floor afterwards.
    public static func dehazeRatio(strength: Double) -> [Double] {
        table(count: 256) { d in dehazeFloor / Swift.max(dehazeFloor, 1 - strength * d) }
    }

    /// What the renderer computes for one pixel (sRGB levels): with `strength` > 0 the haze is taken
    /// out, J = A − (A − I) ÷ t; with `strength` < 0 haze is added, J = I·(1 − h) + A·h.
    public static func dehaze(_ pixel: RGB, darkChannel d: Double, airlight a: RGB, strength: Double) -> RGB {
        if strength < 0 {
            let h = hazeAdded(strength)
            return pixel * (1 - h) + a * h
        }
        let t = Swift.max(dehazeFloor, 1 - strength * d)
        return a - (a - pixel) * (1 / t)
    }

    /// Negative Dehaze: the share of airlight mixed in (strength −1 → 0.6).
    public static func hazeAdded(_ strength: Double) -> Double {
        0.6 * Swift.min(1, Swift.max(0, -strength))
    }
}
