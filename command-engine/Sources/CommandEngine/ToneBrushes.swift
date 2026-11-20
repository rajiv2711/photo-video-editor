import Foundation

/// Photoshop's toning brushes, painted on the photo (sRGB levels): Dodge and Burn lighten or darken
/// by up to one stop at full strength, mostly in one tone range; Sponge adds or takes away colour.
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
