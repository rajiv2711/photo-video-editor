import Foundation

/// White balance math for the Color panel, shared by the iPad renderer and the Linux tests.
///
/// Everything is relative to the photo as shot (a JPEG is taken to be shot in 5500 K daylight).
/// Temperature is in mired (a step in mired looks the same anywhere on the scale): +100 makes the
/// photo as much warmer as if it had been lit by 18 000 K light instead of 5500 K; −100 as much
/// cooler as 3900 K. Tint +100 removes half a stop of green (magenta), −100 adds it.
/// A preset names the light the photo was taken in and adds its own temperature and tint.
///
///     WhiteBalance.gains(temperature: 20, tint: 0)   // linear-light multipliers for R, G, B
public enum WhiteBalance {
    /// Option ids of the White Balance choice, in controls.json order.
    public static let presetIDs = ["asShot", "auto", "daylight", "cloudy", "shade", "tungsten", "fluorescent", "flash"]

    /// The light each preset stands for (Lightroom's values; Flash as cameras set it).
    static let presetLights: [String: (kelvin: Double, tint: Double)] = [
        "daylight": (5500, 0), "cloudy": (6500, 0), "shade": (7500, 0), "tungsten": (2850, 0),
        "fluorescent": (3800, 21), "flash": (6000, 0),
    ]

    /// The light a JPEG is taken to be shot in.
    public static let referenceKelvin = 5500.0

    /// What a preset adds to the Temperature and Tint sliders. As Shot adds nothing; Auto is
    /// worked out from the photo by the renderer (`neutralize` on its average colour).
    public static func offset(preset: String) -> (temperature: Double, tint: Double) {
        guard let light = presetLights[preset] else { return (0, 0) }
        return (1e6 / referenceKelvin - 1e6 / light.kelvin, light.tint)
    }

    /// Linear-light multipliers for red, green and blue. Brightness (luma of white) stays the same.
    public static func gains(temperature: Double, tint: Double) -> RGB {
        let mired = Swift.min(Swift.max(1e6 / referenceKelvin - temperature, 40), 600)
        var g = white(kelvin: referenceKelvin) / white(kelvin: 1e6 / mired)
        g.g *= pow(2, -tint / 200)
        return g * (1 / g.luma)
    }

    /// The temperature and tint (slider units) that turn this linear-light colour neutral grey.
    /// Used by the white balance picker (a tapped spot) and Auto (the photo's average colour).
    public static func neutralize(_ color: RGB) -> (temperature: Double, tint: Double) {
        guard color.r > 0, color.g > 0, color.b > 0 else { return (0, 0) }
        // Warmer settings raise red against blue; find where red = blue.
        func redOverBlue(_ t: Double) -> Double {
            let c = color * gains(temperature: t, tint: 0)
            return c.r / c.b
        }
        var lo = 1e6 / referenceKelvin - 600, hi = 1e6 / referenceKelvin - 40
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if redOverBlue(mid) < 1 { lo = mid } else { hi = mid }
        }
        let temperature = (lo + hi) / 2
        let c = color * gains(temperature: temperature, tint: 0)
        let tint = -200 * log2(((c.r + c.b) / 2) / c.g)
        return (temperature, tint)
    }

    /// Linear sRGB colour of daylight / blackbody light at a colour temperature, green = 1.
    /// (Planckian locus approximation of Kim et al., valid for 1667…25 000 K.)
    static func white(kelvin: Double) -> RGB {
        let t = Swift.min(Swift.max(kelvin, 1667), 25000)
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        }
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        let X = x / y, Y = 1.0, Z = (1 - x - y) / y
        let rgb = RGB(3.2406 * X - 1.5372 * Y - 0.4986 * Z,
                      -0.9689 * X + 1.8758 * Y + 0.0415 * Z,
                      0.0557 * X - 0.2040 * Y + 1.0570 * Z)
        return rgb * (1 / rgb.g)
    }
}
