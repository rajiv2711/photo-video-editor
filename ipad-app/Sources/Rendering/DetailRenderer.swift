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
