import Foundation

/// Photoshop's toning brushes, painted on the photo (sRGB levels): Dodge and Burn lighten or darken
/// by up to one stop at full strength, mostly in one tone range; Sponge adds or takes away colour;
/// Blur, Sharpen and Smudge soften, crispen or smear what they are painted over.
/// `cover` is how much the brush reached each pixel (its soft edge and the pen's pressure),
/// `strength` the Tool Strength 0…1.
enum ToneBrushes {
    /// How much a tone range takes part at a brightness (sRGB luma 0…1): shadows (0), midtones (1),
    /// highlights (2).
    static func rangeWeight(_ luma: Double, range: Int) -> Double {
        switch range {
        case 0: return 1 - Effects.smoothstep(0.1, 0.5, luma)
        case 2: return Effects.smoothstep(0.5, 0.9, luma)
        default: return Swift.max(0, 1 - (2 * luma - 1) * (2 * luma - 1))
        }
    }

    /// Dodge (`lighter`) or burn: exposure × 2^(±strength × range weight × cover), in linear light.
    static func dodgeBurn(_ pixels: inout RGBBuffer, cover: [Float], strength: Double, range: Int, lighter: Bool) {
        let sign = lighter ? 1.0 : -1.0
        for i in 0..<(pixels.width * pixels.height) where cover[i] > 0 {
            let r = pixels.pixels[3 * i], g = pixels.pixels[3 * i + 1], b = pixels.pixels[3 * i + 2]
            let luma = Double(0.2126 * r + 0.7152 * g + 0.0722 * b)
            let stops = sign * strength * rangeWeight(Swift.min(1, Swift.max(0, luma)), range: range) * Double(cover[i])
            guard stops != 0 else { continue }
            let gain = Float(pow(2, stops))
            for c in 0..<3 { pixels.pixels[3 * i + c] = encode(decode(pixels.pixels[3 * i + c]) * gain) }
        }
    }

    /// Sponge: each colour moves away from (`saturate`) or towards its own grey (Rec. 709 luma), up
    /// to twice as colourful or fully grey at full strength.
    static func sponge(_ pixels: inout RGBBuffer, cover: [Float], strength: Double, saturate: Bool) {
        for i in 0..<(pixels.width * pixels.height) where cover[i] > 0 {
            let k = Float(strength) * cover[i]
            let factor = saturate ? 1 + k : 1 - k
            let r = pixels.pixels[3 * i], g = pixels.pixels[3 * i + 1], b = pixels.pixels[3 * i + 2]
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            for c in 0..<3 { pixels.pixels[3 * i + c] = Swift.max(0, luma + (pixels.pixels[3 * i + c] - luma) * factor) }
        }
    }

    /// Each channel of a picture blurred (three box blurs of `radius` pixels, about a Gaussian).
    static func blurred(_ image: RGBBuffer, radius: Int) -> RGBBuffer {
        var out = image
        let n = image.width * image.height
        for c in 0..<3 {
            let channel = (0..<n).map { image.pixels[3 * $0 + c] }
            let soft = MaskRaster.blur(channel, width: image.width, height: image.height, radius: radius)
            for i in 0..<n { out.pixels[3 * i + c] = soft[i] }
        }
        return out
    }

    /// Smudge: a finger dragged through wet paint. It picks up the colours under the first dab and
    /// carries them along the dabs (pixels from the box's corner), mixing them in by `strength`
    /// times the brush's soft edge and the pen's pressure at each dab, and picking up what it mixed.
    static func smudge(_ pixels: inout RGBBuffer, dabs: [(x: Double, y: Double)], pressure: [Float]?, radius r: Double,
                       feather: Double, strength: Double) {
        guard let first = dabs.first else { return }
        let reach = Int(r.rounded(.up)), side = 2 * reach + 1
        let soft = Swift.max(feather / 100, 1.5 / r)
        // The brush's weight at each offset, and the paint it carries.
        var weight = [Float](repeating: 0, count: side * side)
        for dy in -reach...reach {
            for dx in -reach...reach {
                let d = (Double(dx * dx + dy * dy)).squareRoot() / r
                weight[(dy + reach) * side + dx + reach] = d < 1 ? Float(1 - Effects.smoothstep(1 - soft, 1, d)) : 0
            }
        }
        func pixel(_ x: Int, _ y: Int) -> Int? {
            x >= 0 && y >= 0 && x < pixels.width && y < pixels.height ? 3 * (y * pixels.width + x) : nil
        }
        var carried = [Float](repeating: 0, count: side * side * 3)
        var has = [Bool](repeating: false, count: side * side)
        let cx = Int(first.x.rounded(.down)), cy = Int(first.y.rounded(.down))
        for dy in -reach...reach {
            for dx in -reach...reach {
                guard let i = pixel(cx + dx, cy + dy) else { continue }
                let k = (dy + reach) * side + dx + reach
                for c in 0..<3 { carried[3 * k + c] = pixels.pixels[i + c] }
                has[k] = true
            }
        }
        for (n, dab) in dabs.enumerated().dropFirst() {
            let mix = Float(strength) * (pressure?[n] ?? 1)
            let x0 = Int(dab.x.rounded(.down)), y0 = Int(dab.y.rounded(.down))
            for dy in -reach...reach {
                for dx in -reach...reach {
                    let k = (dy + reach) * side + dx + reach
                    guard weight[k] > 0, let i = pixel(x0 + dx, y0 + dy) else { continue }
                    let w = weight[k] * mix
                    for c in 0..<3 {
                        if has[k] { pixels.pixels[i + c] += (carried[3 * k + c] - pixels.pixels[i + c]) * w }
                        carried[3 * k + c] = pixels.pixels[i + c]
                    }
                    has[k] = true
                }
            }
        }
    }

    /// sRGB level → linear light (extended: negative and above-1 levels keep their sign and slope).
    static func decode(_ v: Float) -> Float {
        let a = abs(v)
        let l = a <= 0.04045 ? a / 12.92 : powf((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -l : l
    }

    /// Linear light → sRGB level.
    static func encode(_ l: Float) -> Float {
        let a = abs(l)
        let v = a <= 0.0031308 ? a * 12.92 : 1.055 * powf(a, 1 / 2.4) - 0.055
        return l < 0 ? -v : v
    }
}
