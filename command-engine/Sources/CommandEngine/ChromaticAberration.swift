import Foundation

/// Lateral chromatic aberration: the lens spreads red, green and blue to slightly different sizes,
/// so edges near the corners get red/cyan or blue/yellow fringes. Fixed by reading red and blue a
/// little further in or out than green (LensWarp.redScale, blueScale).
public enum ChromaticAberration {
    /// Manual fringe sliders (−100…100) as a scale: ±0.5 %.
    public static func scale(slider: Double) -> Double {
        1 + 0.005 * Swift.min(100, Swift.max(-100, slider)) / 100
    }

    /// Finds the red and blue scales that line their edges up with green's, from a small copy of the
    /// photo (`pixels`: RGBA floats, row by row). Looks at strong green edges away from the centre
    /// and tries scales from −1 % to +1 %, then refines around the best. 1 when nothing fits better.
    public static func estimate(_ pixels: [Float], width: Int, height: Int) -> (red: Double, blue: Double) {
        guard width > 8, height > 8, pixels.count >= width * height * 4 else { return (1, 1) }
        let w = Double(width), h = Double(height)
        // Strong green edges outside the middle quarter of the diagonal.
        var edges: [(point: LensWarp.Point, green: Float)] = []
        var strengths: [Float] = []
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let g = { (dx: Int, dy: Int) in pixels[((y + dy) * width + x + dx) * 4 + 1] }
                let gx = g(1, 0) - g(-1, 0), gy = g(0, 1) - g(0, -1)
                strengths.append(gx * gx + gy * gy)
            }
        }
        let cut = strengths.sorted()[Int(Double(strengths.count) * 0.92)]
        guard cut > 1e-6 else { return (1, 1) }
        let inner = 0.25 * (w * w + h * h).squareRoot() / 2
        var i = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                defer { i += 1 }
                guard strengths[i] >= cut else { continue }
                let p = LensWarp.Point(x: Double(x) + 0.5 - w / 2, y: Double(y) + 0.5 - h / 2)
                if p.length > inner { edges.append((p, pixels[(y * width + x) * 4 + 1])) }
            }
        }
        guard edges.count >= 20 else { return (1, 1) }

        func error(_ scale: Double, _ channel: Int) -> Double {
            pixels.withUnsafeBufferPointer { buffer in
                edges.reduce(0.0) { sum, edge in
                    sum + Double(abs(LensWarp.sample(buffer, width, height, edge.point.scaled(scale), channel) - edge.green))
                }
            }
        }
        func best(_ channel: Int) -> Double {
            var found = 1.0, lowest = error(1, channel)
            for step in -20...20 where step != 0 {
                let s = 1 + Double(step) * 0.0005
                let e = error(s, channel)
                if e < lowest { (found, lowest) = (s, e) }
            }
            let coarse = found
            for step in -5...5 where step != 0 {
                let s = coarse + Double(step) * 0.0001
                let e = error(s, channel)
                if e < lowest { (found, lowest) = (s, e) }
            }
            return found
        }
        return (best(0), best(2))
    }
}
