import CommandEngine
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Turns control values (see controls.json) into Core Image filters, one panel at a time in
/// Lightroom's processing order: optics (lens fixes, on the photo as shot) → film negative →
/// retouching (spots and brush strokes, early as Lightroom's spot removal) → portrait depth (blur and
/// lighting of iPhone Portrait photos) → white balance → light
/// (exposure, tone) → color → effects → detail → masks (local adjustments) → geometry (crop, turns,
/// transforms) → creative filters (blur, distort, …, on the picture as framed) → vignette and grain
/// (after the crop, as Lightroom's post-crop vignette).
/// Each panel has its own file in Rendering/ (LightRenderer.swift, …).
final class PhotoRenderer {
    let context: CIContext
    private let light: LightRenderer
    private let color: ColorRenderer
    private let effects: EffectsRenderer
    private let detail: DetailRenderer
    private let optics: OpticsRenderer
    private let masks: MaskRenderer
    let retouch: RetouchRenderer
    let geometry: GeometryRenderer
    let portrait: PortraitRenderer
    private let creative: CreativeRenderer
    /// The geometry of the last render (the editor maps touches on the preview back through it).
    private(set) var lastPlan: GeometryPlan?
    /// Every control by id (a mask's local pass leaves all but its own sliders at their defaults).
    private let controls: [String: Control]

    init() {
        let context = CIContext()
        self.context = context
        self.light = LightRenderer(context: context)
        self.color = ColorRenderer(context: context)
        self.effects = EffectsRenderer(context: context)
        self.detail = DetailRenderer(context: context)
        self.optics = OpticsRenderer(context: context)
        self.masks = MaskRenderer(context: context)
        self.retouch = RetouchRenderer(context: context)
        self.geometry = GeometryRenderer(context: context)
        self.portrait = PortraitRenderer(context: context)
        self.creative = CreativeRenderer(context: context)
        let registry = (try? ControlRegistry.bundled()) ?? ControlRegistry(controls: [])
        self.controls = Dictionary(registry.controls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
    /// as a red tint (preview only). `retouches`: spots and brush strokes; with `waitForRetouch` false
    /// new ones may show a moment later (worked out in the background, see RetouchRenderer).
    /// `visualize`: Visualize Spots' threshold when it is on (preview only). `geometry`: what the
    /// Geometry panel's touch tools made; `stage`: how much of the geometry to show (the crop tool
    /// shows the whole frame); `previewScale`: the preview's size ÷ the full photo's (nil when saving),
    /// so Resize keeps the preview no sharper than the saved photo.
    func apply(to image: CIImage, value: (String) -> Double?, masks: [Mask] = [], overlay: Mask? = nil,
               retouches: [Retouch] = [], waitForRetouch: Bool = true, visualize: Double? = nil,
               geometry edits: GeometryEdits = GeometryEdits(), stage: GeometryStage = .full, previewScale: Double? = nil) -> CIImage {
        let hdr = (value("hdr") ?? 0) != 0
        let extent = image.extent
        // Lens corrections, then film negative conversion: the picture range masks and pickers look at.
        let lensFixed = color.filmNegative(optics.apply(image, value: value), value: value)
        let lensKey = Self.opticsIDs.map { value($0) ?? 0 }
        geometry.use(lensFixed, key: lensKey)  // what Upright, content-aware scale, … read
        let retouched = retouch.apply(lensFixed, steps: retouches, source: image, key: lensKey, wait: waitForRetouch)
        var output = color.whiteBalance(portrait.apply(retouched, value: value), value: value)
        output = light.apply(output, value: value, hdr: hdr)
        output = color.apply(output, extent: extent, value: value)
        output = effects.apply(output, extent: extent, value: value)
        output = detail.apply(output, extent: extent, value: value)
        for mask in masks where !mask.components.isEmpty && (mask.settings["maskAmount"] ?? 100) > 0
            && mask.adjustments.contains(where: { controls[$0.key]?.defaultValue != $0.value }) {
            let shape = self.masks.image(of: mask, photo: lensFixed, source: image, lensKey: lensKey, extent: extent)
            output = Filters.blend(local(output, mask: mask, extent: extent, hdr: hdr), over: output, mask: shape)
        }
        let plan = geometry.plan(extent: extent, value: value, edits: edits, stage: stage, previewScale: previewScale)
        lastPlan = plan
        output = geometry.shape(output, plan: plan, clampEdges: stage == .full)
        let shaped = plan.isShapeIdentity ? extent : output.extent
        output = creative.apply(output, extent: shaped, value: value)  // blur, distort, … filters
        output = effects.finish(output, extent: shaped, value: value)  // vignette, grain
        if !hdr {
            output = output.applyingFilter("CIColorClamp")
        }
        if let threshold = visualize {
            output = visualized(output, extent: shaped, threshold: threshold)
        }
        if let overlay, !overlay.components.isEmpty {
            let shape = self.masks.image(of: overlay, photo: lensFixed, source: image, lensKey: lensKey, extent: extent)
            output = MaskRenderer.overlay(output, mask: geometry.shape(shape, plan: plan), extent: shaped)
        }
        output = geometry.frame(output, plan: plan)  // resize
        return output.cropped(to: plan.isFrameIdentity ? shaped : output.extent)
    }

    /// Auto Straighten: the Straighten angle that levels the lines of the photo last rendered (nil
    /// when it has none near level or upright).
    func autoStraightenAngle() -> Double? {
        guard let plan = lastPlan else { return nil }
        return Straighten.autoAngle(geometry.segments(), width: plan.sourceWidth, height: plan.sourceHeight, transform: plan.preStraighten)
    }

    /// Perspective crop: the corners of the largest four-sided shape along the photo's lines (nil when
    /// there is none).
    func detectedQuad() -> [MaskPoint]? {
        guard let plan = lastPlan else { return nil }
        return PerspectiveCrop.detect(geometry.segments(), width: plan.sourceWidth, height: plan.sourceHeight)
    }

    /// A mask's local adjustments on the globally edited picture: the same panels in the same order,
    /// with every slider at its default except the mask's own, scaled by its Amount (exposure −1
    /// inside the mask is one stop darker than the global result there).
    private func local(_ image: CIImage, mask: Mask, extent: CGRect, hdr: Bool) -> CIImage {
        let controls = self.controls
        let value: (String) -> Double? = { id in
            guard let control = controls[id] else { return nil }
            return mask.localValue(control) ?? control.defaultValue
        }
        var output = color.input(image, value: value)  // temperature, tint
        output = light.apply(output, value: value, hdr: hdr)
        output = color.apply(output, extent: extent, value: value)
        output = effects.apply(output, extent: extent, value: value)
        return detail.apply(output, extent: extent, value: value)
    }

    /// Visualize Spots: how far each pixel's brightness is from its surroundings (a high pass, blurred
    /// over 4 px of a 2048 px photo), shown white on black and stretched by the threshold.
    private func visualized(_ image: CIImage, extent: CGRect, threshold: Double) -> CIImage {
        let luma = Filters.luma(Filters.encoded(image))
        let blur = Filters.blurred(luma, radius: Detail.pixels(4, longSide: Double(max(extent.width, extent.height))), extent: extent)
        let difference = luma.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: blur])
        return Filters.linear(Filters.lookup(difference, table: VisualizeSpots.table(threshold: threshold))).cropped(to: extent)
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
