import CommandEngine
import CoreImage

/// The Creative panel (CreativeFilters in CommandEngine), after the crop and before the post-crop
/// vignette and grain, so the filters see the picture as framed. Every filter is a slider, 0 = off;
/// those that are on run in a fixed order: blur → tilt-shift. Sizes are shares of the picture's long side, so the
/// preview and the saved photo look alike. The Effect Center and Angle (Placement) are shared.
final class CreativeRenderer {
    let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    /// `extent` is the picture as framed (after the crop).
    func apply(_ image: CIImage, extent: CGRect, value: (String) -> Double?) -> CIImage {
        func v(_ id: String) -> Double { value(id) ?? 0 }
        let side = Double(max(extent.width, extent.height))
        let centre = Self.point(CreativeFilters.center(value: value), in: extent)
        // Effect Angle counts anticlockwise on the screen, as Core Image does (y up).
        let angle = v("effectAngle") * .pi / 180
        var output = image

        // Blur filters: motion, zoom and spin smear along a direction, a line to the centre or a
        // circle around it; the Gaussian blur softens everything.
        let motion = CreativeFilters.motionLength(v("motionBlur"), longSide: side)
        if motion > 0 {
            output = output.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: motion,
                kCIInputAngleKey: angle,
            ]).cropped(to: extent)
        }
        let zoom = CreativeFilters.zoomLength(v("zoomBlur"), longSide: side)
        if zoom > 0 {
            output = output.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: centre),
                "inputAmount": zoom,
            ]).cropped(to: extent)
        }
        let spin = CreativeFilters.spinAngle(v("spinBlur"))
        if spin > 0 {
            output = spinBlurred(output, extent: extent, center: centre, angle: spin)
        }
        let gaussian = CreativeFilters.gaussianRadius(v("gaussianBlur"), longSide: side)
        if gaussian > 0 {
            output = Filters.blurred(output, radius: gaussian, extent: extent)
        }

        // Tilt-shift, iris and field blur: sharp around the Effect Center (a band, a circle, or below a
        // line), more and more blurred away from it, through a mask (CreativeFilters.focusMask).
        let focusBlurs: [(id: String, kind: CreativeFilters.FocusBlur)] = [("tiltShift", .tiltShift), ("irisBlur", .iris), ("fieldBlur", .field)]
        for blur in focusBlurs {
            let radius = CreativeFilters.focusBlurRadius(v(blur.id), longSide: side)
            guard radius > 0 else { continue }
            let grid = Vignette.gridSize(width: Double(extent.width), height: Double(extent.height))
            let values = CreativeFilters.focusMask(blur.kind, width: grid.width, height: grid.height,
                                                   center: CreativeFilters.center(value: value),
                                                   size: (value("effectSize") ?? 30) / 100, angle: v("effectAngle"))
            let mask = Filters.mask(values, width: grid.width, height: grid.height, over: extent)
            output = output.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": mask.clampedToExtent(),
                kCIInputRadiusKey: radius,
            ]).cropped(to: extent)
        }
        return output
    }

    /// A point given from the top-left (0…1) in Core Image's coordinates of `extent` (y up).
    static func point(_ p: MaskPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + CGFloat(p.x) * extent.width, y: extent.minY + CGFloat(1 - p.y) * extent.height)
    }

    // MARK: - Blur

    /// Spin blur: each pixel is the average of 64 points on the arc through it around the centre
    /// (Core Image kernel language; the arc spans `angle` radians).
    private static let spinKernel: CIKernel? = CIKernel(source: """
        kernel vec4 spinBlur(sampler image, vec2 center, float angle) {
            vec2 d = destCoord() - center;
            vec4 sum = vec4(0.0);
            for (int i = 0; i < 64; i++) {
                float a = angle * (float(i) / 63.0 - 0.5);
                float c = cos(a);
                float s = sin(a);
                vec2 p = center + vec2(c * d.x - s * d.y, s * d.x + c * d.y);
                sum += sample(image, samplerTransform(image, p));
            }
            return sum / 64.0;
        }
        """)

    private func spinBlurred(_ image: CIImage, extent: CGRect, center: CGPoint, angle: Double) -> CIImage {
        guard let kernel = Self.spinKernel else { return image }
        // The arcs reach a little outside the picture: its edges repeat there.
        let reach = extent.insetBy(dx: -0.25 * max(extent.width, extent.height), dy: -0.25 * max(extent.width, extent.height))
        return kernel.apply(extent: extent, roiCallback: { _, _ in reach },
                            arguments: [image.clampedToExtent(), CIVector(cgPoint: center), angle]) ?? image
    }
}
