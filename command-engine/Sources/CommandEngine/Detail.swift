import Foundation

/// Math for the Detail panel (sharpening, noise reduction, moiré, high pass) that the iPad renderer
/// turns into Core Image passes. Tested on Linux.
///
/// Detail sizes are in pixels of a 2048 px photo (the live preview) and grow in proportion on bigger
/// photos, so a saved photo looks like the preview; smaller pictures keep the 2048 px sizes.
public enum Detail {
    /// Pixels on this photo for a size given in pixels of a 2048 px photo.
    public static func pixels(_ size: Double, longSide: Double) -> Double {
        size * Swift.max(1, longSide / 2048)
    }

    /// Sharpening as two unsharp-mask passes: the main one at `radius`, and a finer one (half the
    /// radius) that Detail (0…1) turns up for fine texture. `amount` 0…1.5.
    public static func sharpening(amount: Double, detail: Double) -> (main: Double, fine: Double) {
        (amount * (0.6 + 0.4 * detail), amount * 0.6 * detail)
    }

    /// Sharpening Masking (0…1): where to sharpen, by the local brightness range around a pixel
    /// (sRGB levels). 0 sharpens everywhere; higher values keep flat areas (sky, skin) smooth.
    public static func sharpeningMask(masking: Double) -> [Double] {
        let edge = 0.2 * Swift.min(1, Swift.max(0, masking))
        return Effects.table(count: 64) { range in edge == 0 ? 1 : Effects.smoothstep(0.5 * edge, 1.5 * edge, range) }
    }

    // MARK: - Noise reduction

    /// Luminance noise reduction (`amount` 0…1): how much of a smoothed copy to use, by the local
    /// brightness range around a pixel. Flat and lightly textured areas are smoothed; strong edges
    /// stay. Higher amounts also smooth stronger texture.
    public static func noiseSmoothing(amount: Double) -> [Double] {
        let a = Swift.min(1, Swift.max(0, amount))
        return Effects.table(count: 64) { range in a * (1 - Effects.smoothstep(0.04 + 0.12 * a, 0.1 + 0.25 * a, range)) }
    }

    /// Blur radius (pixels of a 2048 px photo) for luminance and colour noise reduction (`amount` 0…1).
    public static func noiseRadius(amount: Double, color: Bool) -> Double {
        color ? 2 + 6 * amount : 0.8 + 1.5 * amount
    }
}
