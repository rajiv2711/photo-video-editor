import CoreImage
import CoreImage.CIFilterBuiltins

/// The Color panel (after Light in Lightroom's order). So far: Saturation.
enum ColorRenderer {
    static func apply(_ image: CIImage, value: (String) -> Double?) -> CIImage {
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
}
