import CommandEngine
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Geometry panel, at the end of the pipeline (the maths is GeometryPlan in CommandEngine). The
/// edited photo is put into its frame by one transform H (affine on the GPU with `transformed(by:)`,
/// or CIPerspectiveTransform when it has perspective) and cropped. Everything before it (masks,
/// retouching, pickers) works on the photo's own pixels, so nothing has to follow the crop.
final class GeometryRenderer {
    let context: CIContext

    /// Bumped by the editor when another photo is opened (the lines found are kept until then).
    var photoGeneration = 0
    /// The lines found on the photo, and for which photo and lens settings.
    private var lineCache: (key: [Double], segments: [LineSegment])?

    init(context: CIContext) {
        self.context = context
    }

    /// Straight lines on the photo (after lens corrections; `key`: the lens settings), found once on a
    /// copy of at most 800 px (LineDetector in CommandEngine) and kept, so the preview and the saved
    /// photo use the same lines.
    func segments(of picture: CIImage, key: [Double]) -> [LineSegment] {
        let fullKey = key + [Double(photoGeneration)]
        if let lineCache, lineCache.key == fullKey { return lineCache.segments }
        let small = PhotoRenderer.downscaled(picture, maxSide: 800)
        let e = small.extent
        let w = Int(e.width.rounded(.down)), h = Int(e.height.rounded(.down))
        guard w > 8, h > 8, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &rgba, rowBytes: w * 16,
                       bounds: CGRect(x: e.minX, y: e.minY, width: CGFloat(w), height: CGFloat(h)), format: .RGBAf, colorSpace: space)
        var gray = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            gray[i] = 0.2126 * rgba[4 * i] + 0.7152 * rgba[4 * i + 1] + 0.0722 * rgba[4 * i + 2]
        }
        let found = LineDetector.detect(gray, width: w, height: h)
        lineCache = (fullKey, found)
        return found
    }

    /// The plan for a picture over `extent`.
    func plan(extent: CGRect, value: (String) -> Double?, edits: GeometryEdits, stage: GeometryStage) -> GeometryPlan {
        GeometryPlan(settings: GeometrySettings(value: value), width: Double(extent.width), height: Double(extent.height), stage: stage)
    }

    /// The picture put into its frame and cropped, as the plan says; the result starts at the origin.
    /// `clampEdges`: repeat the photo's border pixels outwards (no see-through edge pixels); off while
    /// the crop tool shows the whole frame, so the empty corners show as empty.
    func shape(_ image: CIImage, plan: GeometryPlan, clampEdges: Bool = true) -> CIImage {
        if plan.isIdentity { return image }
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
        return framed.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }
}
