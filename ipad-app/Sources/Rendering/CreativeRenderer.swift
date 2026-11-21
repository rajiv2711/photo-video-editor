import CommandEngine
import CoreImage

/// The Creative panel (CreativeFilters in CommandEngine), after the crop and before the post-crop
/// vignette and grain, so the filters see the picture as framed. Every filter is a slider, 0 = off;
/// those that are on run in a fixed order: distort → blur → tilt-shift. Sizes are shares of the picture's long side, so the
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
        let size = (value("effectSize") ?? 30) / 100
        var output = image

        // Distort filters move pixels: twirl, pinch and spherize inside a circle around the centre,
        // ripple and wave over the whole picture, then polar coordinates.
        let twirl = v("twirl")
        if twirl != 0 {
            output = output.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: centre),
                kCIInputRadiusKey: CreativeFilters.distortRadius(size: size, longSide: side),
                kCIInputAngleKey: twirl * .pi / 180,
            ]).cropped(to: extent)
        }
        let radius = CreativeFilters.distortRadius(size: size, longSide: side)
        if v("pinch") != 0 {
            output = warped(output, kernel: Self.pinchKernel, extent: extent, reach: radius,
                            arguments: [CIVector(cgPoint: centre), radius, CreativeFilters.pinchPower(v("pinch"))])
        }
        if v("spherize") != 0 {
            output = warped(output, kernel: Self.spherizeKernel, extent: extent, reach: radius,
                            arguments: [CIVector(cgPoint: centre), radius, v("spherize") / 100])
        }
        if v("ripple") > 0 {
            let ripple = CreativeFilters.ripple(v("ripple"), size: size, longSide: side)
            output = warped(output, kernel: Self.rippleKernel, extent: extent, reach: ripple.amplitude,
                            arguments: [CIVector(cgPoint: centre), ripple.amplitude, ripple.wavelength])
        }
        if v("wave") > 0 {
            let wave = CreativeFilters.wave(v("wave"), size: size, longSide: side)
            output = warped(output, kernel: Self.waveKernel, extent: extent, reach: wave.amplitude,
                            arguments: [CIVector(cgPoint: centre), wave.amplitude, wave.wavelength,
                                        CIVector(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))])
        }
        if v("polarCoordinates") != 0 {
            let rim = 0.5 * Double(hypot(extent.width, extent.height))
            output = warped(output, kernel: Self.polarKernel, extent: extent, reach: side,
                            arguments: [CIVector(cgPoint: centre), CIVector(cgRect: extent), rim])
        }

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

    // MARK: - Distort

    /// `image` read through a warp kernel (each output pixel reads the point the kernel gives; the
    /// picture's edges repeat outside it). `reach`: how far the kernel may read from a pixel.
    private func warped(_ image: CIImage, kernel: CIWarpKernel?, extent: CGRect, reach: Double, arguments: [Any]) -> CIImage {
        guard let kernel else { return image }
        let r = CGFloat(reach) + 2
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -r, dy: -r) },
                            image: image.clampedToExtent(), arguments: arguments)?.cropped(to: extent) ?? image
    }

    /// Pinch (CreativeFilters.pinchSource): d × sin(π/2 × r)^−k inside the circle.
    private static let pinchKernel: CIWarpKernel? = CIWarpKernel(source: """
        kernel vec2 pinch(vec2 center, float radius, float power) {
            vec2 d = destCoord() - center;
            float r = clamp(length(d) / radius, 0.0001, 1.0);
            return center + d * pow(sin(1.5707963 * r), -power);
        }
        """)

    /// Spherize (CreativeFilters.spherizeSource): 2/π × asin(r) or sin(π/2 × r), mixed in by |amount|.
    private static let spherizeKernel: CIWarpKernel? = CIWarpKernel(source: """
        kernel vec2 spherize(vec2 center, float radius, float amount) {
            vec2 d = destCoord() - center;
            float r = clamp(length(d) / radius, 0.0001, 1.0);
            float target = mix(sin(1.5707963 * r), 0.6366198 * asin(r), step(0.0, amount));
            float s = mix(r, target, abs(amount));
            return center + d * (s / r);
        }
        """)

    /// Ripple: each pixel reads a little nearer or farther from the centre, along sine rings.
    private static let rippleKernel: CIWarpKernel? = CIWarpKernel(source: """
        kernel vec2 ripple(vec2 center, float amplitude, float wavelength) {
            vec2 d = destCoord() - center;
            float r = length(d);
            return destCoord() + d / max(r, 0.0001) * amplitude * sin(6.2831853 * r / wavelength);
        }
        """)

    /// Wave: each pixel reads a little to the side, along sine waves running in `direction`.
    private static let waveKernel: CIWarpKernel? = CIWarpKernel(source: """
        kernel vec2 wave(vec2 center, float amplitude, float wavelength, vec2 direction) {
            float t = dot(destCoord() - center, direction);
            return destCoord() + vec2(-direction.y, direction.x) * amplitude * sin(6.2831853 * t / wavelength);
        }
        """)

    /// Polar coordinates (CreativeFilters.polarSource): the distance from the centre picks the row
    /// (bottom edge in the middle, top edge at `rim`), the direction the column. `box`: the picture.
    private static let polarKernel: CIWarpKernel? = CIWarpKernel(source: """
        kernel vec2 polar(vec2 center, vec4 box, float rim) {
            vec2 d = destCoord() - center;
            float r = min(length(d) / rim, 1.0);
            float a = atan(-d.x, -d.y);
            return vec2(box.x + (a / 6.2831853 + 0.5) * box.z, box.y + r * box.w);
        }
        """)

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
