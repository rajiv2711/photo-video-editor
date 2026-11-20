import Foundation

/// Colour tools that change each colour by its own rule (Color mixer, …), shared by the iPad
/// renderer and the Linux tests.
///
/// Together they become one 3D lookup table (a colour cube) that Core Image applies in a single
/// pass (CIColorCubeWithColorSpace) on sRGB-encoded levels, i.e. what the eye sees.
///
///     ColorLook.cube(value, size: 33)   // RGBA floats, red varying fastest
///
/// `value` returns a control's current value, or nil when the control isn't in controls.json
/// (it then counts as untouched).
public enum ColorLook {
    // MARK: - Controls

    /// Color mixer bands and the hue each is centred on (degrees).
    public static let mixerBands = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
    static let mixerHues: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]
    public static let mixerProperties = ["Hue", "Saturation", "Luminance"]

    /// "mixerRedHue", "mixerAquaLuminance", … (see controls.json).
    public static func mixerID(_ band: String, _ property: String) -> String {
        "mixer" + band.prefix(1).uppercased() + band.dropFirst() + property
    }

    /// Point color: the picked hue, the shifts for colours near it, and how near counts.
    public static let pointIDs = ["pointHue", "pointHueShift", "pointSaturationShift", "pointLuminanceShift", "pointRange",
                                  "pointVariance"]

    /// Color grading: a hue, saturation and luminance per tonal zone (and one for the whole photo).
    public static let gradingZones = ["Shadows", "Midtones", "Highlights", "Global"]
    public static let gradingIDs = gradingZones.flatMap { zone in mixerProperties.map { "grading" + zone + $0 } }
        + ["gradingBlending", "gradingBalance"]

    /// Control ids that feed the cube.
    public static let controlIDs: [String] = mixerBands.flatMap { band in mixerProperties.map { mixerID(band, $0) } }
        + pointIDs + gradingIDs

    /// Controls that only say how another control acts (which hue, how wide): on their own they
    /// change nothing, so they don't count when deciding whether the cube is needed.
    static let modifierIDs = Set(["pointHue", "pointRange", "gradingBlending", "gradingBalance"]
        + gradingZones.map { "grading" + $0 + "Hue" })

    /// The value of each control that leaves the picture untouched (or its default, for modifiers).
    public static func neutral(_ id: String) -> Double {
        switch id {
        case "pointRange", "gradingBlending": return 50
        default: return 0
        }
    }

    /// Whether every cube control is at its neutral value, so the cube can be skipped.
    public static func isIdentity(_ value: (String) -> Double?) -> Bool {
        controlIDs.allSatisfy { modifierIDs.contains($0) || (value($0) ?? neutral($0)) == neutral($0) }
    }

    /// The current values of the cube's controls.
    public struct Values {
        let values: [String: Double]

        public init(_ value: (String) -> Double?) {
            var snapshot: [String: Double] = [:]
            for id in ColorLook.controlIDs { snapshot[id] = value(id) ?? ColorLook.neutral(id) }
            values = snapshot
        }

        subscript(_ id: String) -> Double { values[id] ?? ColorLook.neutral(id) }
    }

    // MARK: - The cube

    /// The lookup table for the current values: size³ RGBA entries (alpha 1), red varying fastest,
    /// then green, then blue, inputs and outputs on sRGB levels 0…1.
    public static func cube(_ value: (String) -> Double?, size: Int = 33) -> [Float] {
        let v = Values(value)
        var out: [Float] = []
        out.reserveCapacity(size * size * size * 4)
        let n = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let c = transform(RGB(Double(r) / n, Double(g) / n, Double(b) / n), v).clamped()
                    out += [Float(c.r), Float(c.g), Float(c.b), 1]
                }
            }
        }
        return out
    }

    /// Every cube step, in order, for one colour (sRGB levels).
    public static func transform(_ color: RGB, _ v: Values) -> RGB {
        var c = mixer(color, v)
        c = pointColor(c, v)
        c = grading(c, v)
        return c
    }

    // MARK: - Color mixer

    /// Hue, saturation and luminance per colour band. Each colour belongs to its two nearest bands
    /// (by hue). Hue ±100 turns it by up to 30°; Saturation −100 makes it grey, +100 doubles it;
    /// Luminance ±100 moves it halfway to white or black. Greys are left alone.
    static func mixer(_ color: RGB, _ v: Values) -> RGB {
        let chroma = color.max - color.min
        guard chroma > 1e-6 else { return color }
        var (h, s, l) = hsl(color)
        var dh = 0.0, ds = 0.0, dl = 0.0
        for (band, w) in bandWeights(hue: h) {
            dh += w * v[mixerID(band, "Hue")] / 100 * 30
            ds += w * v[mixerID(band, "Saturation")] / 100
            dl += w * v[mixerID(band, "Luminance")] / 100
        }
        if dh == 0 && ds == 0 && dl == 0 { return color }
        h += dh
        s = Swift.min(Swift.max(s * (1 + ds), 0), 1)
        // Luminance acts on clearly coloured pixels; near-greys barely move.
        dl *= smoothstep(0, 0.25, chroma) * 0.5
        l = dl > 0 ? l + (1 - l) * dl : l * (1 + dl)
        return rgb(hue: h, saturation: s, lightness: l)
    }

    /// The two mixer bands a hue sits between and how much it belongs to each (they add up to 1).
    static func bandWeights(hue: Double) -> [(String, Double)] {
        let h = wrap(hue)
        for i in mixerHues.indices {
            let lo = mixerHues[i]
            let hi = i + 1 < mixerHues.count ? mixerHues[i + 1] : 360
            if h >= lo && h < hi {
                let t = (h - lo) / (hi - lo)
                return [(mixerBands[i], 1 - t), (mixerBands[(i + 1) % mixerBands.count], t)]
            }
        }
        return [(mixerBands[0], 1)]
    }

    // MARK: - Point color

    /// Shifts the colours close to one picked hue. Point Range 0…100 sets how close: up to 10°…60°
    /// away (35° by default), fading out towards the edge; greys are never picked.
    /// Variance first evens out (−100: every picked colour takes the target hue) or spreads (+100:
    /// twice as far from it) the hues; then the shifts act as in the Color mixer: hue up to 30°,
    /// saturation to grey or double, luminance halfway.
    static func pointColor(_ color: RGB, _ v: Values) -> RGB {
        let hueShift = v["pointHueShift"], satShift = v["pointSaturationShift"], lumShift = v["pointLuminanceShift"]
        let variance = v["pointVariance"]
        guard hueShift != 0 || satShift != 0 || lumShift != 0 || variance != 0 else { return color }
        let w = pointWeight(color, v)
        guard w > 0 else { return color }
        var (h, s, l) = hsl(color)
        h += hueDifference(h, v["pointHue"]) * w * variance / 100
        h += w * hueShift / 100 * 30
        s = Swift.min(Swift.max(s * (1 + w * satShift / 100), 0), 1)
        let dl = w * lumShift / 100 * 0.5
        l = dl > 0 ? l + (1 - l) * dl : l * (1 + dl)
        return rgb(hue: h, saturation: s, lightness: l)
    }

    /// How much a colour belongs to the picked one (0…1).
    static func pointWeight(_ color: RGB, _ v: Values) -> Double {
        let chroma = color.max - color.min
        guard chroma > 1e-6 else { return 0 }
        let width = 10 + v["pointRange"] / 100 * 50
        let distance = abs(hueDifference(hsl(color).h, v["pointHue"]))
        guard distance < width else { return 0 }
        return smoothstep(0, 1, 1 - distance / width) * smoothstep(0.02, 0.12, chroma)
    }

    /// The hue to pick from a tapped colour (linear light), or nil for a grey with no clear hue.
    public static func pickedHue(linear color: RGB) -> Double? {
        let c = color.encoded
        guard c.max - c.min > 0.04 else { return nil }
        return hsl(c).h
    }

    /// a − b as an angle in −180…180.
    static func hueDifference(_ a: Double, _ b: Double) -> Double {
        let d = wrap(a - b)
        return d > 180 ? d - 360 : d
    }

    // MARK: - Color grading

    /// Tints and brightens shadows, midtones and highlights (by the pixel's luma), plus the whole
    /// photo. Saturation 100 adds a colour of that hue worth a quarter of the level range;
    /// Luminance ±100 moves the zone's levels by ±0.15. Balance −100…100 hands more of the tones to
    /// the shadows or the highlights; Blending 0…100 makes the zones overlap less or more.
    static func grading(_ color: RGB, _ v: Values) -> RGB {
        let y = color.luma
        let shifted = Swift.min(Swift.max(y + 0.25 * v["gradingBalance"] / 100, 0), 1)
        let e = pow(4, (50 - v["gradingBlending"]) / 50)
        let shadows = pow(Swift.min(Swift.max(1 - 2 * shifted, 0), 1), e)
        let highlights = pow(Swift.min(Swift.max(2 * shifted - 1, 0), 1), e)
        let weights = ["Shadows": shadows, "Midtones": 1 - shadows - highlights, "Highlights": highlights, "Global": 1]
        var out = color
        for zone in gradingZones {
            let w = weights[zone] ?? 0
            let sat = v["grading" + zone + "Saturation"], lum = v["grading" + zone + "Luminance"]
            guard w > 0, sat != 0 || lum != 0 else { continue }
            out = out + tintDirection(hue: v["grading" + zone + "Hue"]) * (w * sat / 100 * 0.25)
            out = out + RGB(1, 1, 1) * (w * lum / 100 * 0.15)
        }
        return out
    }

    /// The pure colour of a hue with its luma taken out: adding it tints without brightening.
    static func tintDirection(hue: Double) -> RGB {
        let c = rgb(hue: hue, saturation: 1, lightness: 0.5)
        return c - RGB(1, 1, 1) * c.luma
    }

    // MARK: - Colour helpers

    /// Hue (degrees 0…360), saturation and lightness (0…1) of an RGB colour.
    public static func hsl(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let mx = c.max, mn = c.min
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 1e-9 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if mx == c.r {
            h = (c.g - c.b) / d
        } else if mx == c.g {
            h = (c.b - c.r) / d + 2
        } else {
            h = (c.r - c.g) / d + 4
        }
        return (wrap(h * 60), Swift.min(s, 1), l)
    }

    /// The RGB colour for a hue (degrees), saturation and lightness (0…1).
    public static func rgb(hue: Double, saturation s: Double, lightness l: Double) -> RGB {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = wrap(hue) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGB(r + m, g + m, b + m)
    }

    /// An angle in 0..<360.
    static func wrap(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// 0 below `lo`, 1 above `hi`, a smooth S in between.
    static func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
        let t = Swift.min(Swift.max((x - lo) / (hi - lo), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
