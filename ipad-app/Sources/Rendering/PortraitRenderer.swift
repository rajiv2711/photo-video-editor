import CommandEngine
import CoreImage

/// Portrait depth editing (Merge panel, Portrait section) for photos that carry a depth map (iPhone
/// Portrait mode): background blur by distance from the focus depth (CIMaskedVariableBlur through a
/// mask worked out by Portrait in CommandEngine), then a lighting preset through the subject's mask.
/// Runs early, on the photo as shot (after lens fixes and retouching), so every slider works on top.
final class PortraitRenderer {
    let context: CIContext
    /// The photo's depth, or nil (no depth effects).
    var depth: Portrait.DepthMap?

    init(context: CIContext) {
        self.context = context
    }

    func apply(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        guard let depth else { return image }
        let extent = image.extent
        var output = image
        let radius = Portrait.blurRadius(aperture: value("portraitAperture") ?? 16, longSide: Double(max(extent.width, extent.height)))
        if radius > 0.5 {
            let focus = Float((value("focusDepth") ?? 100) / 100)
            let mask = Filters.mask(Portrait.blurMask(depth, focus: focus), width: depth.width, height: depth.height, over: extent)
            output = output.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": mask.clampedToExtent(),
                kCIInputRadiusKey: radius,
            ]).cropped(to: extent)
        }
        let i = Int(value("portraitLighting") ?? 0)
        let lighting = Portrait.lightings.indices.contains(i) ? Portrait.lightings[i] : "natural"
        guard lighting != "natural" else { return output }
        let subject = depth.subject
        let mask = Filters.mask(subject, width: depth.width, height: depth.height, over: extent)
        switch lighting {
        case "studio":
            // The subject a little over half a stop brighter.
            return Filters.blend(Filters.affine(output, scale: 1.45), over: output, mask: mask)
        case "contour":
            // Light falling off towards the subject's edges (shading that sculpts), its middle a touch brighter.
            let inner = Grid.blur(subject, width: depth.width, height: depth.height, radius: max(1, max(depth.width, depth.height) / 30))
            let shade = Filters.mask(inner.map { 0.55 + 0.6 * $0 }, width: depth.width, height: depth.height, over: extent)
            let shaded = output.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: shade])
            return Filters.blend(shaded, over: output, mask: mask)
        case "stage", "stageMono":
            // The background goes black; the subject a little brighter.
            let lit = Filters.affine(output, scale: 1.2)
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
            let staged = Filters.blend(lit, over: black, mask: mask)
            return lighting == "stage" ? staged : Filters.luma(staged)
        case "highKeyMono":
            // A grey subject on white.
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
            return Filters.blend(Filters.luma(Filters.affine(output, scale: 1.1)), over: white, mask: mask)
        default:
            return output
        }
    }

    /// A depth map from a photo's disparity (or depth) picture and its portrait matte: read on a grid
    /// of at most 512 cells on the long side.
    static func depthMap(disparity: CIImage, isDepth: Bool, matte: CIImage?, context: CIContext) -> Portrait.DepthMap? {
        guard let grid = values(of: disparity, context: context) else { return nil }
        let raw = isDepth ? grid.values.map { $0 > 1e-6 ? 1 / $0 : 0 } : grid.values
        let matteValues = matte.flatMap { values(of: $0, context: context, width: grid.width, height: grid.height)?.values }
        return Portrait.DepthMap(disparity: raw, width: grid.width, height: grid.height, matte: matteValues)
    }

    /// A one-channel picture's numbers (its red channel, no colour conversion), at most 512 cells on
    /// the long side, or stretched to `width` × `height`.
    static func values(of image: CIImage, context: CIContext, width: Int? = nil, height: Int? = nil) -> (values: [Float], width: Int, height: Int)? {
        let e = image.extent
        guard e.width >= 1, e.height >= 1 else { return nil }
        let scale = min(1, 512 / max(e.width, e.height))
        let w = width ?? max(1, Int(e.width * scale)), h = height ?? max(1, Int(e.height * scale))
        let target = CGRect(x: 0, y: 0, width: w, height: h)
        let scaled = Filters.resized(image, to: target)
        var rgba = [Float](repeating: 0, count: w * h * 4)
        context.render(scaled, toBitmap: &rgba, rowBytes: w * 16, bounds: target, format: .RGBAf, colorSpace: nil)
        return ((0..<(w * h)).map { rgba[4 * $0] }, w, h)
    }
}
