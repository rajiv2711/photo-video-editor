import CommandEngine
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Color panel, in Lightroom's order. `input` runs before the Light panel (white balance);
/// `apply` runs after it (vibrance, saturation, hue, then the colour cube: color mixer, …).
/// The colour math lives in CommandEngine (WhiteBalance, ColorLook) so it is tested on Linux.
final class ColorRenderer {
    let context: CIContext
    /// The last colour cube and the control values it was made for (sliders move one at a time).
    private var cachedCube: (key: [Double], data: Data)?

    init(context: CIContext) {
        self.context = context
    }

    /// Steps that come before the Light panel: white balance.
    func input(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        whiteBalance(image, value: value)
    }

    /// Steps that come after the Light panel.
    func apply(_ image: CIImage, value: (String) -> Double?) -> CIImage {
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

        return output
    }

    /// Size of the colour cube per side (33³ entries, the usual LUT size).
    static let cubeSize = 33

    /// The per-colour tools (ColorLook) as one lookup-table pass on sRGB levels.
    private func colorCube(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        guard !ColorLook.isIdentity(value), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let key = ColorLook.controlIDs.map { value($0) ?? ColorLook.neutral($0) }
        let data: Data
        if let cached = cachedCube, cached.key == key {
            data = cached.data
        } else {
            let floats = ColorLook.cube(value, size: Self.cubeSize)
            data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            cachedCube = (key, data)
        }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": Self.cubeSize,
            "inputCubeData": data,
            "inputColorSpace": space,
        ])
    }

    /// White balance: the preset's light plus the Temperature and Tint sliders, as one multiplier
    /// per channel in linear light (Core Image's working space). As Shot leaves a JPEG as it is;
    /// Auto makes the photo's average colour neutral.
    private func whiteBalance(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        let index = Int(value("whiteBalance") ?? 0)
        let preset = WhiteBalance.presetIDs.indices.contains(index) ? WhiteBalance.presetIDs[index] : "asShot"
        var offset = WhiteBalance.offset(preset: preset)
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
