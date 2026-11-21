import CommandEngine
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Color panel, in Lightroom's order. `input` runs before the Light panel (film negative, white balance);
/// `apply` runs after it (vibrance, saturation, hue, the colour cube, match color, LUT, invert).
/// The colour math lives in CommandEngine (WhiteBalance, ColorLook) so it is tested on Linux.
final class ColorRenderer {
    let context: CIContext
    /// Colour cubes made lately, by the control values they were made for (the photo's own and each
    /// mask's local one are used in turn on every render).
    private var cachedCubes: [[Double]: Data] = [:]
    /// Match color: statistics of each reference picture, worked out once.
    private var referenceStats: [String: MatchColor.Stats] = [:]
    /// LUT files read so far, and the last cube data made from one (LUT id and amount).
    private var luts: [String: CubeLUT] = [:]
    private var cachedLUT: (key: String, data: Data)?
    /// A raw photo's As Shot white balance (kelvin): the presets are relative to it (nil: 5500 K, a JPEG's).
    var asShotKelvin: Double?

    init(context: CIContext) {
        self.context = context
    }

    /// Steps that come before the Light panel: film negative conversion, white balance.
    func input(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        whiteBalance(filmNegative(image, value: value), value: value)
    }

    /// Film negative conversion: each channel inverted and stretched between its own darkest and
    /// brightest levels (FilmNegative in CommandEngine), which also removes the orange film mask.
    func filmNegative(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        guard (value("filmNegative") ?? 0) != 0 else { return image }
        let h = ImageStats.channelHistograms(of: image, extent: image.extent, context: context)
        let t = FilmNegative.transfer(red: h.red, green: h.green, blue: h.blue)
        return image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(t.scale.r), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(t.scale.g), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(t.scale.b), w: 0),
            "inputBiasVector": CIVector(x: CGFloat(t.bias.r), y: CGFloat(t.bias.g), z: CGFloat(t.bias.b), w: 0),
        ]).applyingFilter("CISRGBToneCurveToLinear")
    }

    /// Steps that come after the Light panel. `extent` is the photo's own frame (filters before
    /// may have grown the image's).
    func apply(_ image: CIImage, extent: CGRect, value: (String) -> Double?) -> CIImage {
        var output = image

        // Vibrance: boosts muted colours more than strong ones, and spares skin tones.
        let vibrance = value("vibrance") ?? 0  // −100…100 → Core Image −1…1
        if vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = output
            filter.amount = Float(vibrance / 100)
            output = filter.outputImage ?? output
        }

        let saturation = value("saturation") ?? 0  // −100…100 → Core Image 0…2
        if saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = 0
            filter.contrast = 1
            filter.saturation = Float(1 + saturation / 100)
            output = filter.outputImage ?? output
        }

        // Hue: turns every colour around the colour wheel by this many degrees; greys stay grey.
        let hue = value("hue") ?? 0  // −180…180°
        if hue != 0 {
            let filter = CIFilter.hueAdjust()
            filter.inputImage = output
            filter.angle = Float(hue * .pi / 180)
            output = filter.outputImage ?? output
        }

        output = colorCube(output, value: value)
        output = matchColor(output, extent: extent, value: value)
        output = lut(output, value: value)

        // Invert: a photo negative of the levels the eye sees (sRGB), so mid-grey stays mid-grey.
        if (value("invert") ?? 0) != 0 {
            output = output.applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIColorInvert")
                .applyingFilter("CISRGBToneCurveToLinear")
        }

        return output
    }

    /// Size of the colour cube per side (33³ entries, the usual LUT size).
    static let cubeSize = 33

    /// The per-colour tools (ColorLook) as one lookup-table pass on sRGB levels.
    private func colorCube(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        guard !ColorLook.isIdentity(value), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let key = ColorLook.controlIDs.map { value($0) ?? ColorLook.neutral($0) }
        let data: Data
        if let cached = cachedCubes[key] {
            data = cached
        } else {
            let floats = ColorLook.cube(value, size: Self.cubeSize)
            data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            if cachedCubes.count >= 6 { cachedCubes = [:] }
            cachedCubes[key] = data
        }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": Self.cubeSize,
            "inputCubeData": data,
            "inputColorSpace": space,
        ])
    }

    /// Match color: moves each channel's average and spread onto the reference picture's
    /// (MatchColor in CommandEngine), on sRGB levels, mixed in by Match Amount.
    private func matchColor(_ image: CIImage, extent: CGRect, value: (String) -> Double?) -> CIImage {
        let index = Int(value("matchColor") ?? 0)
        guard index > 0, MatchColor.referenceIDs.indices.contains(index),
              let reference = stats(ofReference: MatchColor.referenceIDs[index]) else { return image }
        let source = ImageStats.levelStats(of: image, extent: extent, context: context)
        let t = MatchColor.transfer(from: source, to: reference, amount: (value("matchAmount") ?? 100) / 100)
        let matched = image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(t.scale.r), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(t.scale.g), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(t.scale.b), w: 0),
            "inputBiasVector": CIVector(x: CGFloat(t.bias.r), y: CGFloat(t.bias.g), z: CGFloat(t.bias.b), w: 0),
        ])
        return matched.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// LUT: one of the bundled .cube looks (CubeLUT in CommandEngine) on sRGB levels, mixed in by LUT Amount.
    private func lut(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        let index = Int(value("lut") ?? 0)
        guard index > 0, CubeLUT.options.indices.contains(index), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return image
        }
        let id = CubeLUT.options[index]
        if luts[id] == nil { luts[id] = try? CubeLUT.bundled(id) }
        guard let table = luts[id] else { return image }
        let amount = (value("lutAmount") ?? 100) / 100
        let key = "\(id) \(amount)"
        let data: Data
        if let cached = cachedLUT, cached.key == key {
            data = cached.data
        } else {
            data = table.cubeData(amount: amount).withUnsafeBufferPointer { Data(buffer: $0) }
            cachedLUT = (key, data)
        }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": table.size,
            "inputCubeData": data,
            "inputColorSpace": space,
        ])
    }

    /// The reference pictures: the bundled test photo, and a generated sunset (PhotoRenderer.sample).
    private func stats(ofReference id: String) -> MatchColor.Stats? {
        if let known = referenceStats[id] { return known }
        let picture: CIImage?
        switch id {
        case "testPhoto": picture = Bundle.main.url(forResource: "test", withExtension: "jpg").flatMap { CIImage(contentsOf: $0) }
        case "sunset": picture = PhotoRenderer.sample()
        default: picture = nil
        }
        guard let picture else { return nil }
        let small = PhotoRenderer.downscaled(picture, maxSide: 512)
        let stats = ImageStats.levelStats(of: small, extent: small.extent, context: context)
        referenceStats[id] = stats
        return stats
    }

    /// White balance: the preset's light plus the Temperature and Tint sliders, as one multiplier
    /// per channel in linear light (Core Image's working space). As Shot leaves the photo as the camera
    /// set it (a raw's own setting; a JPEG as it is); Auto makes the photo's average colour neutral.
    func whiteBalance(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        let index = Int(value("whiteBalance") ?? 0)
        let preset = WhiteBalance.presetIDs.indices.contains(index) ? WhiteBalance.presetIDs[index] : "asShot"
        var offset = WhiteBalance.offset(preset: preset, asShot: asShotKelvin ?? WhiteBalance.referenceKelvin)
        if preset == "auto" {
            offset = WhiteBalance.neutralize(ImageStats.averageColor(of: image, context: context))
        }
        let temperature = offset.temperature + (value("temperature") ?? 0)
        let tint = offset.tint + (value("tint") ?? 0)
        guard temperature != 0 || tint != 0 else { return image }
        let g = WhiteBalance.gains(temperature: temperature, tint: tint)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(g.r), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(g.g), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(g.b), w: 0),
        ])
    }
}
