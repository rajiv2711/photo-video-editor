import Foundation

/// The Creative panel: blur, tilt-shift, distort, stylize, pixelate and artistic filters, lens flare,
/// lighting, film effects and frames. No AI: every filter is classical image processing.
///
/// Every filter is its own slider, 0 = off; naming it alone turns it on at a moderate strength
/// (`Control.on`: "zoom blur"). Several can be on at once: they run in a fixed order (distort → blur →
/// tilt-shift → stylize → artistic → pixelate → lighting → lens flare → film), after the crop and
/// before the post-crop vignette and grain, so they see the picture as framed. Frames come last,
/// drawn over the finished picture's edge.
///
/// Filters that work around a point share the Placement section: Effect Center X and Y (% of the
/// picture from its top-left), Effect Size and Effect Angle. "place center", then a tap, moves the centre.
public enum CreativeFilters {
    /// The action that arms a tap on the photo to place the Effect Center.
    public static let centerPicker = "placeCenter"

    /// Filters that work around the Effect Center: turning one on by name lets the next tap place it.
    public static let centered: Set<String> = ["zoomBlur", "spinBlur"]

    /// The Effect Center on the picture (0…1 from the top-left).
    public static func center(value: (String) -> Double?) -> MaskPoint {
        MaskPoint((value("effectCenterX") ?? 50) / 100, (value("effectCenterY") ?? 50) / 100)
    }

    /// The Effect Center for a tap on the shown picture (0…1 from the top-left), as percentages rounded
    /// to whole numbers.
    public static func centerValues(_ p: MaskPoint) -> (x: Double, y: Double) {
        ((min(max(p.x, 0), 1) * 100).rounded(), (min(max(p.y, 0), 1) * 100).rounded())
    }

    // MARK: - Blur

    /// Gaussian Blur's radius (sigma, pixels): up to 4 % of the long side.
    public static func gaussianRadius(_ amount: Double, longSide: Double) -> Double {
        max(0, amount) / 100 * 0.04 * longSide
    }

    /// Motion Blur's length (pixels): up to 6 % of the long side.
    public static func motionLength(_ amount: Double, longSide: Double) -> Double {
        max(0, amount) / 100 * 0.06 * longSide
    }

    /// Zoom Blur's streak length at the edges (pixels): up to 8 % of the long side.
    public static func zoomLength(_ amount: Double, longSide: Double) -> Double {
        max(0, amount) / 100 * 0.08 * longSide
    }

    /// Spin Blur's whole arc (radians): up to 24°.
    public static func spinAngle(_ amount: Double) -> Double {
        max(0, amount) / 100 * 24 * .pi / 180
    }
}
