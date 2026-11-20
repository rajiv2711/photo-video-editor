import Foundation

/// Tone math for the Light panel, shared by the iPad renderer and the Linux tests.
///
/// The global tone controls (Highlights brightening, Whites, Blacks, Brightness, tone curve, Fade) become one
/// lookup table per colour channel, applied in a single Core Image pass (CIColorCurves). Inputs and
/// outputs are sRGB-encoded levels (0 = black, 1 = SDR white), i.e. what the eye sees.
///
///     ToneCurve.table(value).red[i]   // output for input i / (size - 1) * maxInput
///
/// `value` returns a control's current value, or nil when the control isn't in controls.json
/// (it then counts as untouched).
public enum ToneCurve {
    /// One lookup table per channel, sampled at `size` evenly spaced inputs over 0…maxInput.
    public struct Table: Equatable {
        public let maxInput: Double
        public var red: [Double]
        public var green: [Double]
        public var blue: [Double]

        /// Interleaved RGB floats, the layout CIColorCurves expects.
        public var interleaved: [Float] {
            var out: [Float] = []
            out.reserveCapacity(red.count * 3)
            for i in red.indices {
                out += [Float(red[i]), Float(green[i]), Float(blue[i])]
            }
            return out
        }

        /// Output of one channel's table for an input level (linear interpolation between samples).
        public func lookup(_ x: Double, channel: [Double]) -> Double {
            let t = Swift.min(Swift.max(x / maxInput, 0), 1) * Double(channel.count - 1)
            let i = Swift.min(Int(t), channel.count - 2)
            return channel[i] + (channel[i + 1] - channel[i]) * (t - Double(i))
        }
    }

    /// Control ids that feed the table; when all are at their default the table is skipped.
    public static let controlIDs: [String] = [
        "highlights", "whites", "blacks", "brightness", "fade",
        "curveHighlights", "curveLights", "curveDarks", "curveShadows",
    ]

    /// The value of each tone control that leaves the picture untouched.
    public static func neutral(_ id: String) -> Double {
        0
    }

    /// Whether every tone control is at its neutral value, so the table can be skipped.
    public static func isIdentity(_ value: (String) -> Double?) -> Bool {
        controlIDs.allSatisfy { (value($0) ?? neutral($0)) == neutral($0) }
    }

    /// The tone lookup tables for the current control values. `maxInput` above 1 keeps HDR levels
    /// brighter than white: above 1 the curve continues with slope 1.
    public static func table(_ value: (String) -> Double?, size: Int = 1024, maxInput: Double = 1) -> Table {
        var snapshot: [String: Double] = [:]
        for id in controlIDs { snapshot[id] = value(id) ?? neutral(id) }
        let v = Values(values: snapshot)
        var red: [Double] = [], green: [Double] = [], blue: [Double] = []
        let top = v.channels(1)
        for i in 0..<size {
            let x = Double(i) / Double(size - 1) * maxInput
            let y: (Double, Double, Double)
            if x <= 1 {
                y = v.channels(x)
            } else {
                y = (top.0 + x - 1, top.1 + x - 1, top.2 + x - 1)
            }
            red.append(Swift.min(Swift.max(y.0, 0), maxInput))
            green.append(Swift.min(Swift.max(y.1, 0), maxInput))
            blue.append(Swift.min(Swift.max(y.2, 0), maxInput))
        }
        return Table(maxInput: maxInput, red: monotone(red), green: monotone(green), blue: monotone(blue))
    }

    /// Smooth curve through points (monotone cubic, so it never overshoots between points).
    /// `xs` must be increasing.
    public static func spline(xs: [Double], ys: [Double], at x: Double) -> Double {
        let n = xs.count
        guard n > 1 else { return ys.first ?? x }
        if x <= xs[0] { return ys[0] }
        if x >= xs[n - 1] { return ys[n - 1] }
        var slopes = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { slopes[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
        // Fritsch–Carlson tangents.
        var m = [Double](repeating: 0, count: n)
        m[0] = slopes[0]
        m[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            m[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<(n - 1) where slopes[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<(n - 1) where slopes[i] != 0 {
            let a = m[i] / slopes[i], b = m[i + 1] / slopes[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * slopes[i]
                m[i + 1] = t * b * slopes[i]
            }
        }
        var k = 0
        while k < n - 2 && x > xs[k + 1] { k += 1 }
        let h = xs[k + 1] - xs[k]
        let t = (x - xs[k]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * m[k + 1]
    }

    /// The controls' values and the tone steps, in order.
    private struct Values {
        let values: [String: Double]

        func value(_ id: String) -> Double {
            values[id] ?? ToneCurve.neutral(id)
        }

        /// Output (red, green, blue) for one input level 0…1.
        func channels(_ x: Double) -> (Double, Double, Double) {
            let y = fade(parametric(basic(x)))
            return (y, y, y)
        }

        /// Whites, Blacks, Highlights (brightening only; darkening is CIHighlightShadowAdjust in the
        /// renderer) and Brightness.
        func basic(_ x: Double) -> Double {
            let whites = value("whites") / 100, blacks = value("blacks") / 100
            let highlights = Swift.max(value("highlights"), 0) / 100
            // Whites move the top end: +100 lifts white by a quarter (clipping the brightest tones), −100 dims it.
            var y = x + 0.25 * whites * x * x * x
            // Blacks move the bottom end: −100 crushes the darkest quarter to black, +100 lifts black.
            y += 0.25 * blacks * pow(1 - Swift.min(x, 1), 3)
            if highlights > 0 {
                // Bump peaking at 3/4, zero at 0 and 1.
                y += 0.1 * highlights * (256.0 / 27.0) * x * x * x * (1 - x)
            }
            // Brightness: a gamma curve, so midtones move while black and white stay put.
            let brightness = value("brightness") / 100
            if brightness != 0 && y > 0 && y < 1 {
                y = pow(y, pow(2, -0.8 * brightness))
            }
            return y
        }

        /// Tone curve regions (Lightroom's parametric curve): Shadows, Darks, Lights and Highlights
        /// each move their quarter of the range, by up to 0.12 at ±100; black and white stay put.
        func parametric(_ x: Double) -> Double {
            let amounts = ["curveShadows", "curveDarks", "curveLights", "curveHighlights"].map { value($0) / 100 }
            guard amounts.contains(where: { $0 != 0 }) else { return x }
            let xs = [0, 0.125, 0.375, 0.625, 0.875, 1]
            let ys = [0] + zip(xs[1...4], amounts).map { $0 + 0.12 * $1 } + [1]
            return ToneCurve.spline(xs: xs, ys: ys, at: x)
        }

        /// Fade: lifts black towards grey for a matte look (up to a quarter); white stays white.
        func fade(_ x: Double) -> Double {
            let f = value("fade") / 100 * 0.25
            return f == 0 ? x : f + (1 - f) * x
        }
    }

    /// Never lets a table go down (keeps every curve monotone after clamping).
    private static func monotone(_ values: [Double]) -> [Double] {
        var out = values
        for i in out.indices.dropFirst() where out[i] < out[i - 1] { out[i] = out[i - 1] }
        return out
    }
}
