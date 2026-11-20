import CommandEngine
import CoreImage

/// The Detail panel, after Effects: noise reduction first (so sharpening doesn't sharpen noise), then
/// moiré removal, sharpening and high pass. Works on sRGB-encoded levels; sizes are pixels of a
/// 2048 px photo, grown in proportion on bigger photos (Detail in CommandEngine).
final class DetailRenderer {
    let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    /// `extent` is the photo's own frame.
    func apply(_ image: CIImage, extent: CGRect, value: (String) -> Double?) -> CIImage {
        func v(_ id: String) -> Double { value(id) ?? 0 }
        let side = Double(max(extent.width, extent.height))
        var output = image

        // Luminance noise reduction: a median and blur, used where the picture is flat or lightly
        // textured (by the local brightness range) and only for brightness, so colours stay put.
        let luminanceNR = v("noiseReduction") / 100
        if luminanceNR > 0 {
            let encoded = Filters.encoded(output)
            let radius = Detail.pixels(Detail.noiseRadius(amount: luminanceNR, color: false), longSide: side)
            let soft = Filters.blurred(encoded.applyingFilter("CIMedianFilter"), radius: radius, extent: extent)
            let range = Filters.localRange(encoded, extent: extent, radius: Detail.pixels(1.5, longSide: side))
            let smoothed = Filters.blend(soft, over: encoded, mask: Filters.lookup(range, table: Detail.noiseSmoothing(amount: luminanceNR)))
            let brightnessOnly = smoothed.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: encoded])
            output = Filters.linear(brightnessOnly.cropped(to: extent))
        }

        // Colour noise reduction: the colour of a blurred copy on the brightness of the picture.
        let chromaNR = v("chromaNoiseReduction") / 100
        if chromaNR > 0 {
            let encoded = Filters.encoded(output)
            let radius = Detail.pixels(Detail.noiseRadius(amount: chromaNR, color: true), longSide: side)
            let colour = Filters.blurred(encoded, radius: radius, extent: extent)
                .applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: encoded])
            output = Filters.linear(Filters.mix(encoded, colour.cropped(to: extent), min(1, 2 * chromaNR)))
        }

        // Sharpening: an unsharp mask at Radius, plus a finer pass that Detail turns up; Masking
        // keeps flat areas out (by the local brightness range around each pixel).
        let amount = v("sharpening") / 100
        if amount > 0 {
            let encoded = Filters.encoded(output)
            let radius = Detail.pixels(value("sharpeningRadius") ?? 1, longSide: side)
            let passes = Detail.sharpening(amount: amount, detail: (value("sharpeningDetail") ?? 25) / 100)
            var sharpened = Filters.unsharp(encoded, radius: radius, intensity: passes.main, extent: extent)
            sharpened = Filters.unsharp(sharpened, radius: 0.5 * radius, intensity: passes.fine, extent: extent)
            let masking = v("sharpeningMasking") / 100
            if masking > 0 {
                let range = Filters.localRange(encoded, extent: extent, radius: Detail.pixels(1.5, longSide: side))
                sharpened = Filters.blend(sharpened, over: encoded, mask: Filters.lookup(range, table: Detail.sharpeningMask(masking: masking)))
            }
            output = Filters.linear(sharpened)
        }

        return output
    }
}
