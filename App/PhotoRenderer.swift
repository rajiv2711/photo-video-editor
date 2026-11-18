import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Maps control values (as defined in controls.json) onto Core Image filters.
final class PhotoRenderer {
    private let context = CIContext()

    func apply(to image: CIImage, value: (String) -> Double) -> CIImage {
        var output = image

        let exposure = value("exposure")  // EV, −3…3
        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(exposure)
            output = filter.outputImage ?? output
        }

        let contrast = value("contrast")      // −100…100 → Core Image 0.5…1.5
        let saturation = value("saturation")  // −100…100 → Core Image 0…2
        if contrast != 0 || saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = 0
            filter.contrast = Float(1 + contrast / 100 * 0.5)
            filter.saturation = Float(1 + saturation / 100)
            output = filter.outputImage ?? output
        }

        return output.cropped(to: image.extent)
    }

    func uiImage(_ image: CIImage) -> UIImage? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A smaller copy for live preview, so sliders stay smooth on large photos.
    static func downscaled(_ image: CIImage, maxSide: CGFloat) -> CIImage {
        let side = max(image.extent.width, image.extent.height)
        guard side > maxSide else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(maxSide / side)
        filter.aspectRatio = 1
        return filter.outputImage ?? image
    }

    /// A built-in picture so the editor is usable before a photo is opened.
    static func sample() -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        let sky = CIFilter.linearGradient()
        sky.point0 = CGPoint(x: 0, y: 0)
        sky.point1 = CGPoint(x: 0, y: 1200)
        sky.color0 = CIColor(red: 0.95, green: 0.55, blue: 0.25)
        sky.color1 = CIColor(red: 0.20, green: 0.35, blue: 0.75)
        let sun = CIFilter.radialGradient()
        sun.center = CGPoint(x: 1100, y: 520)
        sun.radius0 = 70
        sun.radius1 = 380
        sun.color0 = CIColor(red: 1, green: 0.95, blue: 0.7, alpha: 1)
        sun.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        guard let skyImage = sky.outputImage, let sunImage = sun.outputImage else {
            return CIImage(color: .gray).cropped(to: rect)
        }
        return sunImage.composited(over: skyImage).cropped(to: rect)
    }
}
