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

        // Clarity: midtone local contrast. A wide unsharp mask (2 % of the long side) or, negative,
        // a mix towards a blurred copy; kept in the midtones only, so blacks and whites don't clip.
        let clarity = v("clarity") / 100
        if clarity != 0 {
            let encoded = Filters.encoded(output)
            let changed: CIImage
            if clarity > 0 {
                changed = Filters.unsharp(encoded, radius: 0.02 * side, intensity: 0.8 * clarity, extent: extent)
            } else {
                changed = Filters.mix(encoded, Filters.blurred(encoded, radius: 0.01 * side, extent: extent), -0.6 * clarity)
            }
            let midtones = Filters.lookup(Filters.luma(encoded), table: Effects.midtones())
            output = Filters.linear(Filters.blend(changed, over: encoded, mask: midtones))
        }

        // Dehaze: takes haze out (or adds it), see `dehaze` below.
        let haze = v("dehaze") / 100
        if haze != 0 {
            output = dehaze(output, extent: extent, strength: haze)
        }

        return output
    }

    /// Dehaze with the dark channel prior (Effects.dehaze in CommandEngine shows the per-pixel math).
    /// Haze-free scenes almost always have a dark channel somewhere nearby, so the darkest channel
    /// (÷ the haze colour) over a neighbourhood measures how much haze lies in front: the transmission
    /// t = 1 − strength × that. Positive: J = A − (A − I) ÷ t. Negative: the haze colour is mixed in.
    private func dehaze(_ image: CIImage, extent: CGRect, strength: Double) -> CIImage {
        let h = ImageStats.channelHistograms(of: image, extent: extent, context: context)
        let air = Effects.airlight(red: h.red, green: h.green, blue: h.blue)
        let encoded = Filters.encoded(image)
        if strength < 0 {
            let k = Effects.hazeAdded(strength)
            return Filters.linear(Filters.affine(encoded, scale: RGB(1 - k, 1 - k, 1 - k), bias: air * k))
        }
        // Dark channel on a small copy (about 256 px): darkest channel, local minimum, softened, then
        // stretched back over the photo. Smooth on purpose; the haze varies slowly.
        let normalized = Filters.affine(encoded, scale: RGB(1 / air.r, 1 / air.g, 1 / air.b), bias: RGB(0, 0, 0))
        let small = PhotoRenderer.downscaled(normalized.cropped(to: extent), maxSide: 256)
        let dark = small.applyingFilter("CIMinimumComponent").clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 3])
            .applyingGaussianBlur(sigma: 4)
            .cropped(to: small.extent)
        let ratio = Filters.lookup(Filters.resized(dark, to: extent), table: Effects.dehazeRatio(strength: strength))
        // (A − I) × floor/t, then A − that ÷ floor.
        let fromAir = Filters.affine(encoded, scale: RGB(-1, -1, -1), bias: air)
        let scaled = fromAir.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: ratio])
        let k = -1 / Effects.dehazeFloor
        return Filters.linear(Filters.affine(scaled, scale: RGB(k, k, k), bias: air))
    }
}
