import Foundation

// Geometry (the Geometry panel): crop, straighten, rotate and flip, upright, transform, perspective
// crop, content-aware scale, warp, canvas size and resize. As in Lightroom nothing is baked in: the
// photo keeps its own coordinates (masks, retouch spots, colour pickers and upright guides stay in
// them) and the geometry is worked out from the settings at the end of the pipeline:
//
//   photo ─H→ frame ─crop→ cropped ─content-aware scale→ ─warp→ (vignette, grain) ─canvas→ ─resize→ saved
//
// H is one 3×3 projective transform: upright, the manual transform and perspective crop, then
// straighten, the quarter turns and the flips. Touches on the edited photo are mapped back through
// the same steps (GeometryPlan.toSource), so they land on the pixels they were made on.
//
// Points are in pixels from the top-left (y down) unless they say "normalized" (0…1 of a width and height).

/// A point or vector in pixels (x right, y down).
public struct Vec2: Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public var length: Double { (x * x + y * y).squareRoot() }
}

/// A box in pixels: left, top, width, height.
public struct GeoRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var centre: Vec2 { Vec2(x + width / 2, y + height / 2) }
}

/// A 3×3 projective transform (homography): (x, y) → ((m0 x + m1 y + m2), (m3 x + m4 y + m5)) ÷ (m6 x + m7 y + m8).
/// Rotations, scalings, flips and perspective (keystone) changes are all of this kind, and so is any
/// mix of them, so the whole of upright, transform, straighten, turns and flips is one of these.
public struct Homography: Equatable {
    /// Row by row.
    public var m: [Double]

    public init(_ m: [Double]) {
        self.m = m
    }

    public static let identity = Homography([1, 0, 0, 0, 1, 0, 0, 0, 1])

    public static func translation(_ x: Double, _ y: Double) -> Homography {
        Homography([1, 0, x, 0, 1, y, 0, 0, 1])
    }

    public static func scale(_ sx: Double, _ sy: Double) -> Homography {
        Homography([sx, 0, 0, 0, sy, 0, 0, 0, 1])
    }

    /// Clockwise on screen by `degrees` (y points down), about the origin. Quarter turns are exact.
    public static func rotation(degrees: Double) -> Homography {
        let quarter = degrees / 90
        if quarter == quarter.rounded() {
            let k = ((Int(quarter) % 4) + 4) % 4
            let c = [1.0, 0, -1, 0][k], s = [0.0, 1, 0, -1][k]
            return Homography([c, -s, 0, s, c, 0, 0, 0, 1])
        }
        let a = degrees * .pi / 180
        return Homography([cos(a), -sin(a), 0, sin(a), cos(a), 0, 0, 0, 1])
    }

    public func apply(_ p: Vec2) -> Vec2 {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        let safe = abs(w) < 1e-12 ? (w < 0 ? -1e-12 : 1e-12) : w
        return Vec2((m[0] * p.x + m[1] * p.y + m[2]) / safe, (m[3] * p.x + m[4] * p.y + m[5]) / safe)
    }

