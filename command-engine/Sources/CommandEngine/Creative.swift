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
                                               "twirl", "ripple", "pinch", "spherize", "lensFlare", "spotlight", "omniLight"]

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

    /// Zoom Blur's strength (Core Image's zoom amount, pixels): up to 2.5 % of the long side (its
    /// streaks grow with the distance from the centre, to several times that at the edges).
    public static func zoomLength(_ amount: Double, longSide: Double) -> Double {
        max(0, amount) / 100 * 0.025 * longSide
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

    // MARK: - Pixelate

    /// Mosaic's square cells (pixels): up to 8 % of the long side ("mosaic 12": about 1 %).
    public static func mosaicCell(_ amount: Double, longSide: Double) -> Double {
        max(0, amount) / 100 * 0.08 * longSide
    }

    /// Crystallize's cells (their radius, pixels): up to 6 % of the long side.
    public static func crystalRadius(_ amount: Double, longSide: Double) -> Double {
        max(0, amount) / 100 * 0.06 * longSide
    }

    /// Halftone's dot spacing (pixels): up to 4 % of the long side.
    public static func halftoneSpacing(_ amount: Double, longSide: Double) -> Double {
        max(0, amount) / 100 * 0.04 * longSide
    }

    // MARK: - Artistic

    /// Watercolor's and Cartoon's smoothing (the Kuwahara filter's reach, pixels): up to 0.8 % of the
    /// long side; Cutout's: up to 1.2 %.
    public static func paintRadius(_ amount: Double, longSide: Double, cutout: Bool = false) -> Double {
        max(0, amount) / 100 * (cutout ? 0.012 : 0.008) * longSide
    }

    /// Cutout's number of flat tones: 8 at the lowest amount, down to 3 at 100.
    public static func cutoutLevels(_ amount: Double) -> Int {
        min(8, max(3, Int((8 - 5 * amount / 100).rounded())))
    }

    /// Sketch: how wide the pencil strokes are (the blur of the inverted picture, pixels: 0.2 % to
    /// 0.8 % of the long side) and how dark (each level raised to the power 1 + 2 × amount).
    public static func sketchStroke(_ amount: Double, longSide: Double) -> Double {
        (0.002 + 0.006 * min(max(amount, 0), 100) / 100) * longSide
    }

    /// Sketch's darkening: output levels for 256 evenly spaced inputs (0…1).
    public static func sketchTable(_ amount: Double) -> [Double] {
        let p = 1 + 2 * min(max(amount, 0), 100) / 100
        return (0..<256).map { pow(Double($0) / 255, p) }
    }

    /// Cartoon, Cutout and Watercolor: `levels` flat tones placed by the picture's own brightness, half
    /// by how many pixels hold each level and half evenly, so a dark subject on a light background still
    /// keeps a few tones of its own. `histogram`: pixel counts of sRGB luma in equal bins over 0…1.
    /// Returns output levels for 256 evenly spaced inputs: each the mean luma of its band.
    public static func toneBands(histogram: [Double], levels: Int) -> [Double] {
        let bins = histogram.count
        let total = histogram.reduce(0, +)
        guard bins > 0, total > 0, levels > 1 else { return (0..<256).map { Double($0) / 255 } }
        var band = [Int](repeating: 0, count: bins)
        var before = 0.0
        for i in 0..<bins {
            let position = 0.5 * (before + histogram[i] / 2) / total + 0.5 * (Double(i) + 0.5) / Double(bins)
            band[i] = min(levels - 1, Int(position * Double(levels)))
            before += histogram[i]
        }
        // Each band's mean level (or its middle when no pixel falls in it).
        var sums = [Double](repeating: 0, count: levels), counts = [Double](repeating: 0, count: levels)
        var lows = [Double](repeating: 1, count: levels), highs = [Double](repeating: 0, count: levels)
        for i in 0..<bins {
            let centre = (Double(i) + 0.5) / Double(bins)
            sums[band[i]] += histogram[i] * centre
            counts[band[i]] += histogram[i]
            lows[band[i]] = min(lows[band[i]], centre)
            highs[band[i]] = max(highs[band[i]], centre)
        }
        let means = (0..<levels).map { counts[$0] > 0 ? sums[$0] / counts[$0] : (lows[$0] + highs[$0]) / 2 }
        return (0..<256).map { j in
            means[band[min(bins - 1, Int(Double(j) / 256 * Double(bins)))]]
        }
    }

    // MARK: - Lens flare

    /// Lens Flare's size (pixels): the glow's reach, half Effect Size × the long side; its halo ring
    /// lies at 1.2 × that.
    public static func flareSize(size: Double, longSide: Double) -> Double {
        max(0.05, size) * 0.5 * longSide
    }

    /// Lens Flare's brightness (× the flare's light, screened onto the picture): up to 1.2.
    public static func flareStrength(_ amount: Double) -> Double {
        max(0, amount) / 100 * 1.2
    }

    /// Where the flare's ghosts sit: along the line from the light (`source`) through the picture's
    /// middle, at these shares of the way (1 = the middle, 2 = as far past it), with their radius (×
    /// the flare's size), colour and strength. A light in the very middle sends them along the diagonal.
    public static let flareGhosts: [(at: Double, radius: Double, color: RGB, strength: Double)] = [
        (0.4, 0.15, RGB(0.6, 0.8, 1.0), 0.15),
        (0.8, 0.08, RGB(1.0, 0.7, 0.4), 0.2),
        (1.25, 0.3, RGB(0.5, 1.0, 0.6), 0.08),
        (1.6, 0.12, RGB(0.8, 0.6, 1.0), 0.15),
        (2.1, 0.45, RGB(0.5, 0.7, 1.0), 0.07),
    ]

    /// The line the ghosts run along (pixels, y down): from the light to the picture's middle, or down
    /// and to the right when the light is (almost) in the middle.
    public static func flareAxis(source: Vec2, middle: Vec2, size: Double) -> Vec2 {
        let axis = middle - source
        return axis.length < 0.1 * size ? Vec2(1.4 * size, 1.4 * size) : axis
    }

    // MARK: - Lighting

    /// A light's pool on the picture: `radius` (pixels) across, `stretch` × that along its beam, the
    /// end towards the light `hot` brighter, everything else dimmed to `ambient` and the middle of the
    /// pool brightened by `boost` (gains in linear light).
    public struct LightPool: Equatable {
        public let radius: Double
        public let stretch: Double
        public let hot: Double
        public let ambient: Double
        public let boost: Double
    }

    /// Spotlight (an oval pool, brighter towards the light) or Omni Light (a round pool around the
    /// Effect Center) at `amount` (0…100): the rest dims by up to 70 %, the pool brightens by up to 40 %;
    /// its radius is Effect Size × the long side.
    public static func lightPool(_ amount: Double, size: Double, longSide: Double, spot: Bool) -> LightPool {
        let a = min(max(amount, 0), 100) / 100
        return LightPool(radius: max(0.05, size) * longSide, stretch: spot ? 1.8 : 1, hot: spot ? 0.3 : 0,
                         ambient: 1 - 0.7 * a, boost: 0.4 * a)
    }

    /// The light's gain at `d` from the Effect Center, `beam` the unit direction the light shines
    /// along (any coordinates, as long as both agree). The renderer's kernel does the same.
    public static func lightGain(_ d: Vec2, beam: Vec2, pool: LightPool) -> Double {
        let along = (d.x * beam.x + d.y * beam.y) / (pool.radius * pool.stretch)
        let across = (d.y * beam.x - d.x * beam.y) / pool.radius
        let inPool = exp(-2 * (along * along + across * across)) * (1 + pool.hot * min(max(-along, -1), 1))
        return pool.ambient + (1 + pool.boost - pool.ambient) * inPool
    }

    // MARK: - Film effects

    /// Light Leak's glows, the same every time: centre (0…1 from the top-left, may lie just off the
    /// picture), radius (× the long side), colour and strength. Warm light bleeding in from the left
    /// edge and a little at the top-right corner, as from a camera back that doesn't quite close.
    public static let lightLeaks: [(x: Double, y: Double, radius: Double, color: RGB, strength: Double)] = [
        (-0.05, 0.35, 0.45, RGB(1.0, 0.45, 0.1), 0.9),
        (0.0, 0.8, 0.3, RGB(1.0, 0.2, 0.12), 0.7),
        (0.1, 0.05, 0.25, RGB(1.0, 0.85, 0.4), 0.6),
        (1.05, 0.1, 0.3, RGB(1.0, 0.35, 0.5), 0.5),
    ]

    /// Light Leak's strength (× the glows, screened on): up to 1.
    public static func leakStrength(_ amount: Double) -> Double {
        min(max(amount, 0), 100) / 100
    }

    /// A speck of dust, or one dot of a hair: where (0…1 from the top-left), how big (radius × the long
    /// side), how strong (0…1), and whether it is light (a hole in the emulsion) or dark (dirt).
    public struct Speck: Equatable {
        public let x: Double
        public let y: Double
        public let radius: Double
        public let opacity: Double
        public let light: Bool
    }

    /// A scratch along the film: a thin light line from `top` to `bottom` (0…1) at `x`.
    public struct Scratch: Equatable {
        public let x: Double
        public let top: Double
        public let bottom: Double
        public let width: Double
        public let opacity: Double
    }

    /// Dust and Scratches, the same every time (a fixed seed): up to 60 specks, 6 hairs (curling chains
    /// of small dark dots) and 5 scratches. `amount` (0…100) shows a matching share of them and makes
    /// them stronger.
    public static func dustAndScratches(_ amount: Double) -> (specks: [Speck], hairs: [[Speck]], scratches: [Scratch]) {
        let a = min(max(amount, 0), 100) / 100
        guard a > 0 else { return ([], [], []) }
        var random = SplitMix(seed: 1977)
        let strength = 0.5 + 0.5 * a
        var specks: [Speck] = []
        for _ in 0..<60 {
            let speck = Speck(x: random.next(), y: random.next(), radius: 0.001 + 0.003 * random.next() * random.next(),
                              opacity: (0.5 + 0.5 * random.next()) * strength, light: random.next() < 0.25)
            specks.append(speck)
        }
        var hairs: [[Speck]] = []
        for _ in 0..<6 {
            var x = random.next(), y = random.next()
            var heading = random.next() * 2 * .pi
            let opacity = (0.6 + 0.4 * random.next()) * strength
            var dots: [Speck] = []
            for _ in 0..<16 {
                dots.append(Speck(x: x, y: y, radius: 0.0007, opacity: opacity, light: false))
                heading += (random.next() - 0.5) * 0.9
                x += cos(heading) * 0.004
                y += sin(heading) * 0.004
            }
            hairs.append(dots)
        }
        var scratches: [Scratch] = []
        for _ in 0..<5 {
            let top = random.next() * 0.5
            scratches.append(Scratch(x: 0.05 + 0.9 * random.next(), top: top, bottom: min(1, top + 0.3 + 0.7 * random.next()),
                                     width: 0.0006 + 0.0006 * random.next(), opacity: (0.4 + 0.4 * random.next()) * strength))
        }
        let count = { (n: Int) in Int((Double(n) * a).rounded(.up)) }
        return (Array(specks.prefix(count(60))), Array(hairs.prefix(count(6))), Array(scratches.prefix(count(5))))
    }
}

/// A small repeatable random number generator (SplitMix64): the same numbers on every device.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// The next number in 0…1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
