import Foundation

/// Defringe: purple and green colour fringes along high-contrast edges (from the lens focusing red,
/// green and blue at slightly different distances) lose their colour. A colour cube on sRGB levels
/// greys out the chosen hue bands; the renderer uses it only near strong edges.
///
///     Defringe.apply(RGB(0.6, 0.2, 0.6), purple: 1, purpleHue: 290, green: 0, greenHue: 120)  → grey
public enum Defringe {
    /// Centre of the purple band (degrees) for Purple Fringe Hue 0…100 (50 → 290°, a magenta-violet).
    public static func purpleHue(_ slider: Double) -> Double {
        260 + 0.6 * slider
    }

    /// Centre of the green band for Green Fringe Hue 0…100 (50 → 120°, green).
    public static func greenHue(_ slider: Double) -> Double {
        75 + 0.9 * slider
    }

    /// One colour with the fringe colours taken out (towards the grey of the same luma). `purple`,
    /// `green`: amounts 0…1; a band reaches 20° each side of its centre fully, fading out by 40°.
    public static func apply(_ c: RGB, purple: Double, purpleHue: Double, green: Double, greenHue: Double) -> RGB {
        guard c.max - c.min > 0.001 else { return c }
        let hue = ColorLook.hsl(c).h
        func band(_ centre: Double) -> Double {
            1 - Effects.smoothstep(20, 40, abs(ColorLook.hueDifference(hue, centre)))
        }
        let weight = Swift.min(1, purple * band(purpleHue) + green * band(greenHue))
        return c.mixed(with: RGB(c.luma, c.luma, c.luma), weight)
    }

    /// The colour cube for the renderer: `size`³ RGBA floats, red changing fastest.
    public static func cube(purple: Double, purpleHue: Double, green: Double, greenHue: Double, size: Int = 33) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(size * size * size * 4)
        let n = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let c = apply(RGB(Double(r) / n, Double(g) / n, Double(b) / n), purple: purple, purpleHue: purpleHue,
                                  green: green, greenHue: greenHue)
                    out += [Float(c.r), Float(c.g), Float(c.b), 1]
                }
            }
        }
        return out
    }

    /// Where fringes can be: by the local brightness range around a pixel (sRGB levels), strong edges only.
    public static func edgeMask() -> [Double] {
        Effects.table(count: 64) { range in Effects.smoothstep(0.08, 0.22, range) }
    }
}
