import CommandEngine
import CoreImage

/// The Effects panel, after Color: texture → clarity → dehaze → glow → posterize, threshold, solarize.
/// The vignette and grain are finishing touches (`finish`), after the Detail panel, as in Lightroom.
/// Perceptual effects run on sRGB-encoded levels (Filters.encoded); sizes are a share of the photo's
/// long side, so the preview and the saved photo look alike. (Tables: Effects in CommandEngine.)
final class EffectsRenderer {
    let context: CIContext
    /// The last vignette mask and the settings it was made for (grid size, midpoint, roundness, feather).
    private var cachedVignette: (key: [Double], values: [Double])?

    init(context: CIContext) {
        self.context = context
    }

    /// `extent` is the photo's own frame.
    func apply(_ image: CIImage, extent: CGRect, value: (String) -> Double?) -> CIImage {
        func v(_ id: String) -> Double { value(id) ?? 0 }
        let side = Double(max(extent.width, extent.height))
        var output = image

        // Texture: medium-size detail (about 0.3 % of the long side). Positive adds it with an
        // unsharp mask; negative mixes in a blurred copy. Both leave strong edges alone (by the local
        // brightness range within the blur's reach), so edges keep their shape and get no halos.
        let texture = v("texture") / 100
        if texture != 0 {
            let encoded = Filters.encoded(output)
            let radius = 0.003 * side
            let range = Filters.localRange(encoded, extent: extent, radius: 2 * radius)
            let changed: CIImage
            if texture > 0 {
                let boosted = Filters.unsharp(encoded, radius: radius, intensity: texture, extent: extent)
                changed = Filters.blend(boosted, over: encoded, mask: Filters.lookup(range, table: Effects.textureBoost()))
            } else {
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

        // Glow: Core Image's soft bloom (2 % of the long side), in linear light like real light.
        let glow = v("glow") / 100
        if glow > 0 {
            output = output.cropped(to: extent).clampedToExtent().applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: 0.02 * side,
                kCIInputIntensityKey: glow,
            ]).cropped(to: extent)
        }

        // Halation: film's red-orange halo around bright areas. The bright parts, blurred and tinted,
        // are screened onto the picture (sRGB levels), so they show most against darker surroundings.
        let halation = v("halation") / 100
        if halation > 0 {
            let encoded = Filters.encoded(output)
            let bright = Filters.lookup(Filters.luma(encoded), table: Effects.halationSource())
            let halo = Filters.affine(Filters.blurred(bright, radius: 0.012 * side, extent: extent),
                                      scale: Effects.halationTint * halation, bias: RGB(0, 0, 0))
            output = Filters.linear(halo.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: encoded]))
        }

        // Posterize: a few evenly spaced levels per channel, on sRGB levels.
        if v("posterize") != 0 {
            let levels = Int(value("posterizeLevels") ?? 4)
            output = Filters.linear(Filters.lookup(Filters.encoded(output), table: Effects.posterize(levels: levels)))
        }

        // Threshold: pure black and white, cut at a brightness level (sRGB luma, 0…255).
        if v("threshold") != 0 {
            let level = value("thresholdLevel") ?? 128
            output = Filters.linear(Filters.lookup(Filters.luma(Filters.encoded(output)), table: Effects.threshold(level: level)))
        }

        // Solarize: the bright levels fold back down (sRGB levels).
        let solarize = v("solarize") / 100
        if solarize > 0 {
            output = Filters.linear(Filters.lookup(Filters.encoded(output), table: Effects.solarize(amount: solarize)))
        }

        return output
    }

    /// Finishing touches, after the Detail panel: the post-crop vignette, then grain.
    func finish(_ image: CIImage, extent: CGRect, value: (String) -> Double?) -> CIImage {
        func v(_ id: String) -> Double { value(id) ?? 0 }
        var output = image

        let amount = v("vignette") / 100
        if amount != 0 {
            output = vignette(output, extent: extent, amount: amount,
                              midpoint: (value("vignetteMidpoint") ?? 50) / 100,
                              roundness: v("vignetteRoundness") / 100,
                              feather: (value("vignetteFeather") ?? 50) / 100,
                              highlights: v("vignetteHighlights") / 100)
        }

        let grainAmount = v("grain") / 100
        if grainAmount > 0 {
            output = grain(output, extent: extent, amount: grainAmount, size: (value("grainSize") ?? 25) / 100,
                                roughness: (value("grainRoughness") ?? 50) / 100)
        }
        return output
    }

    /// Film grain: a mid-grey noise layer overlaid on sRGB levels, so it shows most in the midtones.
    /// Roughness mixes in a second, coarser noise for clumpier grain. The noise is Core Image's fixed
    /// random pattern, so the same settings always give the same picture.
    private func grain(_ image: CIImage, extent: CGRect, amount: Double, size: Double, roughness: Double) -> CIImage {
        let cell = Effects.grainCell(size: size, longSide: Double(max(extent.width, extent.height)))
        var noise = Self.noise(cell: cell, offset: 0, extent: extent)
        if roughness > 0 {
            noise = Filters.mix(noise, Self.noise(cell: cell * 2.5, offset: 300, extent: extent), 0.6 * roughness)
        }
        let k = Effects.grainContrast(amount: amount)
        let layer = Filters.affine(noise, scale: k, bias: 0.5 * (1 - k))
        let grained = layer.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: Filters.encoded(image)])
        return Filters.linear(grained)
    }

    /// Grey random noise (0…1) with cells of `cell` pixels over `extent`; `offset` picks another part of
    /// the random pattern.
    private static func noise(cell: Double, offset: CGFloat, extent: CGRect) -> CIImage {
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        }
        let size = CGFloat(cell)
        let area = CGRect(x: offset, y: offset, width: extent.width / size + 2, height: extent.height / size + 2)
        let grey = random.cropped(to: area).settingAlphaOne(in: area).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        let transform = CGAffineTransform(translationX: extent.minX, y: extent.minY)
            .scaledBy(x: size, y: size)
            .translatedBy(x: -offset, y: -offset)
        return grey.transformed(by: transform).cropped(to: extent)
    }

    /// Post-crop vignette on sRGB levels: the mask (Vignette in CommandEngine) darkens the edges by
    /// multiplying (negative amount; Highlights bring bright areas back) or lightens them by screening
    /// towards white (positive amount).
    private func vignette(_ image: CIImage, extent: CGRect, amount: Double, midpoint: Double, roundness: Double,
                          feather: Double, highlights: Double) -> CIImage {
        let grid = Vignette.gridSize(width: Double(extent.width), height: Double(extent.height))
        let key = [Double(grid.width), Double(grid.height), midpoint, roundness, feather]
        let values: [Double]
        if let cached = cachedVignette, cached.key == key {
            values = cached.values
        } else {
            values = Vignette.mask(width: grid.width, height: grid.height, midpoint: midpoint, roundness: roundness, feather: feather)
            cachedVignette = (key, values)
        }
        let mask = Filters.mask(values, width: grid.width, height: grid.height, over: extent)
        let encoded = Filters.encoded(image)
        if amount > 0 {
            let light = Filters.affine(mask, scale: amount)
            return Filters.linear(light.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: encoded]))
        }
        let gain = Filters.affine(mask, scale: amount, bias: 1)
        var dark = encoded.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain])
        if highlights > 0 {
            let keep = Filters.lookup(Filters.luma(encoded), table: Effects.vignetteHighlights(amount: highlights))
            dark = Filters.blend(encoded, over: dark, mask: keep)
        }
        return Filters.linear(dark)
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