    /// `a * b`: first b, then a.
    public static func * (a: Homography, b: Homography) -> Homography {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                out[r * 3 + c] = a.m[r * 3] * b.m[c] + a.m[r * 3 + 1] * b.m[3 + c] + a.m[r * 3 + 2] * b.m[6 + c]
            }
        }
        return Homography(out)
    }

    public var inverse: Homography {
        let a = m
        let c0 = a[4] * a[8] - a[5] * a[7], c1 = a[5] * a[6] - a[3] * a[8], c2 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c0 + a[1] * c1 + a[2] * c2
        guard abs(det) > 1e-18 else { return .identity }
        let inv = [c0, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
                   c1, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
                   c2, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3]]
        return Homography(inv.map { $0 / det })
    }

    /// No perspective part: parallel lines stay parallel.
    public var isAffine: Bool {
        abs(m[6]) < 1e-12 && abs(m[7]) < 1e-12 && abs(m[8] - 1) < 1e-12
    }

    /// Scaled so the bottom-right entry is 1 (as most formulas expect).
    public var normalized: Homography {
        abs(m[8]) < 1e-15 ? self : Homography(m.map { $0 / m[8] })
    }

    public func isClose(to other: Homography, tolerance: Double = 1e-9) -> Bool {
        let a = normalized.m, b = other.normalized.m
        return zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// The transform taking four points to four others (exact; nil if three of them are in a line).
    public static func mapping(_ from: [Vec2], to: [Vec2]) -> Homography? {
        guard from.count == 4, to.count == 4 else { return nil }
        // Unknowns m0…m7 (m8 = 1): two equations per point.
        var rows: [[Double]] = []
        for (p, q) in zip(from, to) {
            rows.append([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y, q.x])
            rows.append([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y, q.y])
        }
        guard let h = solve(rows) else { return nil }
        return Homography(h + [1])
    }

    /// Solves n equations in n unknowns given as rows [a0 … a(n−1), b] (Gaussian elimination).
    static func solve(_ input: [[Double]]) -> [Double]? {
        var a = input
        let n = a.count
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-12 else {
                return nil
            }
            a.swapAt(col, pivot)
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for c in col...n { a[r][c] -= f * a[col][c] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}

/// What the Geometry panel's touch tools made (the sliders and choices are in `EditState.values`).
public struct GeometryEdits: Hashable, Codable {
    /// Guided upright: lines drawn along edges that should be vertical or horizontal, on the photo
    /// (normalized, two points each), oldest first; at most four.
    public var guides: [[MaskPoint]]
    /// Perspective crop: the corners of the tilted plane on the photo (normalized; top-left,
    /// top-right, bottom-right, bottom-left). Empty: none.
    public var quad: [MaskPoint]
    /// Warp handles: grid points and puppet pins.
    public var pins: [WarpPin]

    public init(guides: [[MaskPoint]] = [], quad: [MaskPoint] = [], pins: [WarpPin] = []) {
        self.guides = guides
        self.quad = quad
        self.pins = pins
    }
}

/// One warp handle: where it sits on the (cropped) picture before warping and where it was dragged
/// to, both normalized.
public struct WarpPin: Hashable, Codable {
    public var anchor: MaskPoint
    public var position: MaskPoint

    public init(anchor: MaskPoint, position: MaskPoint) {
        self.anchor = anchor
        self.position = position
    }
}

/// Which steps a preview shows: everything; the whole frame without the crop (while cropping,
/// straightening or drawing guides); or the photo as it is (while placing perspective crop corners).
public enum GeometryStage: Equatable {
    case full, frame, source
}

/// The Geometry panel's values as plain numbers, read from the controls (`value` gives a control's
/// value by id, as the renderers get it).
public struct GeometrySettings: Equatable {
    /// Crop aspect option id ("free", the default; "original", "16:9", …).
    public var aspect: String
    /// Share of the frame cut from each side, 0…0.95.
    public var cropLeft: Double
    public var cropTop: Double
    public var cropRight: Double
    public var cropBottom: Double
    /// Straighten, degrees clockwise on screen (−45…45).
    public var straighten: Double
    /// Quarter turns clockwise (0…3), then the flips (mirror left-right, top-bottom).
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    /// Upright mode (an option id of Upright.modes: "off", "auto", "level", "vertical", "full", "guided").
    public var upright: String
    /// The manual transform (Lightroom's Transform sliders): vertical and horizontal perspective
    /// (−100…100), rotate (degrees), aspect (−100…100), scale (1 = 100 %), offsets (−100…100).
    public var transformVertical = 0.0
    public var transformHorizontal = 0.0
    public var transformRotate = 0.0
    public var transformAspect = 0.0
    public var transformScale = 1.0
    public var offsetX = 0.0
    public var offsetY = 0.0
    /// Resize: the saved photo's size as a share of what the edit gives (1 = 100 %), or, when set,
    /// its long edge in pixels (0 = not set); its resolution (pixels per inch, kept in the file).
    public var resize = 1.0
    public var longEdge = 0.0
    public var resolution = 72.0

    public init(aspect: String = "free", cropLeft: Double = 0, cropTop: Double = 0, cropRight: Double = 0,
                cropBottom: Double = 0, straighten: Double = 0, quarterTurns: Int = 0, flipHorizontal: Bool = false,
                flipVertical: Bool = false, upright: String = "off") {
        self.aspect = aspect
        self.cropLeft = cropLeft
        self.cropTop = cropTop
        self.cropRight = cropRight
        self.cropBottom = cropBottom
        self.straighten = straighten
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.upright = upright
    }

    public init(value: (String) -> Double?) {
        func v(_ id: String) -> Double { value(id) ?? 0 }
        let index = Int(value("cropAspect") ?? 1)
        aspect = Crop.aspects.indices.contains(index) ? Crop.aspects[index] : "free"
        cropLeft = Swift.min(0.95, Swift.max(0, v("cropLeft") / 100))
        cropTop = Swift.min(0.95, Swift.max(0, v("cropTop") / 100))
        cropRight = Swift.min(0.95, Swift.max(0, v("cropRight") / 100))
        cropBottom = Swift.min(0.95, Swift.max(0, v("cropBottom") / 100))
        straighten = Swift.min(45, Swift.max(-45, v("straighten")))
        quarterTurns = ((Int(v("rotation")) % 4) + 4) % 4
        flipHorizontal = v("flipHorizontal") != 0
        flipVertical = v("flipVertical") != 0
        let mode = Int(v("upright"))
        upright = Upright.modes.indices.contains(mode) ? Upright.modes[mode] : "off"
        transformVertical = v("transformVertical")
        transformHorizontal = v("transformHorizontal")
        transformRotate = v("transformRotate")
        transformAspect = v("transformAspect")
        transformScale = Swift.max(0.1, (value("transformScale") ?? 100) / 100)
        offsetX = v("transformOffsetX")
        offsetY = v("transformOffsetY")
        resize = Swift.max(0.01, (value("resize") ?? 100) / 100)
        longEdge = Swift.max(0, v("longEdge"))
        resolution = value("resolution") ?? 72
    }

    /// The manual transform in pixels of a `width` × `height` photo (the frame keeps its size): a camera
    /// turn for Vertical (pitch, up to 25°: + widens the top), Horizontal (yaw, up to 25°: + makes the
    /// right side taller) and Rotate, keeping the middle in place; then Aspect (+ wider, up to 1.41×),
    /// Scale and the offsets (up to half the frame), about the middle.
    public func manualTransform(width: Double, height: Double) -> Homography {
        guard transformVertical != 0 || transformHorizontal != 0 || transformRotate != 0 || transformAspect != 0
            || transformScale != 1 || offsetX != 0 || offsetY != 0 else { return .identity }
        let camera = Upright.Camera(f: Upright.defaultFocal(width: width, height: height), cx: width / 2, cy: height / 2)
        let p = transformVertical / 100 * 25 * Double.pi / 180, y = transformHorizontal / 100 * 25 * Double.pi / 180
        let r = transformRotate * Double.pi / 180
        let rx = Homography([1, 0, 0, 0, cos(p), -sin(p), 0, sin(p), cos(p)])
        let ry = Homography([cos(y), 0, sin(y), 0, 1, 0, -sin(y), 0, cos(y)])
        let rz = Homography([cos(r), -sin(r), 0, sin(r), cos(r), 0, 0, 0, 1])
        let turned = Upright.centred(camera.transform((rz * ry * rx).m), width: width, height: height)
        let stretch = pow(2, transformAspect / 200)
        let around = Homography.translation(width / 2 + offsetX / 200 * width, height / 2 + offsetY / 200 * height)
            * Homography.scale(transformScale * stretch, transformScale / stretch) * Homography.translation(-width / 2, -height / 2)
        return around * turned
    }
}

/// The geometry of one render: sizes and transforms from the photo (`width` × `height` pixels) to
/// the picture the pipeline puts out, and the maps between their points.
public struct GeometryPlan: Equatable {
    public let sourceWidth: Double
    public let sourceHeight: Double
    public let stage: GeometryStage
    /// Photo pixels → frame pixels.
    public let transform: Homography
    /// Photo pixels → the photo before straightening (upright and the manual transform; frame pixels
    /// before the straighten turn): where lines are measured for Straighten.
    public let preStraighten: Homography
    public let frameWidth: Double
    public let frameHeight: Double
    /// The crop in frame pixels (whole pixels); the whole frame when the stage shows no crop.
    public let crop: GeoRect
    /// Where the photo lies in the frame (its corners: top-left, top-right, bottom-right, bottom-left).
    public let photoCorners: [Vec2]
    /// Resize: the scale this render applies at the end, the size it puts out, and the size of the
    /// saved photo (pixels of the full-size photo).
    public let resizeFactor: Double
    public let outputWidth: Double
    public let outputHeight: Double
    public let savedWidth: Double
    public let savedHeight: Double
    /// Pixels per inch written into the saved photo.
    public let resolution: Double

    /// `segments`: the photo's straight lines (LineDetector), for Upright; `edits`: what the touch
    /// tools made (guides, …). `previewScale`: for a preview, its size ÷ the full photo's (the
    /// preview is resized only to be no sharper than the saved photo); nil when saving.
    public init(settings: GeometrySettings, width: Double, height: Double, stage: GeometryStage = .full,
                segments: [LineSegment] = [], edits: GeometryEdits = GeometryEdits(), previewScale: Double? = nil) {
        sourceWidth = width
        sourceHeight = height
        self.stage = stage
        let corners = [Vec2(0, 0), Vec2(width, 0), Vec2(width, height), Vec2(0, height)]
        // Perspective crop (its four corners become the frame) or Upright (the perspective correction
        // the photo's lines ask for), then the manual transform.
        var base = (width: width, height: height)
        var pre: Homography
        if let rect = PerspectiveCrop.rectify(edits.quad, width: width, height: height) {
            base = (rect.width, rect.height)
            pre = settings.manualTransform(width: rect.width, height: rect.height) * rect.transform
        } else {
            pre = settings.manualTransform(width: width, height: height)
                * Upright.transform(mode: settings.upright, segments: segments, width: width, height: height, guides: edits.guides)
        }
        if stage == .source { base = (width, height) }
        // Straighten turns the picture about the frame's middle; then the quarter turns (which swap
        // the frame's sides) and the flips, about the middle too.
        let turned = settings.quarterTurns % 2 == 1 && stage != .source
        let w3 = turned ? base.height : base.width, h3 = turned ? base.width : base.height
        let flip = Homography.scale(settings.flipHorizontal ? -1 : 1, settings.flipVertical ? -1 : 1)
        let turn = Homography.translation(w3 / 2, h3 / 2) * flip * Homography.rotation(degrees: Double(90 * settings.quarterTurns))
            * Homography.rotation(degrees: settings.straighten) * Homography.translation(-base.width / 2, -base.height / 2)
        preStraighten = stage == .source ? .identity : pre
        let h = stage == .source ? Homography.identity : turn * pre
        transform = h
        frameWidth = w3
        frameHeight = h3
        photoCorners = corners.map { h.apply($0) }
        switch stage {
        case .full:
            crop = Crop.rect(settings: settings, width: frameWidth, height: frameHeight,
                             sourceAspect: frameWidth / Swift.max(frameHeight, 1), valid: photoCorners)
        case .frame, .source:
            crop = Crop.whole(width: frameWidth, height: frameHeight)
        }
        // Resize, on what the edit gives (in this render's pixels; the full photo's is that ÷ the preview scale).
        let scale = previewScale ?? 1
        let shapedW = crop.width, shapedH = crop.height
        let full = Swift.max(shapedW, shapedH) / scale
        let r = stage == .full ? (settings.longEdge > 0 ? settings.longEdge / full : settings.resize) : 1
        savedWidth = Swift.max(1, (shapedW / scale * r).rounded())
        savedHeight = Swift.max(1, (shapedH / scale * r).rounded())
        resolution = settings.resolution
        resizeFactor = previewScale == nil ? r : Swift.min(1, r / scale)
        outputWidth = abs(resizeFactor - 1) < 1e-9 ? shapedW : Swift.max(1, (shapedW * resizeFactor).rounded())
        outputHeight = abs(resizeFactor - 1) < 1e-9 ? shapedH : Swift.max(1, (shapedH * resizeFactor).rounded())
    }

    /// Nothing changes the picture: the pipeline can skip the geometry.
    public var isIdentity: Bool {
        isShapeIdentity && isFrameIdentity
    }

    /// No turn, transform or crop (the photo keeps its shape).
    public var isShapeIdentity: Bool {
        transform.isClose(to: .identity) && frameWidth == sourceWidth && frameHeight == sourceHeight
            && crop == Crop.whole(width: frameWidth, height: frameHeight)
    }

    /// No canvas and no resize at the end.
    public var isFrameIdentity: Bool {
        abs(resizeFactor - 1) < 1e-9
    }

    /// The size of the picture after the crop (before vignette and grain).
    public var shapedWidth: Double { crop.width }
    public var shapedHeight: Double { crop.height }

    /// A point on the shown picture (normalized) → the same point on the photo (normalized).
    public func toSource(_ p: MaskPoint) -> MaskPoint {
        let framed = Vec2(crop.x + p.x * crop.width, crop.y + p.y * crop.height)
        let q = transform.inverse.apply(framed)
        return MaskPoint(q.x / Swift.max(sourceWidth, 1e-9), q.y / Swift.max(sourceHeight, 1e-9))
    }

    /// A point on the photo (normalized) → where it shows (normalized).
    public func toShown(_ p: MaskPoint) -> MaskPoint {
        let q = shownTransform.apply(Vec2(p.x, p.y))
        return MaskPoint(q.x, q.y)
    }

    /// The photo (normalized) → the shown picture (normalized), as one projective transform: used to
    /// draw outlines made on the photo (mask handles, spots) over the edited picture.
    public var shownTransform: Homography {
        Homography.scale(1 / Swift.max(crop.width, 1e-9), 1 / Swift.max(crop.height, 1e-9))
            * Homography.translation(-crop.x, -crop.y) * transform * Homography.scale(sourceWidth, sourceHeight)
    }

    /// A point on the frame (normalized, as the crop tool shows it) → the photo before straightening,
    /// in pixels (where Straighten measures a drawn line).
    public func frameToPreStraighten(_ p: MaskPoint) -> Vec2 {
        (preStraighten * transform.inverse).apply(Vec2(p.x * frameWidth, p.y * frameHeight))
    }

    /// The guides (on the photo) where they show on the frame (normalized), for drawing them.
    public func guidesOnFrame(_ guides: [[MaskPoint]]) -> [(MaskPoint, MaskPoint)] {
        guides.compactMap { g in
            guard let a = g.first, let b = g.last else { return nil }
            let p = transform.apply(Vec2(a.x * sourceWidth, a.y * sourceHeight)), q = transform.apply(Vec2(b.x * sourceWidth, b.y * sourceHeight))
            return (MaskPoint(p.x / frameWidth, p.y / frameHeight), MaskPoint(q.x / frameWidth, q.y / frameHeight))
        }
    }

    /// A point on the frame (normalized, as the crop tool shows it) → normalized on the photo.
    public func frameToSource(_ p: MaskPoint) -> MaskPoint {
        let q = transform.inverse.apply(Vec2(p.x * frameWidth, p.y * frameHeight))
        return MaskPoint(q.x / Swift.max(sourceWidth, 1e-9), q.y / Swift.max(sourceHeight, 1e-9))
    }

    /// The crop as shares of the frame: left, top, right, bottom edges (0…1 from the top-left).
    public var cropBox: (x0: Double, y0: Double, x1: Double, y1: Double) {
        (crop.x / frameWidth, crop.y / frameHeight, crop.maxX / frameWidth, crop.maxY / frameHeight)
    }
}

/// Crop: aspect presets, the crop box (kept inside the photo when it is turned or transformed, as
/// Lightroom's "constrain to image" does) and the crop tool's handles.
public enum Crop {
    /// Option ids of the "cropAspect" choice, in order; must match controls.json (unit-tested).
    public static let aspects = ["original", "free", "1:1", "4:5", "5:4", "2:3", "3:2", "3:4", "4:3", "9:16", "16:9"]

    /// Width ÷ height for an aspect option: nil for free; `original` uses the photo's own.
    public static func ratio(_ aspect: String, original: Double) -> Double? {
        switch aspect {
        case "free": return nil
        case "original": return original
        default:
            let parts = aspect.split(separator: ":").compactMap { Double($0) }
            return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : original
        }
    }

    /// The whole frame in whole pixels.
    public static func whole(width: Double, height: Double) -> GeoRect {
        GeoRect(x: 0, y: 0, width: Swift.max(1, (width + 1e-6).rounded(.down)), height: Swift.max(1, (height + 1e-6).rounded(.down)))
    }

    /// The crop box in frame pixels: the box the edges ask for, narrowed to the aspect (centred), then
    /// shrunk about its centre until it lies inside the photo (`valid`: its corners in the frame), in
    /// whole pixels. `sourceAspect`: the photo's width ÷ height as it is shown (for "original").
    public static func rect(settings: GeometrySettings, width: Double, height: Double, sourceAspect: Double,
                            valid: [Vec2]) -> GeoRect {
        var x0 = settings.cropLeft * width, x1 = (1 - settings.cropRight) * width
        var y0 = settings.cropTop * height, y1 = (1 - settings.cropBottom) * height
        let minW = 0.05 * width, minH = 0.05 * height
        if x1 - x0 < minW { let c = Swift.min(Swift.max((x0 + x1) / 2, minW / 2), width - minW / 2); x0 = c - minW / 2; x1 = c + minW / 2 }
        if y1 - y0 < minH { let c = Swift.min(Swift.max((y0 + y1) / 2, minH / 2), height - minH / 2); y0 = c - minH / 2; y1 = c + minH / 2 }
        var box = GeoRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        if let a = ratio(settings.aspect, original: sourceAspect), a > 0 {
            let w = box.width / box.height > a ? box.height * a : box.width
            let h = w / a
            box = GeoRect(x: box.centre.x - w / 2, y: box.centre.y - h / 2, width: w, height: h)
        }
        box = constrained(box, inside: valid, width: width, height: height)
        return integral(box, width: width, height: height)
    }

    /// The box shrunk about its centre (the photo's middle if the centre is off the photo) until its
    /// corners are inside the polygon `valid` and the frame.
    public static func constrained(_ box: GeoRect, inside valid: [Vec2], width: Double, height: Double) -> GeoRect {
        func fits(_ c: Vec2, _ s: Double) -> Bool {
            let hw = box.width / 2 * s, hh = box.height / 2 * s
            let corners = [Vec2(c.x - hw, c.y - hh), Vec2(c.x + hw, c.y - hh), Vec2(c.x + hw, c.y + hh), Vec2(c.x - hw, c.y + hh)]
            return corners.allSatisfy { p in
                p.x >= -1e-6 && p.y >= -1e-6 && p.x <= width + 1e-6 && p.y <= height + 1e-6 && inside(p, valid)
            }
        }
        var c = box.centre
        if !fits(c, 1e-4) {
            let mid = valid.reduce(Vec2(0, 0)) { $0 + $1 } * (1 / Double(Swift.max(valid.count, 1)))
            c = Vec2(Swift.min(Swift.max(mid.x, 0), width), Swift.min(Swift.max(mid.y, 0), height))
            if !fits(c, 1e-4) { return box }
        }
        if fits(c, 1) { return GeoRect(x: c.x - box.width / 2, y: c.y - box.height / 2, width: box.width, height: box.height) }
        var lo = 1e-4, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if fits(c, mid) { lo = mid } else { hi = mid }
        }
        let w = box.width * lo, h = box.height * lo
        return GeoRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    /// Whether a point is inside a convex polygon (either winding), edges included.
    public static func inside(_ p: Vec2, _ polygon: [Vec2]) -> Bool {
        guard polygon.count >= 3 else { return true }
        var sign = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            let scale = Swift.max((b - a).length, 1e-9)
            if abs(cross) / scale < 1e-6 { continue }
            if sign == 0 { sign = cross > 0 ? 1 : -1 } else if cross * sign < 0 { return false }
        }
        return true
    }

    /// Edges rounded inwards to whole pixels (at least 1 × 1), inside the frame.
    static func integral(_ box: GeoRect, width: Double, height: Double) -> GeoRect {
        let maxW = (width + 1e-6).rounded(.down), maxH = (height + 1e-6).rounded(.down)
        var x0 = Swift.max(0, (box.x - 1e-6).rounded(.up)), y0 = Swift.max(0, (box.y - 1e-6).rounded(.up))
        var x1 = Swift.min(maxW, (box.maxX + 1e-6).rounded(.down)), y1 = Swift.min(maxH, (box.maxY + 1e-6).rounded(.down))
        if x1 - x0 < 1 { x0 = Swift.min(Swift.max(0, (box.centre.x - 0.5).rounded(.down)), maxW - 1); x1 = x0 + 1 }
        if y1 - y0 < 1 { y0 = Swift.min(Swift.max(0, (box.centre.y - 0.5).rounded(.down)), maxH - 1); y1 = y0 + 1 }
        return GeoRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The parts of the crop box a drag can take hold of.
    public enum Handle: Equatable {
        /// 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
        case corner(Int)
        /// 0 left, 1 top, 2 right, 3 bottom.
        case edge(Int)
        /// Inside the box: moves it.
        case move
        /// Away from the box: draws a new one.
        case new
    }

    /// What a drag starting at `p` takes hold of (box and point normalized on the frame; `reach`: how
    /// near a corner or edge counts, as a share of the frame).
    public static func handle(at p: MaskPoint, box: (x0: Double, y0: Double, x1: Double, y1: Double), reach: Double = 0.05) -> Handle {
        let corners = [(box.x0, box.y0), (box.x1, box.y0), (box.x1, box.y1), (box.x0, box.y1)]
        if let i = corners.indices.first(where: { abs(p.x - corners[$0].0) <= reach && abs(p.y - corners[$0].1) <= reach }) {
            return .corner(i)
        }
        let withinX = p.x >= box.x0 - reach && p.x <= box.x1 + reach, withinY = p.y >= box.y0 - reach && p.y <= box.y1 + reach
        if withinY, abs(p.x - box.x0) <= reach { return .edge(0) }
        if withinX, abs(p.y - box.y0) <= reach { return .edge(1) }
        if withinY, abs(p.x - box.x1) <= reach { return .edge(2) }
        if withinX, abs(p.y - box.y1) <= reach { return .edge(3) }
        if p.x > box.x0, p.x < box.x1, p.y > box.y0, p.y < box.y1 { return .move }
        return .new
    }

    /// The crop box after dragging `handle` of `box` from `start` to `end` (all normalized on a
    /// `width` × `height` frame). With an aspect (width ÷ height in pixels) the box keeps it.
    public static func drag(_ handle: Handle, box: (x0: Double, y0: Double, x1: Double, y1: Double), from start: MaskPoint,
                            to end: MaskPoint, aspect: Double?, width: Double, height: Double)
        -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        func clamp(_ v: Double) -> Double { Swift.min(1, Swift.max(0, v)) }
        let dx = end.x - start.x, dy = end.y - start.y
        var b = box
        switch handle {
        case .move:
            let mx = Swift.min(Swift.max(dx, -b.x0), 1 - b.x1), my = Swift.min(Swift.max(dy, -b.y0), 1 - b.y1)
            return (b.x0 + mx, b.y0 + my, b.x1 + mx, b.y1 + my)
        case .new:
            b = (clamp(Swift.min(start.x, end.x)), clamp(Swift.min(start.y, end.y)), clamp(Swift.max(start.x, end.x)),
                 clamp(Swift.max(start.y, end.y)))
            guard let a = aspect else { return b }
            return fitted(b, fixed: (start.x <= end.x ? b.x0 : b.x1, start.y <= end.y ? b.y0 : b.y1), aspect: a, width: width, height: height)
        case .corner(let i):
            let fixed = [(b.x1, b.y1), (b.x0, b.y1), (b.x0, b.y0), (b.x1, b.y0)][i]
            let moved = (clamp([b.x0, b.x1, b.x1, b.x0][i] + dx), clamp([b.y0, b.y0, b.y1, b.y1][i] + dy))
            b = (Swift.min(fixed.0, moved.0), Swift.min(fixed.1, moved.1), Swift.max(fixed.0, moved.0), Swift.max(fixed.1, moved.1))
            guard let a = aspect else { return b }
            return fitted(b, fixed: fixed, aspect: a, width: width, height: height)
        case .edge(let i):
            switch i {
            case 0: b.x0 = clamp(Swift.min(b.x0 + dx, b.x1 - 0.01))
            case 1: b.y0 = clamp(Swift.min(b.y0 + dy, b.y1 - 0.01))
            case 2: b.x1 = clamp(Swift.max(b.x1 + dx, b.x0 + 0.01))
            default: b.y1 = clamp(Swift.max(b.y1 + dy, b.y0 + 0.01))
            }
            guard let a = aspect else { return b }
            // The other side follows, centred where it was.
            if i % 2 == 0 {
                let h = (b.x1 - b.x0) * width / a / height, cy = (box.y0 + box.y1) / 2
                let top = Swift.min(Swift.max(cy - h / 2, 0), Swift.max(0, 1 - h))
                return (b.x0, top, b.x1, Swift.min(1, top + h))
            }
            let w = (b.y1 - b.y0) * height * a / width, cx = (box.x0 + box.x1) / 2
            let left = Swift.min(Swift.max(cx - w / 2, 0), Swift.max(0, 1 - w))
            return (left, b.y0, Swift.min(1, left + w), b.y1)
        }
    }

    /// The box made to the aspect, growing the shorter side away from the fixed corner (and
    /// shrinking both if that leaves the frame).
    static func fitted(_ b: (x0: Double, y0: Double, x1: Double, y1: Double), fixed: (Double, Double), aspect: Double,
                       width: Double, height: Double) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        var w = (b.x1 - b.x0) * width, h = (b.y1 - b.y0) * height
        if w / Swift.max(h, 1e-9) > aspect { h = w / aspect } else { w = h * aspect }
        let sx = fixed.0 <= b.x0 + 1e-12 ? 1.0 : -1.0, sy = fixed.1 <= b.y0 + 1e-12 ? 1.0 : -1.0
        let roomX = (sx > 0 ? 1 - fixed.0 : fixed.0) * width, roomY = (sy > 0 ? 1 - fixed.1 : fixed.1) * height
        let k = Swift.min(1, roomX / Swift.max(w, 1e-9), roomY / Swift.max(h, 1e-9))
        w *= k
        h *= k
        let xa = fixed.0, xb = fixed.0 + sx * w / width, ya = fixed.1, yb = fixed.1 + sy * h / height
        return (Swift.min(xa, xb), Swift.min(ya, yb), Swift.max(xa, xb), Swift.max(ya, yb))
    }

    /// Crop edge sliders (% cut from each side) for a box normalized on the frame.
    public static func edges(of box: (x0: Double, y0: Double, x1: Double, y1: Double)) -> [String: Double] {
        func percent(_ v: Double) -> Double { (Swift.min(95, Swift.max(0, v * 100)) * 100).rounded() / 100 }
        return ["cropLeft": percent(box.x0), "cropTop": percent(box.y0), "cropRight": percent(1 - box.x1), "cropBottom": percent(1 - box.y1)]
    }
}

