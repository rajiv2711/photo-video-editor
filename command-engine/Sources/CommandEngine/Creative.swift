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
    public static let centered: Set<String> = ["zoomBlur", "spinBlur", "tiltShift", "irisBlur", "fieldBlur",
                                               "twirl", "ripple", "pinch", "spherize"]

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

    // MARK: - Distort

    /// Twirl, Pinch and Spherize work inside a circle of Effect Size × the long side around the centre.
    public static func distortRadius(size: Double, longSide: Double) -> Double {
        max(0.05, size) * longSide
    }

    /// Wave: the picture shifted sideways along sine waves, up to 3 % of the long side, a wave every
    /// half Effect Size × long side.
    public static func wave(_ amount: Double, size: Double, longSide: Double) -> (amplitude: Double, wavelength: Double) {
        (max(0, amount) / 100 * 0.03 * longSide, max(0.05, size) * 0.5 * longSide)
    }

    /// Ripple: rings around the centre, up to 1.5 % of the long side deep, a ring every quarter Effect
    /// Size × long side.
    public static func ripple(_ amount: Double, size: Double, longSide: Double) -> (amplitude: Double, wavelength: Double) {
        (max(0, amount) / 100 * 0.015 * longSide, max(0.05, size) * 0.25 * longSide)
    }

    /// Pinch's power k (−0.8…0.8): positive pulls the middle in, negative bulges it.
    public static func pinchPower(_ amount: Double) -> Double {
        min(max(amount, -100), 100) / 100 * 0.8
    }

    /// The point a pixel at `d` from the centre reads (also from the centre), for Pinch: inside the
    /// circle of `radius` it reads d × sin(π/2 × r)^−k (r = |d| ÷ radius), so with k > 0 the picture
    /// is pulled in towards the middle, with k < 0 it swells; outside nothing moves. The renderer's
    /// kernel does the same on the GPU.
    public static func pinchSource(_ d: Vec2, radius: Double, power k: Double) -> Vec2 {
        let r = min(max(d.length / radius, 0.0001), 1)
        return d * pow(sin(.pi / 2 * r), -k)
    }

    /// Spherize: the picture wrapped round a ball (positive: the middle swells, the rim squeezes; at
    /// amount 1 a pixel at r reads 2/π × asin(r)) or the other way (negative: sin(π/2 × r)), mixed with
    /// the picture as it is by |amount| (−1…1). Outside the circle nothing moves.
    public static func spherizeSource(_ d: Vec2, radius: Double, amount: Double) -> Vec2 {
        let r = d.length / radius
        guard r < 1, r > 0 else { return d }
        let k = min(max(amount, -1), 1)
        let target = k > 0 ? 2 / .pi * asin(r) : sin(.pi / 2 * r)
        let s = r + (target - r) * abs(k)
        return d * (s / r)
    }

    /// Polar Coordinates (the "tiny planet"): around the centre, the picture's bottom edge shrinks to
    /// the middle and its top edge becomes the outer circle (through the corners); going round the
    /// middle, from straight down clockwise, crosses the picture from left to right. `d` is from the
    /// centre with y down, in pixels of a `width` × `height` picture; the result is a point on the
    /// picture from its top-left.
    public static func polarSource(_ d: Vec2, width: Double, height: Double) -> Vec2 {
        let rim = 0.5 * (width * width + height * height).squareRoot()
        let r = min(d.length / rim, 1)
        // 0 straight down, growing clockwise on the screen (towards the left first).
        let a = atan2(-d.x, d.y)
        return Vec2((a / (2 * .pi) + 0.5) * width, (1 - r) * height)
    }

    // MARK: - Stylize

    /// Oil Paint's brush (the Kuwahara filter's reach, pixels): up to 1 % of the long side.
    public static func oilRadius(_ amount: Double, longSide: Double) -> Double {
        max(0, amount) / 100 * 0.01 * longSide
    }

    /// Emboss: how far apart the two samples of the relief are (pixels, 0.2 % of the long side, at
    /// least 1) and how steep the relief is (× the brightness difference, up to 8).
    public static func emboss(_ amount: Double, longSide: Double) -> (offset: Double, height: Double) {
        (max(1, 0.002 * longSide), max(0, amount) / 100 * 8)
    }

    /// Emboss's light comes from the top-left, turned by Effect Angle (degrees, anticlockwise).
    public static func embossLightAngle(_ effectAngle: Double) -> Double {
        135 + effectAngle
    }

    /// Find Edges looks this far to each side (pixels, 0.12 % of the long side, at least 1).
    public static func edgeOffset(longSide: Double) -> Double {
        max(1, 0.0012 * longSide)
    }

    /// Wind: the longest streak (pixels, up to 8 % of the long side) and the height of the bands
    /// whose streaks differ in length (0.12 % of the long side, at least 1 pixel).
    public static func wind(_ amount: Double, longSide: Double) -> (length: Double, band: Double) {
        (max(0, amount) / 100 * 0.08 * longSide, max(1, 0.0012 * longSide))
    }
}
