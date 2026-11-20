import CommandEngine
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Turns control values (see controls.json) into Core Image filters, one panel at a time in
/// Lightroom's processing order: optics (lens fixes, on the photo as shot) → film negative and white
/// balance → light (exposure, tone) → color → effects → detail → masks (local adjustments) →
/// vignette and grain last. Each panel has its own file in Rendering/ (LightRenderer.swift, …).
final class PhotoRenderer {
    let context: CIContext
    private let light: LightRenderer
    private let color: ColorRenderer
    private let effects: EffectsRenderer
    private let detail: DetailRenderer
    private let optics: OpticsRenderer
    private let masks: MaskRenderer
    /// Every control's default (a mask's local pass leaves all but its own sliders there).
    private let defaults: [String: Double]

    init() {
        let context = CIContext()
        self.context = context
        self.light = LightRenderer(context: context)
        self.color = ColorRenderer(context: context)
        self.effects = EffectsRenderer(context: context)
        self.detail = DetailRenderer(context: context)
        self.optics = OpticsRenderer(context: context)
        self.masks = MaskRenderer(context: context)
        let registry = (try? ControlRegistry.bundled()) ?? ControlRegistry(controls: [])
        self.defaults = Dictionary(registry.controls.map { ($0.id, $0.defaultValue) }, uniquingKeysWith: { a, _ in a })
    }

    /// The photo's lens (EXIF), for Lens Profile Correction.
    var lens: PhotoLens {
        get { optics.lens }
        set { optics.lens = newValue }
    }

    /// The bundled lens profile that fits the photo's lens, if any.
    var lensProfileName: String? {
        optics.profile?.profile.model
    }

    /// `value` gives a control's current value by id, or nil when controls.json has no such control.
    /// With HDR off the result is clipped to SDR white (1); with HDR on brighter levels survive.
    /// `masks`: local adjustments, each blended in through its mask; `overlay`: a mask to show
    /// as a red tint (preview only).
    func apply(to image: CIImage, value: (String) -> Double?, masks: [Mask] = [], overlay: Mask? = nil) -> CIImage {
        let hdr = (value("hdr") ?? 0) != 0
        let extent = image.extent
        // Lens corrections, then film negative conversion: the picture range masks and pickers look at.
        let lensFixed = color.filmNegative(optics.apply(image, value: value), value: value)
        let lensKey = Self.opticsIDs.map { value($0) ?? 0 }
        var output = color.whiteBalance(lensFixed, value: value)
        output = light.apply(output, value: value, hdr: hdr)
        output = color.apply(output, extent: extent, value: value)
        output = effects.apply(output, extent: extent, value: value)
        output = detail.apply(output, extent: extent, value: value)
        for mask in masks where !mask.components.isEmpty && mask.adjustments.contains(where: { defaults[$0.key] != $0.value }) {
            let shape = self.masks.image(of: mask, photo: lensFixed, source: image, lensKey: lensKey, extent: extent)
            output = Filters.blend(local(output, mask: mask, extent: extent, hdr: hdr), over: output, mask: shape)
        }
        output = effects.finish(output, extent: extent, value: value)  // vignette, grain
        if !hdr {
            output = output.applyingFilter("CIColorClamp")
        }
        if let overlay, !overlay.components.isEmpty {
            let shape = self.masks.image(of: overlay, photo: lensFixed, source: image, lensKey: lensKey, extent: extent)
            output = MaskRenderer.overlay(output, mask: shape, extent: extent)
        }
        return output.cropped(to: extent)
    }

    /// A mask's local adjustments on the globally edited picture: the same panels in the same order,
    /// with every slider at its default except the mask's own (exposure −1 inside the mask is one
    /// stop darker than the global result there).
    private func local(_ image: CIImage, mask: Mask, extent: CGRect, hdr: Bool) -> CIImage {
        let defaults = self.defaults
        let value: (String) -> Double? = { id in mask.adjustments[id] ?? defaults[id] }
        var output = color.input(image, value: value)  // temperature, tint
        output = light.apply(output, value: value, hdr: hdr)
        output = color.apply(output, extent: extent, value: value)
        output = effects.apply(output, extent: extent, value: value)
        return detail.apply(output, extent: extent, value: value)
    }

    /// The lens settings and film negative conversion: when they change, the picture masks look at changes too.
    static let opticsIDs = ["lensProfile", "removeCA", "caRedCyan", "caBlueYellow", "defringePurple", "defringePurpleHue",
                            "defringeGreen", "defringeGreenHue", "distortion", "lensVignetting", "lensVignettingMidpoint",
                            "fisheye", "filmNegative"]

    /// The picture the white balance step works on (after lens corrections and film negative
    /// conversion): what the picker tools sample.
    func whiteBalanceInput(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        color.filmNegative(optics.apply(image, value: value), value: value)
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