/// The Geometry panel's actions and the controls they act on.
public enum GeometryTools {
    /// Actions that pick a touch tool for the photo, and the tool: "crop" (drag the crop box).
    public static let actions: [String: String] = ["cropTool": "crop", "straightenTool": "straighten", "guidedUpright": "guides",
                                                   "perspectiveCrop": "perspective"]
    /// Actions the app works out from the photo (they come back as commands from its action handler).
    public static let fromPhoto: Set<String> = ["autoStraighten"]
    /// The crop box's controls ("reset crop" puts them back).
    public static let cropIDs = ["cropAspect", "cropLeft", "cropTop", "cropRight", "cropBottom"]

    /// After a geometry control changed from `from` to `to`: the crop box turns and flips with the
    /// photo (a turned crop keeps covering the same part of it, its aspect turned too).
    public static func follow(_ id: String, from: Double, to: Double, state: inout EditState, registry: ControlRegistry) {
        guard from != to else { return }
        func value(_ id: String) -> Double { registry.control(id: id).map { state.value(of: $0) } ?? 0 }
        func set(_ id: String, _ v: Double) {
            if let c = registry.control(id: id) { state.set(c, to: v) }
        }
        switch id {
        case "rotation":
            let steps = ((Int(to) - Int(from)) % 4 + 4) % 4
            for _ in 0..<steps {
                // A clockwise quarter turn: what was cut on the left is now cut at the top, …
                let l = value("cropLeft"), t = value("cropTop"), r = value("cropRight"), b = value("cropBottom")
                set("cropTop", l)
                set("cropRight", t)
                set("cropBottom", r)
                set("cropLeft", b)
                let index = Int(value("cropAspect"))
                if Crop.aspects.indices.contains(index) {
                    let parts = Crop.aspects[index].split(separator: ":")
                    if parts.count == 2, let turned = Crop.aspects.firstIndex(of: "\(parts[1]):\(parts[0])") {
                        set("cropAspect", Double(turned))
                    }
                }
            }
        case "flipHorizontal":
            let l = value("cropLeft")
            set("cropLeft", value("cropRight"))
            set("cropRight", l)
        case "flipVertical":
            let t = value("cropTop")
            set("cropTop", value("cropBottom"))
            set("cropBottom", t)
        default:
            break
        }
    }
}
