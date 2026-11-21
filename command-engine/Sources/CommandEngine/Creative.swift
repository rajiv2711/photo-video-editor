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
    public static let centered: Set<String> = ["zoomBlur", "spinBlur", "tiltShift", "irisBlur", "fieldBlur"]

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

    // MARK: - Tilt-shift, iris and field blur

    /// The selective-focus blurs: a sharp band (tilt-shift, the miniature look), a sharp circle (iris)
    /// or sharp below a line and more and more blurred above it (field).
    public enum FocusBlur {
        case tiltShift, iris, field
    }

    /// Their largest blur radius (pixels): up to 3 % of the long side.
    public static func focusBlurRadius(_ amount: Double, longSide: Double) -> Double {
        max(0, amount) / 100 * 0.03 * longSide
    }

    /// How much of the blur each cell of a `width` × `height` grid gets (0 sharp … 1 full), row by row
    /// from the top. The sharp area is around `center` (0…1 from the top-left); `size` is Effect Size
    /// (0…1) and `angle` Effect Angle (degrees, anticlockwise; 0 = a level band, blur rising upwards).
    /// With L the grid's long side: tilt-shift is sharp within 0.2 × size × L of the line through the
    /// centre and fully blurred at 3 × that; iris is sharp within 0.5 × size × L of the centre and fully
    /// blurred at twice that; field is sharp on and below the line and fully blurred size × L above it.
    /// The changes follow a smoothstep, so the edges of the sharp area don't show.
    public static func focusMask(_ kind: FocusBlur, width: Int, height: Int, center: MaskPoint, size: Double, angle: Double) -> [Float] {
        let long = Double(max(width, height))
        let s = min(max(size, 0.01), 1)
        let theta = angle * .pi / 180
        // The line's normal, pointing down when it is level (y counts down).
        let nx = sin(theta), ny = cos(theta)
        let cx = center.x * Double(width), cy = center.y * Double(height)
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let t: Double
                switch kind {
                case .tiltShift:
                    let w = 0.2 * s * long
                    t = (abs(dx * nx + dy * ny) - w) / (2 * w)
                case .iris:
                    let w = 0.5 * s * long
                    t = ((dx * dx + dy * dy).squareRoot() - w) / w
                case .field:
                    t = -(dx * nx + dy * ny) / (s * long)
                }
                let c = min(max(t, 0), 1)
                out[y * width + x] = Float(c * c * (3 - 2 * c))
            }
        }
        return out
    }
}
