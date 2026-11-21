import CommandEngine
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Geometry panel, at the end of the pipeline (the maths is GeometryPlan in CommandEngine). The
/// edited photo is put into its frame by one transform H (affine on the GPU with `transformed(by:)`,
/// or CIPerspectiveTransform when it has perspective) and cropped; content-aware scale then reads it
/// through a WarpMap (a small Core Image kernel). Everything before it (masks, retouching, pickers)
/// works on the photo's own pixels, so nothing has to follow the crop.
final class GeometryRenderer {
    let context: CIContext

    /// Bumped by the editor when another photo is opened (what was read from the photo is kept until then).
    var photoGeneration = 0
    /// The photo after lens corrections (Upright, Auto Straighten, perspective crop and content-aware
    /// scale read it) and a key for it: its lens settings and the photo generation.
    private var photo: (picture: CIImage, key: [Double])?
    /// What was read from it: a grey copy of at most 800 px, its straight lines, the content-aware map.
    private var grayCache: (key: [Double], pixels: [Float], width: Int, height: Int)?
    private var lineCache: (key: [Double], segments: [LineSegment])?
    private var mapCache: (key: [Double], map: WarpMap)?

    init(context: CIContext) {
        self.context = context
    }

    /// The photo after lens corrections, for this render (`key`: the lens settings). Nothing is read
    /// from it until a tool needs it.
    func use(_ picture: CIImage, key: [Double]) {
        photo = (picture, key + [Double(photoGeneration)])
    }

