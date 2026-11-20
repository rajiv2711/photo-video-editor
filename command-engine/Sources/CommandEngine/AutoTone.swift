import Foundation

/// One-tap Auto. Reads the photo's brightness histogram and colour and returns `set` commands for
/// Exposure, Contrast, Highlights, Shadows, Whites and Blacks, then Temperature, Tint and Vibrance,
/// so the result shows on the sliders and stays editable.
///
///     AutoTone.commands(lumaHistogram: bins, averageColor: avg, meanChroma: 0.05)
///         → [{"op":"set","control":"exposure","value":-0.4}, …, {"op":"set","control":"vibrance","value":20}]
public enum AutoTone {
    /// The controls Auto sets, every time (so pressing Auto twice gives the same result).
    public static let controlIDs = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks",
                                    "temperature", "tint", "vibrance"]

    /// `lumaHistogram`: share of pixels per brightness bin (sRGB-encoded luma), darkest first.
    /// `averageColor`: the photo's average colour in linear light; a cast is taken out at 60 %
    /// strength (a sunset should stay warm). `meanChroma`: average of max − min channel per pixel on
    /// sRGB levels (0 grey … 1 pure colours); muted photos get some Vibrance.
    /// Without them, Temperature, Tint and Vibrance are set to 0.
    public static func commands(lumaHistogram: [Double], averageColor: RGB? = nil, meanChroma: Double? = nil) -> [Command] {
        let total = lumaHistogram.reduce(0, +)
        guard total > 0, lumaHistogram.count > 1 else { return [] }
        let bins = lumaHistogram.map { $0 / total }

        func percentile(_ p: Double) -> Double {
            var sum = 0.0
            for (i, share) in bins.enumerated() {
                sum += share
                if sum >= p { return (Double(i) + 0.5) / Double(bins.count) }
            }
            return 1
        }
        func share(below x: Double) -> Double {
            bins.enumerated().filter { (Double($0.offset) + 0.5) / Double(bins.count) < x }.reduce(0) { $0 + $1.element }
        }

        // Exposure: bring the median into 0.4…0.65 (sRGB), at 60 % strength, at most ±1.5 EV.
        let median = percentile(0.5)
        let target = Swift.min(Swift.max(median, 0.4), 0.65)
        var ev = 0.0
        if target != median {
            ev = 0.6 * log2(linear(target) / Swift.max(linear(median), 1e-4))
        }
        ev = Swift.min(Swift.max(ev, -1.5), 1.5)
        let gain = pow(2, ev)
        func shifted(_ x: Double) -> Double { encoded(linear(x) * gain) }

        // Whites / Blacks: stretch the brightest and darkest 0.5 % towards white and black.
        let hi = shifted(percentile(0.995)), lo = shifted(percentile(0.005))
        let whites = Swift.min(Swift.max((0.97 - hi) * 300, 0), 60)
        let blacks = -Swift.min(Swift.max((lo - 0.03) * 300, 0), 50)
        // Highlights: recover when many pixels are near white; Shadows: open up large dark areas.
        let highlights = -Swift.min(share(below: 2) - share(below: 0.95), 0.25) / 0.25 * 50
        let shadows = Swift.min(share(below: 0.12), 0.4) / 0.4 * 30
        // Contrast: add some when the tones sit in a narrow band.
        let spread = percentile(0.95) - percentile(0.05)
        let contrast = Swift.min(Swift.max((0.7 - spread) * 60, 0), 25)

        // Colour: take out most of a colour cast (grey-world guess), add vibrance to muted photos.
        var temperature = 0.0, tint = 0.0, vibrance = 0.0
        if let averageColor {
            let neutral = WhiteBalance.neutralize(averageColor)
            temperature = Swift.min(Swift.max(0.6 * neutral.temperature, -60), 60)
            tint = Swift.min(Swift.max(0.6 * neutral.tint, -40), 40)
        }
        if let meanChroma {
            vibrance = Swift.min(Swift.max((0.2 - meanChroma) / 0.2 * 25, 0), 25)
        }

        return [
            .set("exposure", round(ev, to: 0.05)),
            .set("contrast", round(contrast, to: 5)),
            .set("highlights", round(highlights, to: 5)),
            .set("shadows", round(shadows, to: 5)),
            .set("whites", round(whites, to: 5)),
            .set("blacks", round(blacks, to: 5)),
            .set("temperature", round(temperature, to: 1)),
            .set("tint", round(tint, to: 1)),
            .set("vibrance", round(vibrance, to: 5)),
        ]
    }

    static func round(_ value: Double, to step: Double) -> Double {
        let r = (value / step).rounded() * step
        let tidy = (r * 1_000_000).rounded() / 1_000_000
        return tidy == 0 ? 0 : tidy
    }

    /// sRGB level → linear light.
    static func linear(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    /// Linear light → sRGB level (clipped to 0…1).
    static func encoded(_ x: Double) -> Double {
        let c = Swift.min(Swift.max(x, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
