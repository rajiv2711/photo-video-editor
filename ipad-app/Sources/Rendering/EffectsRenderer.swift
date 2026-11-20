import CommandEngine
import CoreImage

/// The Effects panel, after Color: texture → clarity → dehaze → glow → posterize, threshold, solarize.
/// Perceptual effects run on sRGB-encoded levels (Filters.encoded); sizes are a share of the photo's
/// long side, so the preview and the saved photo look alike. (Tables: Effects in CommandEngine.)
final class EffectsRenderer {
    let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    /// `extent` is the photo's own frame.
    func apply(_ image: CIImage, extent: CGRect, value: (String) -> Double?) -> CIImage {
        func v(_ id: String) -> Double { value(id) ?? 0 }
        let side = Double(max(extent.width, extent.height))
        var output = image

        // Texture: medium-size detail (about 0.5 % of the long side). Positive adds it with an
        // unsharp mask; negative mixes in a blurred copy where detail is fine, keeping strong edges.
        let texture = v("texture") / 100
        if texture != 0 {
            let encoded = Filters.encoded(output)
            let radius = 0.005 * side
            let changed: CIImage
            if texture > 0 {
                changed = Filters.unsharp(encoded, radius: radius, intensity: 1.2 * texture, extent: extent)
            } else {
                let range = Filters.localRange(encoded, extent: extent, radius: 0.0015 * side)
                let weight = Filters.lookup(range, table: Effects.textureSmoothing(amount: -texture))
                changed = Filters.blend(Filters.blurred(encoded, radius: radius, extent: extent), over: encoded, mask: weight)
            }
            output = Filters.linear(changed)
        }

        return output
    }
}