    /// The photo's brightness (sRGB levels) on a copy of at most 800 px, read once per photo, so the
    /// preview and the saved photo see the same.
    private func gray() -> (pixels: [Float], width: Int, height: Int)? {
        guard let photo else { return nil }
        if let grayCache, grayCache.key == photo.key { return (grayCache.pixels, grayCache.width, grayCache.height) }
        let small = PhotoRenderer.downscaled(photo.picture, maxSide: 800)
        let e = small.extent
        let w = Int(e.width.rounded(.down)), h = Int(e.height.rounded(.down))
        guard w > 8, h > 8, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &rgba, rowBytes: w * 16,
                       bounds: CGRect(x: e.minX, y: e.minY, width: CGFloat(w), height: CGFloat(h)), format: .RGBAf, colorSpace: space)
        var pixels = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            pixels[i] = 0.2126 * rgba[4 * i] + 0.7152 * rgba[4 * i + 1] + 0.0722 * rgba[4 * i + 2]
        }
        grayCache = (photo.key, pixels, w, h)
        return (pixels, w, h)
    }

    /// Straight lines on the photo (LineDetector in CommandEngine), found once per photo.
    func segments() -> [LineSegment] {
        guard let photo else { return [] }
        if let lineCache, lineCache.key == photo.key { return lineCache.segments }
        guard let g = gray() else { return [] }
        let found = LineDetector.detect(g.pixels, width: g.width, height: g.height)
        lineCache = (photo.key, found)
        return found
    }

    /// The plan for a picture over `extent`. `previewScale`: the preview's size ÷ the full photo's
    /// (nil when saving). Upright reads the photo's lines; content-aware scale gets its map here.
    func plan(extent: CGRect, value: (String) -> Double?, edits: GeometryEdits, stage: GeometryStage,
              previewScale: Double? = nil) -> GeometryPlan {
        let settings = GeometrySettings(value: value)
        let lines = settings.upright == "off" || settings.upright == "guided" || edits.quad.count == 4 ? [] : segments()
        var plan = GeometryPlan(settings: settings, width: Double(extent.width), height: Double(extent.height), stage: stage,
                                segments: lines, edits: edits, previewScale: previewScale)
        if plan.hasContentAware { plan.contentAwareMap = contentAwareMap(plan) }
        return plan
    }

    /// Content-aware scale's map: the photo as the crop shows it, on a grid of long side 256 (its
    /// energy), seam-carved to the new size. Kept while the photo, the geometry and the sizes stay.
    private func contentAwareMap(_ plan: GeometryPlan) -> WarpMap? {
        guard let photo, let g = gray() else { return nil }
        // Normalized, so the preview and the saved photo share it.
        let w = plan.sourceWidth, h = plan.sourceHeight
        let norm = Homography.scale(1 / plan.frameWidth, 1 / plan.frameHeight) * plan.transform * Homography.scale(w, h)
        let key = photo.key + norm.normalized.m + [plan.crop.x / plan.frameWidth, plan.crop.y / plan.frameHeight,
                                                   plan.crop.width / plan.frameWidth, plan.crop.height / plan.frameHeight,
                                                   plan.contentAwareWidth, plan.contentAwareHeight]
        if let mapCache, mapCache.key.count == key.count, zip(mapCache.key, key).allSatisfy({ abs($0 - $1) < 1e-6 }) {
            return mapCache.map
        }
        let size = SeamCarving.gridSize(width: plan.crop.width, height: plan.crop.height)
        let grid = plan.cropGrid(gray: g.pixels, width: g.width, height: g.height, gridWidth: size.width, gridHeight: size.height)
        let map = SeamCarving.map(energy: SeamCarving.energy(grid, width: size.width, height: size.height), width: size.width,
                                  height: size.height, sx: plan.contentAwareWidth, sy: plan.contentAwareHeight)
        mapCache = (key, map)
        return map
    }

    /// Reads each output pixel where a WarpMap says, as a shift from a plain stretch (Core Image
    /// kernel language: the picture and the shift grid as two samplers).
    private static let remapKernel: CIKernel? = CIKernel(source: """
        kernel vec4 remap(sampler image, sampler shift, vec4 inBox, vec4 outBox) {
            vec2 u = (destCoord() - outBox.xy) / outBox.zw;
            vec2 d = sample(shift, samplerCoord(shift)).rg;
            vec2 p = inBox.xy + (u + d) * inBox.zw;
            p = clamp(p, inBox.xy + vec2(0.5), inBox.xy + inBox.zw - vec2(0.5));
            return sample(image, samplerTransform(image, p));
        }
        """)

    /// `image` read through `map` into a picture of `size` at the origin (a plain stretch if the
    /// kernel is missing).
    func remap(_ image: CIImage, map: WarpMap?, to size: CGSize) -> CIImage {
        let inBox = image.extent
        let outBox = CGRect(origin: .zero, size: size)
        let stretched = image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -inBox.minX, y: -inBox.minY)
                .concatenating(CGAffineTransform(scaleX: size.width / max(inBox.width, 1), y: size.height / max(inBox.height, 1))))
            .cropped(to: outBox)
        guard let map, map.width > 0, map.height > 0, let kernel = Self.remapKernel else { return stretched }
        // The shifts with y counted upwards, as Core Image does.
        let d = map.displacements
        var pixels = [Float](repeating: 0, count: map.width * map.height * 4)
        for i in 0..<(map.width * map.height) {
            pixels[4 * i] = d[2 * i]
            pixels[4 * i + 1] = -d[2 * i + 1]
            pixels[4 * i + 3] = 1
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let grid = CIImage(bitmapData: data, bytesPerRow: map.width * 16, size: CGSize(width: map.width, height: map.height),
                           format: .RGBAf, colorSpace: nil)
        let shift = Filters.resized(grid, to: outBox)
        let shiftExtent = shift.extent
        return kernel.apply(extent: outBox, roiCallback: { index, _ in index == 0 ? inBox : shiftExtent },
                            arguments: [image, shift, CIVector(cgRect: inBox), CIVector(cgRect: outBox)]) ?? stretched
    }

    /// The finished picture on its canvas and resized (Lanczos) as the plan says, at the origin.
    func frame(_ image: CIImage, plan: GeometryPlan) -> CIImage {
        if plan.isFrameIdentity { return image }
        let e = image.extent
        var out = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        var area = CGRect(x: 0, y: 0, width: e.width, height: e.height)
        if !plan.hasNoCanvas {
            let canvas = CGRect(x: 0, y: 0, width: CGFloat(plan.canvasWidth), height: CGFloat(plan.canvasHeight))
            let picture = out.cropped(to: CGRect(x: 0, y: 0, width: CGFloat(plan.shapedWidth), height: CGFloat(plan.shapedHeight)))
            // Placed from the canvas's top-left (Core Image counts y from the bottom).
            let y = plan.canvasHeight - plan.contentY - plan.shapedHeight
            out = picture.transformed(by: CGAffineTransform(translationX: CGFloat(plan.contentX), y: CGFloat(y)))
                .composited(over: background(picture, plan: plan, canvas: canvas))
            area = canvas
        }
        let k = plan.resizeFactor
        if abs(k - 1) > 1e-9 {
            // Edges repeated a little outwards, so the border pixels stay solid.
            out = out.clampedToExtent().cropped(to: area.insetBy(dx: -4, dy: -4))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        }
        return out.cropped(to: CGRect(x: 0, y: 0, width: CGFloat(plan.outputWidth), height: CGFloat(plan.outputHeight)))
    }

    /// The canvas's colour, or the picture itself stretched to fill it and blurred (3 % of its long side).
    private func background(_ picture: CIImage, plan: GeometryPlan, canvas: CGRect) -> CIImage {
        switch plan.canvasColor {
        case "black":
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
        case "grey":
            return CIImage(color: CIColor(red: 0.21, green: 0.21, blue: 0.21)).cropped(to: canvas)  // mid-grey on sRGB levels
        case "blur":
            let p = picture.extent
            let scale = max(canvas.width / max(p.width, 1), canvas.height / max(p.height, 1))
            let filled = picture.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: (canvas.width - p.width * scale) / 2, y: (canvas.height - p.height * scale) / 2)
                    .scaledBy(x: scale, y: scale))
            return filled.applyingGaussianBlur(sigma: Double(0.03 * max(canvas.width, canvas.height))).cropped(to: canvas)
        default:
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvas)
        }
    }

    /// The picture put into its frame and cropped, as the plan says; the result starts at the origin.
    /// `clampEdges`: repeat the photo's border pixels outwards (no see-through edge pixels); off while
    /// the crop tool shows the whole frame, so the empty corners show as empty.
    func shape(_ image: CIImage, plan: GeometryPlan, clampEdges: Bool = true) -> CIImage {
        if plan.isShapeIdentity { return image }
        let e = image.extent
        // Core Image's coordinates (origin bottom-left) → the photo's pixels (from its top-left) → the
        // frame's pixels → Core Image's coordinates of the frame.
        let toPhoto = Homography([1, 0, -Double(e.minX), 0, -1, Double(e.maxY), 0, 0, 1])
        let toCI = Homography([1, 0, 0, 0, -1, plan.frameHeight, 0, 0, 1])
        let h = (toCI * plan.transform * toPhoto).normalized
        let framed: CIImage
        if h.isAffine {
            let input = clampEdges ? image.clampedToExtent() : image
            let m = h.m.map { CGFloat($0) }
            framed = input.transformed(by: CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5]))
        } else {
            // The perspective filter maps the corners of its input; a slightly larger input keeps
            // clamped edges solid.
            let grown = clampEdges ? e.insetBy(dx: -2, dy: -2) : e
            let input = clampEdges ? image.clampedToExtent().cropped(to: grown) : image
            func corner(_ x: CGFloat, _ y: CGFloat) -> CIVector {
                let p = h.apply(Vec2(Double(x), Double(y)))
                return CIVector(x: CGFloat(p.x), y: CGFloat(p.y))
            }
            framed = input.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": corner(grown.minX, grown.maxY),
                "inputTopRight": corner(grown.maxX, grown.maxY),
                "inputBottomRight": corner(grown.maxX, grown.minY),
                "inputBottomLeft": corner(grown.minX, grown.minY),
            ])
        }
        let c = plan.crop
        let rect = CGRect(x: CGFloat(c.x), y: CGFloat(plan.frameHeight - c.y - c.height), width: CGFloat(c.width), height: CGFloat(c.height))
        let cropped = framed.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        guard plan.hasContentAware else { return cropped }
        // Content-aware scale: busy parts keep their shape, plain parts give way.
        return remap(cropped, map: plan.contentAwareMap, to: CGSize(width: CGFloat(plan.shapedWidth), height: CGFloat(plan.shapedHeight)))
    }
}
