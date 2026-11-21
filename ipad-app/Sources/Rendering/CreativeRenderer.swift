import CommandEngine
import CoreImage

/// The Creative panel (CreativeFilters in CommandEngine), after the crop and before the post-crop
/// vignette and grain, so the filters see the picture as framed. Every filter is a slider, 0 = off;
/// those that are on run in a fixed order: distort → blur → tilt-shift → stylize → artistic → pixelate. Sizes are shares of the picture's long side, so the
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

        // Stylize filters, on sRGB levels: oil paint, emboss, find edges, wind.
        let oil = CreativeFilters.oilRadius(v("oilPaint"), longSide: side)
        if oil > 0.5 {
            output = Filters.linear(painted(Filters.encoded(output), extent: extent, radius: oil))
        }
        if v("emboss") > 0 {
            let emboss = CreativeFilters.emboss(v("emboss"), longSide: side)
            let light = CreativeFilters.embossLightAngle(v("effectAngle")) * .pi / 180
            let offset = CIVector(x: CGFloat(cos(light) * emboss.offset), y: CGFloat(sin(light) * emboss.offset))
            output = Filters.linear(apply(Self.embossKernel, to: Filters.encoded(output), extent: extent, reach: emboss.offset,
                                          arguments: [offset, emboss.height]))
        }
        let edges = v("findEdges") / 100
        if edges > 0 {
            let offset = CreativeFilters.edgeOffset(longSide: side)
            let encoded = Filters.encoded(output)
            let found = apply(Self.edgesKernel, to: encoded, extent: extent, reach: offset, arguments: [offset, 2.5])
            output = Filters.linear(Filters.mix(encoded, found, edges))
        }
        if v("wind") > 0 {
            let wind = CreativeFilters.wind(v("wind"), longSide: side)
            output = Filters.linear(apply(Self.windKernel, to: Filters.encoded(output), extent: extent, reach: wind.length,
                                          arguments: [CIVector(x: CGFloat(cos(angle)), y: CGFloat(sin(angle))), wind.length, wind.band]))
        }

        // Artistic filters, on sRGB levels: watercolor, sketch, cartoon, cutout.
        let watercolor = v("watercolor")
        if watercolor > 0 {
            output = Filters.linear(watercolored(Filters.encoded(output), extent: extent, amount: watercolor))
        }
        let sketch = v("sketch")
        if sketch > 0 {
            // Pencil sketch: the grey picture colour-dodged by its blurred negative, so only the edges
            // stay dark, then darkened.
            let grey = Filters.luma(Filters.encoded(output))
            let negative = Filters.blurred(Filters.affine(grey, scale: -1, bias: 1),
                                           radius: CreativeFilters.sketchStroke(sketch, longSide: side), extent: extent)
            let dodged = negative.applyingFilter("CIColorDodgeBlendMode", parameters: [kCIInputBackgroundImageKey: grey])
                .applyingFilter("CIColorClamp")
            output = Filters.linear(Filters.lookup(dodged, table: CreativeFilters.sketchTable(sketch)))
        }
        let cartoon = v("cartoon")
        if cartoon > 0 {
            // Smoothed colours in a few flat tones, inked where the smoothed picture changes sharply.
            let r = max(1, CreativeFilters.paintRadius(cartoon, longSide: side))
            let smooth = Filters.blurred(painted(Filters.encoded(output), extent: extent, radius: r), radius: 0.002 * side, extent: extent)
            let flat = toneBanded(smooth, extent: extent, levels: 6)
            let offset = CreativeFilters.edgeOffset(longSide: side)
            output = Filters.linear(apply(Self.edgeDarkenKernel, to: smooth, extent: extent, reach: offset,
                                          arguments: [flat.clampedToExtent(), offset, 12.5, 0.08, 1.0]))
        }
        let cutout = v("cutout")
        if cutout > 0 {
            // Paper shapes: smoothed hard, then a few flat tones.
            let r = max(1, CreativeFilters.paintRadius(cutout, longSide: side, cutout: true))
            let smooth = Filters.blurred(painted(Filters.encoded(output), extent: extent, radius: r), radius: 0.6 * r, extent: extent)
            output = Filters.linear(toneBanded(smooth, extent: extent, levels: CreativeFilters.cutoutLevels(cutout)))
        }

        // Pixelate filters: square cells from the picture's top-left corner, crystal cells, or a
        // colour halftone (CMYK dots on white, on sRGB levels so the midtones get mid-size dots).
        let corner = CIVector(x: extent.minX, y: extent.maxY)
        let cell = CreativeFilters.mosaicCell(v("mosaic"), longSide: side)
        if cell >= 1 {
            output = output.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: corner,
                kCIInputScaleKey: cell,
            ]).cropped(to: extent)
        }
        let crystal = CreativeFilters.crystalRadius(v("crystallize"), longSide: side)
        if crystal >= 1 {
            output = output.clampedToExtent().applyingFilter("CICrystallize", parameters: [
                kCIInputCenterKey: corner,
                kCIInputRadiusKey: crystal,
            ]).cropped(to: extent)
        }
        let dots = CreativeFilters.halftoneSpacing(v("halftone"), longSide: side)
        if dots >= 2 {
            output = Filters.linear(Filters.encoded(output).clampedToExtent().applyingFilter("CICMYKHalftone", parameters: [
                kCIInputCenterKey: corner,
                "inputWidth": dots,
                kCIInputAngleKey: 0,
                "inputSharpness": 0.7,
                "inputGCR": 1,
                "inputUCR": 0.5,
            ]).cropped(to: extent))
        }
        return output
    }

    /// A point given from the top-left (0…1) in Core Image's coordinates of `extent` (y up).
    static func point(_ p: MaskPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + CGFloat(p.x) * extent.width, y: extent.minY + CGFloat(1 - p.y) * extent.height)
    }

    /// `image` through a kernel that reads its neighbours up to `reach` pixels away (the picture's
    /// edges repeat outside it); the kernel's first argument is the picture.
    private func apply(_ kernel: CIKernel?, to image: CIImage, extent: CGRect, reach: Double, arguments: [Any]) -> CIImage {
        guard let kernel else { return image }
        let r = CGFloat(reach) + 2
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -r, dy: -r) },
                            arguments: [image.clampedToExtent() as Any] + arguments)?.cropped(to: extent) ?? image
    }

    // MARK: - Stylize

    /// Oil paint: the Kuwahara filter. Each pixel takes the mean colour of whichever of the four
    /// squares it is a corner of (5 × 5 samples across `radius`) has the least variance, so flat
    /// patches form while edges stay sharp, like brush strokes.
    private static let oilKernel: CIKernel? = CIKernel(source: """
        kernel vec4 oilPaint(sampler image, float radius) {
            vec2 c = destCoord();
            float spacing = radius / 4.0;
            vec3 m0 = vec3(0.0); vec3 m1 = vec3(0.0); vec3 m2 = vec3(0.0); vec3 m3 = vec3(0.0);
            vec3 s0 = vec3(0.0); vec3 s1 = vec3(0.0); vec3 s2 = vec3(0.0); vec3 s3 = vec3(0.0);
            for (int j = 0; j < 5; j++) {
                for (int i = 0; i < 5; i++) {
                    vec2 o = vec2(float(i), float(j)) * spacing;
                    vec3 a = sample(image, samplerTransform(image, c + vec2(-o.x, -o.y))).rgb;
                    vec3 b = sample(image, samplerTransform(image, c + vec2(o.x, -o.y))).rgb;
                    vec3 d = sample(image, samplerTransform(image, c + vec2(-o.x, o.y))).rgb;
                    vec3 e = sample(image, samplerTransform(image, c + o)).rgb;
                    m0 += a; s0 += a * a;
                    m1 += b; s1 += b * b;
                    m2 += d; s2 += d * d;
                    m3 += e; s3 += e * e;
                }
            }
            m0 /= 25.0; m1 /= 25.0; m2 /= 25.0; m3 /= 25.0;
            vec3 w = vec3(1.0);
            float v0 = dot(abs(s0 / 25.0 - m0 * m0), w);
            float v1 = dot(abs(s1 / 25.0 - m1 * m1), w);
            float v2 = dot(abs(s2 / 25.0 - m2 * m2), w);
            float v3 = dot(abs(s3 / 25.0 - m3 * m3), w);
            vec3 best = m0;
            float least = v0;
            float t = step(v1, least); best = mix(best, m1, t); least = mix(least, v1, t);
            t = step(v2, least); best = mix(best, m2, t); least = mix(least, v2, t);
            t = step(v3, least); best = mix(best, m3, t);
            return vec4(best, sample(image, samplerCoord(image)).a);
        }
        """)

    /// Emboss: a grey relief, the brightness read as height and lit from the side `offset` points to.
    private static let embossKernel: CIKernel? = CIKernel(source: """
        kernel vec4 emboss(sampler image, vec2 offset, float height) {
            vec2 c = destCoord();
            vec3 w = vec3(0.2126, 0.7152, 0.0722);
            float toLight = dot(sample(image, samplerTransform(image, c + offset)).rgb, w);
            float away = dot(sample(image, samplerTransform(image, c - offset)).rgb, w);
            float g = clamp(0.5 + height * (away - toLight), 0.0, 1.0);
            return vec4(g, g, g, sample(image, samplerCoord(image)).a);
        }
        """)

    /// Find edges: white paper with the edges drawn in their own colour, darker where the colour
    /// changes more across the pixel.
    private static let edgesKernel: CIKernel? = CIKernel(source: """
        kernel vec4 findEdges(sampler image, float offset, float gain) {
            vec2 c = destCoord();
            vec4 here = sample(image, samplerCoord(image));
            vec3 l = sample(image, samplerTransform(image, c - vec2(offset, 0.0))).rgb;
            vec3 r = sample(image, samplerTransform(image, c + vec2(offset, 0.0))).rgb;
            vec3 d = sample(image, samplerTransform(image, c - vec2(0.0, offset))).rgb;
            vec3 u = sample(image, samplerTransform(image, c + vec2(0.0, offset))).rgb;
            vec3 e = abs(r - l) + abs(u - d);
            float k = clamp(gain * max(e.r, max(e.g, e.b)), 0.0, 1.0);
            return vec4(mix(vec3(1.0), here.rgb, k), here.a);
        }
        """)

    /// Wind: light parts streak downwind (along `direction`). Each pixel keeps the brightest of 24
    /// points upwind, faded with distance; bands across the wind get streaks of different lengths.
    private static let windKernel: CIKernel? = CIKernel(source: """
        kernel vec4 wind(sampler image, vec2 direction, float len, float band) {
            vec2 c = destCoord();
            vec4 here = sample(image, samplerCoord(image));
            float row = floor(dot(c, vec2(-direction.y, direction.x)) / band);
            float random = fract(sin(row * 12.9898) * 43758.5453);
            float reach = len * (0.3 + 0.7 * random);
            vec4 best = here;
            for (int i = 1; i <= 24; i++) {
                float t = float(i) / 24.0;
                vec4 s = sample(image, samplerTransform(image, c - direction * (t * reach)));
                best = max(best, mix(here, s, 1.0 - t));
            }
            return best;
        }
        """)

    // MARK: - Artistic

    /// The Kuwahara filter (oil paint's brush) over `radius` pixels.
    private func painted(_ image: CIImage, extent: CGRect, radius: Double) -> CIImage {
        apply(Self.oilKernel, to: image, extent: extent, reach: radius, arguments: [radius])
    }

    /// `levels` flat tones placed by the picture's own brightness (CreativeFilters.toneBands): each
    /// pixel's brightness moves to its tone's, its colour differences kept. On sRGB levels.
    private func toneBanded(_ image: CIImage, extent: CGRect, levels: Int) -> CIImage {
        guard let kernel = Self.toneKernel else { return image }
        let histogram = ImageStats.lumaHistogram(of: Filters.linear(image), extent: extent, context: context)
        let tone = Filters.lookup(Filters.luma(image), table: CreativeFilters.toneBands(histogram: histogram, levels: levels))
        return kernel.apply(extent: extent, arguments: [image, tone]) ?? image
    }

    private static let toneKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 toTone(__sample c, __sample tone) {
            float l = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
            return vec4(clamp(c.rgb + (tone.r - l), 0.0, 1.0), c.a);
        }
        """)

    /// Darkens `colours` where `lines` changes across the pixel (the largest channel difference over
    /// `offset` pixels each way, past `threshold`, × `gain`), by up to `depth`: cartoon ink, watercolor's
    /// pigment gathering at the edge of a wash.
    private static let edgeDarkenKernel: CIKernel? = CIKernel(source: """
        kernel vec4 darkenEdges(sampler lines, sampler colours, float offset, float gain, float threshold, float depth) {
            vec2 c = destCoord();
            vec3 l = sample(lines, samplerTransform(lines, c - vec2(offset, 0.0))).rgb;
            vec3 r = sample(lines, samplerTransform(lines, c + vec2(offset, 0.0))).rgb;
            vec3 d = sample(lines, samplerTransform(lines, c - vec2(0.0, offset))).rgb;
            vec3 u = sample(lines, samplerTransform(lines, c + vec2(0.0, offset))).rgb;
            vec3 e = abs(r - l) + abs(u - d);
            float k = clamp(gain * (max(e.r, max(e.g, e.b)) - threshold), 0.0, 1.0);
            vec4 here = sample(colours, samplerCoord(colours));
            return vec4(here.rgb * (1.0 - depth * k), here.a);
        }
        """)

    /// Watercolor (sRGB levels): smoothed washes, half pooled into 8 tones, pigment darkening their
    /// edges, a faint paper grain and the paper's white showing through.
    private func watercolored(_ image: CIImage, extent: CGRect, amount: Double) -> CIImage {
        let side = Double(max(extent.width, extent.height))
        let r = max(1, CreativeFilters.paintRadius(amount, longSide: side))
        let wash = Filters.blurred(painted(image, extent: extent, radius: r), radius: 0.6 * r, extent: extent)
        let pooled = Filters.mix(wash, toneBanded(wash, extent: extent, levels: 8), 0.5)
        let offset = max(1, 0.0015 * side)
        let edged = apply(Self.edgeDarkenKernel, to: pooled, extent: extent, reach: offset,
                          arguments: [pooled.clampedToExtent(), offset, 4.0, 0.0, 0.5])
        let lighter = Filters.affine(edged, scale: 0.9, bias: 0.1)
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return lighter }
        // Paper: the fixed random pattern in cells of 0.4 % of the long side, softened (about ±1.5 %).
        let cell = CGFloat(max(1, 0.004 * side))
        let area = CGRect(x: 0, y: 0, width: extent.width / cell + 4, height: extent.height / cell + 4)
        let grain = Filters.luma(random.cropped(to: area).settingAlphaOne(in: area))
            .transformed(by: CGAffineTransform(translationX: extent.minX - 2 * cell, y: extent.minY - 2 * cell).scaledBy(x: cell, y: cell))
            .clampedToExtent().applyingGaussianBlur(sigma: Double(cell)).cropped(to: extent)
        let paper = Filters.affine(grain, scale: 0.15, bias: 1 - 0.075)
        return lighter.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: paper])
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
