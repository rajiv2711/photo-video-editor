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

    /// Control ids that feed the cube; when all are at their neutral value the cube is skipped.
    public static let controlIDs: [String] = mixerBands.flatMap { band in mixerProperties.map { mixerID(band, $0) } }

    /// The value of each control that leaves the picture untouched.
    public static func neutral(_ id: String) -> Double {
        0
    }

    /// Whether every cube control is at its neutral value, so the cube can be skipped.
    public static func isIdentity(_ value: (String) -> Double?) -> Bool {
        controlIDs.allSatisfy { (value($0) ?? neutral($0)) == neutral($0) }
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
        mixer(color, v)
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
