import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Turns control values (see controls.json) into Core Image filters, one panel at a time in
/// Lightroom's order: white balance → light (exposure, tone) → color → effects → detail → optics.
/// Each panel has its own file in Rendering/ (LightRenderer.swift, ColorRenderer.swift, …).
final class PhotoRenderer {
    let context: CIContext
    private let light: LightRenderer
    private let color: ColorRenderer
    private let effects: EffectsRenderer

    init() {
        let context = CIContext()
        self.context = context
        self.light = LightRenderer(context: context)
        self.color = ColorRenderer(context: context)
        self.effects = EffectsRenderer(context: context)
    }

    /// `value` gives a control's current value by id, or nil when controls.json has no such control.
    /// With HDR off the result is clipped to SDR white (1); with HDR on brighter levels survive.
    func apply(to image: CIImage, value: (String) -> Double?) -> CIImage {
        let hdr = (value("hdr") ?? 0) != 0
        var output = image
        output = color.input(output, value: value)  // film negative, white balance
        output = light.apply(output, value: value, hdr: hdr)
        output = color.apply(output, extent: image.extent, value: value)
        output = effects.apply(output, extent: image.extent, value: value)
        if !hdr {
            output = output.applyingFilter("CIColorClamp")
        }
        return output.cropped(to: image.extent)
    }

    /// The picture the white balance step works on (after film negative conversion): what the
    /// picker tools sample.
    func whiteBalanceInput(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        color.filmNegative(image, value: value)
    }

    /// Pixels for the screen. `hdr` keeps levels above white (half floats, extended Display P3),
    /// so an XDR display can show them brighter than SDR white.
    func uiImage(_ image: CIImage, hdr: Bool = false) -> UIImage? {
        let cg: CGImage?
        if hdr, let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            cg = context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: space)
        } else {
            cg = context.createCGImage(image, from: image.extent)
        }
        return cg.map { UIImage(cgImage: $0) }
    }

    /// 10-bit HEIF with the PQ (HDR10) curve, for saving HDR edits.
    func hdrHEIF(_ image: CIImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3_PQ) else { return nil }
        return try? context.heif10Representation(of: image, colorSpace: space, options: [:])
    }

    /// JPEG bytes (sRGB), as the render gallery saves them.
    func jpegData(_ image: CIImage) -> Data? {
        uiImage(image)?.jpegData(compressionQuality: 0.92)
    }

    /// The brightest channel value in the image, in linear light (1 = SDR white).
    func peak(of image: CIImage) -> Double {
        let filter = CIFilter.areaMaximum()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return 0 }
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return Double(max(pixel[0], pixel[1], pixel[2]))
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
