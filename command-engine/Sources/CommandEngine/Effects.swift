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
}
