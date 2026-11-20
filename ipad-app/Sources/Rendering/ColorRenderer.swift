import CommandEngine
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Color panel, in Lightroom's order. `input` runs before the Light panel (white balance);
/// `apply` runs after it (saturation, …). The colour math lives in CommandEngine (WhiteBalance,
/// …) so it is tested on Linux.
struct ColorRenderer {
    let context: CIContext

    /// Steps that come before the Light panel: white balance.
    func input(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        whiteBalance(image, value: value)
    }

    /// Steps that come after the Light panel.
    func apply(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        var output = image

        let saturation = value("saturation") ?? 0  // −100…100 → Core Image 0…2
        if saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = 0
            filter.contrast = 1
            filter.saturation = Float(1 + saturation / 100)
            output = filter.outputImage ?? output
        }

        return output
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
