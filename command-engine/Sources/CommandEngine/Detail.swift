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

    // MARK: - Moiré

    /// Moiré removal (`amount` 0…1): how much new colour to use, by how fast the colourfulness
    /// changes around a pixel (local range of max − min channel, softened). Busy coloured patterns
    /// get it; plain areas keep their colour.
    public static func moireMask(amount: Double) -> [Double] {
        let a = Swift.min(1, Swift.max(0, amount))
        return Effects.table(count: 64) { range in a * Effects.smoothstep(0.03, 0.12, range) }
    }

    /// Blur radius (pixels of a 2048 px photo) for the colour that replaces moiré.
    public static func moireRadius(amount: Double) -> Double {
        4 + 8 * amount
    }

    // MARK: - High pass

    /// High pass (`amount` 0…1): how far the edge-detail layer (picture − blurred picture, around
    /// mid-grey) is stretched before it is overlaid on the picture. 0.5 is the usual 100 % overlay.
    public static func highPassContrast(amount: Double) -> Double {
        2 * Swift.min(1, Swift.max(0, amount))
    }

    /// What overlaying the layer does to one level `x` (sRGB) with edge detail `d` (picture − blurred):
    /// x + 2·min(x, 1 − x)·k·d, so black and white can't clip.
    public static func highPass(_ x: Double, detail d: Double, amount: Double) -> Double {
        let layer = 0.5 + highPassContrast(amount: amount) * d
        return x < 0.5 ? 2 * x * layer : 1 - 2 * (1 - x) * (1 - layer)
    }
}
