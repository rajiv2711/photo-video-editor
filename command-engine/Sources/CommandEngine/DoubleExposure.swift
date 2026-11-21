import Foundation

/// Double exposure: photos laid on top of each other with a blend mode (the usual formulas, on sRGB
/// levels as in Photoshop), each new one by Blend Amount. Screen, the default, adds light as a second
/// exposure on the same film frame would.
public enum DoubleExposure {
    public enum Mode: String {
        case screen, multiply, overlay, softLight, lighten, darken, add, difference
    }

    /// "blendMode" option ids, in order; must match controls.json.
    public static let modes = ["screen", "multiply", "overlay", "softLight", "lighten", "darken", "add", "difference"]

    /// One level of `top` blended onto one level of `base` (both 0…1).
    public static func blend(_ a: Float, _ b: Float, mode: Mode) -> Float {
        switch mode {
        case .screen: return 1 - (1 - a) * (1 - b)
        case .multiply: return a * b
        case .overlay: return a < 0.5 ? 2 * a * b : 1 - 2 * (1 - a) * (1 - b)
        case .softLight:
            // The W3C (compositing spec) soft light.
            if b <= 0.5 { return a - (1 - 2 * b) * a * (1 - a) }
            let d = a <= 0.25 ? ((16 * a - 12) * a + 4) * a : sqrtf(a)
            return a + (2 * b - 1) * (d - a)
        case .lighten: return max(a, b)
        case .darken: return min(a, b)
        case .add: return min(1, a + b)
        case .difference: return abs(a - b)
        }
    }

    /// The photos (RGB on sRGB levels, one size) laid on the first one in order, each blended in by
    /// `amount` (0…1).
    public static func merge(_ photos: [FloatImage], mode: Mode, amount: Float) -> FloatImage {
        guard var out = photos.first else { return FloatImage(width: 0, height: 0, channels: 3) }
        let k = min(1, max(0, amount))
        for top in photos.dropFirst() where top.data.count == out.data.count {
            for i in out.data.indices {
                let a = out.data[i]
                out.data[i] = a + k * (blend(a, top.data[i], mode: mode) - a)
            }
        }
        return out
    }
}
