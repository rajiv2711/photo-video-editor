import Foundation

/// A picture as numbers for retouching: r, g, b per pixel on sRGB levels (HDR levels may go above 1),
/// row by row from the top.
public struct RGBBuffer: Equatable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// From RGBA numbers (4 per pixel, alpha dropped).
    public init(width: Int, height: Int, rgba: [Float]) {
        var pixels = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<Swift.min(width * height, rgba.count / 4) {
            pixels[3 * i] = rgba[4 * i]
            pixels[3 * i + 1] = rgba[4 * i + 1]
            pixels[3 * i + 2] = rgba[4 * i + 2]
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// RGBA numbers (alpha 1), for turning back into a picture.
    public var rgba: [Float] {
        var out = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            out[4 * i] = pixels[3 * i]
            out[4 * i + 1] = pixels[3 * i + 1]
            out[4 * i + 2] = pixels[3 * i + 2]
        }
        return out
    }

    /// The colour at a pixel.
    public func color(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        let i = 3 * (y * width + x)
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    /// The colour at a point in pixels (pixel centres at whole numbers), blended from the four
    /// nearest; points outside take the edge.
    public func bilinear(x: Double, y: Double) -> (Float, Float, Float) {
        let fx = Swift.min(Swift.max(x, 0), Double(width - 1)), fy = Swift.min(Swift.max(y, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = Swift.min(x0 + 1, width - 1), y1 = Swift.min(y0 + 1, height - 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let a = color(x0, y0), b = color(x1, y0), c = color(x0, y1), d = color(x1, y1)
        func mix(_ p: Float, _ q: Float, _ r: Float, _ s: Float) -> Float {
            (p * (1 - tx) + q * tx) * (1 - ty) + (r * (1 - tx) + s * tx) * ty
        }
        return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2))
    }

    /// The pixels inside `box` as a picture of their own.
    public func crop(_ box: PixelBox) -> RGBBuffer {
        var out = [Float](repeating: 0, count: box.width * box.height * 3)
        for y in 0..<box.height {
            let from = 3 * ((box.y0 + y) * width + box.x0), to = 3 * y * box.width
            out.replaceSubrange(to..<(to + 3 * box.width), with: pixels[from..<(from + 3 * box.width)])
        }
        return RGBBuffer(width: box.width, height: box.height, pixels: out)
    }

    /// Puts `part` (a picture the size of `box`) back at `box`.
    public mutating func paste(_ part: RGBBuffer, at box: PixelBox) {
        for y in 0..<box.height {
            let to = 3 * ((box.y0 + y) * width + box.x0), from = 3 * y * box.width
            pixels.replaceSubrange(to..<(to + 3 * box.width), with: part.pixels[from..<(from + 3 * box.width)])
        }
    }

    /// A number that changes when any pixel inside `box` changes (FNV-1a over the bits), for caching.
    func checksum(_ box: PixelBox) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        pixels.withUnsafeBufferPointer { p in
            for y in box.y0..<box.y1 {
                let row = 3 * (y * width)
                for i in (row + 3 * box.x0)..<(row + 3 * box.x1) {
                    hash = (hash ^ UInt64(p[i].bitPattern)) &* 0x100_0000_01B3
                }
            }
        }
        return hash
    }
}

/// A rectangle of pixels: columns x0..<x1, rows y0..<y1.
public struct PixelBox: Hashable {
    public var x0, y0, x1, y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public var width: Int { Swift.max(0, x1 - x0) }
    public var height: Int { Swift.max(0, y1 - y0) }
    public var isEmpty: Bool { width == 0 || height == 0 }

    /// Grown by `margin` pixels on every side, then cut to a `width` × `height` picture.
    func expanded(by margin: Int, width: Int, height: Int) -> PixelBox {
        PixelBox(x0: Swift.max(0, x0 - margin), y0: Swift.max(0, y0 - margin),
                 x1: Swift.min(width, x1 + margin), y1: Swift.min(height, y1 + margin))
    }
}

/// What a render of the retouch steps gives.
public struct RetouchResult {
    /// The retouched picture.
    public let image: RGBBuffer
    /// Steps whose source was picked automatically: step index → the offset found (kept in the edit,
    /// so the source stays put and the saved photo uses the same one).
    public let sources: [Int: MaskPoint]
}

/// Draws the retouch steps (see Retouch.swift) on a picture, in order, each on the result of the ones
/// before. Every step works on the box it touches only; its result (at full opacity) is kept, keyed by
/// the step and the pixels it read, so changing a step's opacity, adding a step or deleting one only
/// works out what really changed. Liquify strokes are one displacement field, applied last (the app
/// maps spots made after a liquify stroke back through it, so they stay on what they covered).
/// The iPad keeps one canvas per picture (preview or full size).
public final class RetouchCanvas {
    /// The picture before any retouching.
    public let base: RGBBuffer
    /// The last render: the steps as given, as drawn (sources filled in), and the picture.
    private var last: (given: [Retouch], drawn: [Retouch], image: RGBBuffer)?
    /// Results of single steps: (step without opacity, checksum of what it read) → its pixels in its box.
    private var results: [StepKey: [Float]] = [:]
    private var cachedFloats = 0
    /// The liquify field of the last render and its strokes.
    private var liquify: (strokes: [Retouch], field: LiquifyField)?
    /// The last liquified picture: the steps before liquify it started from, the strokes, the result.
    private var lastWarp: (before: [Retouch], strokes: [Retouch], image: RGBBuffer)?

    struct StepKey: Hashable {
        let step: Retouch
        let read: UInt64
    }

    public init(base: RGBBuffer) {
        self.base = base
    }

    /// The photo's long side in pixels (brush sizes are shares of it).
    var longSide: Double { Double(Swift.max(base.width, base.height)) }

    /// The picture with `steps` drawn in order (liquify strokes last, as one field).
    public func render(_ steps: [Retouch]) -> RetouchResult {
        let indices = steps.indices.filter { steps[$0].tool != "liquify" }
        let pixelSteps = indices.map { steps[$0] }
        var image = base
        var drawn: [Retouch] = []
        // Steps already drawn last time (the usual case: one more step at the end) are not drawn again.
        if let last, last.given.count <= pixelSteps.count,
           zip(last.given, pixelSteps).enumerated().allSatisfy({ $0.element.0 == $0.element.1 || last.drawn[$0.offset] == $0.element.1 }) {
            image = last.image
            drawn = last.drawn
        }
        for step in pixelSteps.dropFirst(drawn.count) {
            drawn.append(draw(step, on: &image))
        }
        last = (pixelSteps, drawn, image)
        var sources: [Int: MaskPoint] = [:]
        for (k, i) in indices.enumerated() where steps[i].offset == nil {
            if let offset = drawn[k].offset { sources[i] = offset }
        }
        let strokes = steps.filter { $0.tool == "liquify" }
        guard !strokes.isEmpty else { return RetouchResult(image: image, sources: sources) }
        if let lastWarp, lastWarp.before == drawn, lastWarp.strokes == strokes {
            return RetouchResult(image: lastWarp.image, sources: sources)
        }
        let warped = field(for: strokes).warped(image)
        lastWarp = (drawn, strokes, warped)
        return RetouchResult(image: warped, sources: sources)
    }

    /// The liquify field of these strokes (strokes added at the end are added to the last field).
    func field(for strokes: [Retouch]) -> LiquifyField {
        var field: LiquifyField
        var done = 0
        if let liquify, liquify.strokes.count <= strokes.count, Array(strokes.prefix(liquify.strokes.count)) == liquify.strokes {
            field = liquify.field
            done = liquify.strokes.count
        } else {
            let grid = MaskRaster.gridSize(width: Double(base.width), height: Double(base.height))
            field = LiquifyField(width: grid.width, height: grid.height)
        }
        for stroke in strokes.dropFirst(done) { field.apply(stroke) }
        liquify = (strokes, field)
        return field
    }

    /// Where a point on the retouched picture (from the top-left, 0…1) was before the liquify strokes
    /// of the last render: a new spot made there is kept at that place, so it stays on what it covers.
    public func unwarp(_ p: MaskPoint) -> MaskPoint {
        liquify.map { $0.field.unwarp(p) } ?? p
    }

    /// Draws one step on `image`; returns the step as drawn (an automatic source filled in).
    private func draw(_ given: Retouch, on image: inout RGBBuffer) -> Retouch {
        let step = resolve(given, on: image)
        guard let plan = plan(step, width: image.width, height: image.height) else { return step }
        var key = step
        key.values["spotOpacity"] = nil
        let lookup = StepKey(step: key, read: image.checksum(plan.read))
        let result: [Float]
        if let known = results[lookup] {
            result = known
        } else {
            result = compute(step, plan: plan, image: image)
            if cachedFloats + result.count > 40_000_000 {
                results = [:]
                cachedFloats = 0
            }
            results[lookup] = result
            cachedFloats += result.count
        }
        // Opacity: part way from the picture before the step to the step's result.
        let opacity = Float(step.opacity)
        let box = plan.write
        for y in 0..<box.height {
            let row = 3 * ((box.y0 + y) * image.width + box.x0), part = 3 * y * box.width
            for i in 0..<(3 * box.width) {
                let before = image.pixels[row + i]
                image.pixels[row + i] = before + (result[part + i] - before) * opacity
            }
        }
        return step
    }

    /// Where a step reads and writes.
    struct Plan {
        var read: PixelBox
        var write: PixelBox
    }

    /// The boxes a step reads and writes on a `width` × `height` picture; nil when it touches nothing.
    func plan(_ step: Retouch, width: Int, height: Int) -> Plan? {
        let write = footprintBox(step, width: width, height: height)
        guard !write.isEmpty else { return nil }
        switch step.tool {
        case "remove":
            // The fill copies from around the stroke: up to a few brush widths away.
            let r = radius(step)
            let margin = Swift.max(16, Int(2 * r), Int(0.3 * Double(Swift.max(write.width, write.height))))
            return Plan(read: write.expanded(by: margin, width: width, height: height), write: write)
        case "heal":
            // A pixel more on each side for the edge the colours are matched on; the source box too.
            let box = write.expanded(by: 2, width: width, height: height)
            guard let o = pixels(step.offset) else { return nil }
            return Plan(read: union(box, shifted(box, o, width: width, height: height)), write: box)
        case "clone":
            guard let o = pixels(step.offset) else { return nil }
            return Plan(read: union(write, shifted(write, o, width: width, height: height)), write: write)
        case "patch":
            // As heal, with the outline instead of a brush stroke.
            let box = write.expanded(by: 2, width: width, height: height)
            guard let o = pixels(step.offset) else { return nil }
            return Plan(read: union(box, shifted(box, o, width: width, height: height)), write: box)
        case "redEye", "petEye":
            return Plan(read: write, write: write)
        case "move":
            // The area is filled from around it (as the Remove brush) and put down `offset` away.
            guard let o = pixels(step.offset), o.dx != 0 || o.dy != 0 else { return nil }
            let both = union(write, shifted(write, o, width: width, height: height))
            let margin = Swift.max(16, Int(0.5 * Double(Swift.max(write.width, write.height))))
            return Plan(read: both.expanded(by: margin, width: width, height: height), write: both)
        default:
            return nil
        }
    }

    /// Fills in what a step leaves to the canvas: a copying tool's source, picked nearby.
    func resolve(_ step: Retouch, on image: RGBBuffer) -> Retouch {
        guard RetouchTools.copying.contains(step.tool), step.offset == nil else { return step }
        let box = footprintBox(step, width: image.width, height: image.height)
        guard !box.isEmpty else { return step }
        let hole = footprint(step, in: box).map { $0 > 0.02 }
        var out = step
        let reach = RetouchTools.outlined.contains(step.tool) ? Double(Swift.min(box.width, box.height)) : 2 * radius(step)
        if let found = Healing.pickSource(hole: hole, box: box, image: image, diameter: reach, brightness: step.tool == "clone") {
            out.offset = MaskPoint(Double(found.dx) / Double(image.width), Double(found.dy) / Double(image.height))
        }
        return out
    }

    /// An offset as whole pixels.
    func pixels(_ offset: MaskPoint?) -> (dx: Int, dy: Int)? {
        offset.map { (Int(($0.x * Double(base.width)).rounded()), Int(($0.y * Double(base.height)).rounded())) }
    }

    /// `box` moved by an offset, cut to the picture.
    func shifted(_ box: PixelBox, _ o: (dx: Int, dy: Int), width: Int, height: Int) -> PixelBox {
        PixelBox(x0: box.x0 + o.dx, y0: box.y0 + o.dy, x1: box.x1 + o.dx, y1: box.y1 + o.dy).expanded(by: 0, width: width, height: height)
    }

    /// The smallest box holding both (an empty one counts as nothing).
    func union(_ a: PixelBox, _ b: PixelBox) -> PixelBox {
        if b.isEmpty { return a }
        return PixelBox(x0: Swift.min(a.x0, b.x0), y0: Swift.min(a.y0, b.y0), x1: Swift.max(a.x1, b.x1), y1: Swift.max(a.y1, b.y1))
    }

    /// The step's pixels in its write box, at full opacity.
    private func compute(_ step: Retouch, plan: Plan, image: RGBBuffer) -> [Float] {
        switch step.tool {
        case "remove":
            return remove(step, plan: plan, image: image)
        case "heal", "patch":
            return heal(step, plan: plan, image: image)
        case "move":
            return move(step, plan: plan, image: image)
        case "redEye", "petEye":
            var eye = image.crop(plan.write)
            let circle = eyeCircle(step)
            RedEye.fix(&eye, box: plan.write, centre: (circle.x, circle.y), radius: circle.r, pet: step.tool == "petEye",
                       pupilSize: step.values["pupilSize"] ?? 50, darken: step.values["pupilDarken"] ?? 50,
                       catchlight: (step.values["catchlight"] ?? 1) != 0)
            return eye.pixels
        case "clone":
            // The source's pixels as they are, blended in by the brush's soft edge.
            guard let o = pixels(step.offset) else { return image.crop(plan.write).pixels }
            let box = plan.write
            return blend(copied(image, box: box, offset: o), over: image.crop(box), cover: footprint(step, in: box), from: box, to: box)
        default:
            return image.crop(plan.write).pixels
        }
    }

    // MARK: - Brush geometry

    /// Brush radius in pixels.
    func radius(_ step: Retouch) -> Double {
        Swift.max(0.5, step.size / 100 * longSide / 2)
    }

    /// The stroke's dab centres in pixels (every quarter radius; one for a tap).
    func dabs(_ step: Retouch) -> [(x: Double, y: Double)] {
        let points = step.points.map { (x: $0.x * Double(base.width), y: $0.y * Double(base.height)) }
        return MaskRaster.resample(points, spacing: Swift.max(0.5, radius(step) / 4))
    }

    /// An eye tool's circle in pixels: a tap's is the brush, a line's is the circle around it.
    func eyeCircle(_ step: Retouch) -> (x: Double, y: Double, r: Double) {
        let xs = step.points.map { $0.x * Double(base.width) }, ys = step.points.map { $0.y * Double(base.height) }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return (0, 0, 0) }
        if step.points.count == 1 { return (x0, y0, radius(step)) }
        return ((x0 + x1) / 2, (y0 + y1) / 2, Swift.max(2, Swift.max(x1 - x0, y1 - y0) / 2))
    }

    /// The pixels the brush (or the outline, with its soft edge; or the eye circle) touches.
    func footprintBox(_ step: Retouch, width: Int, height: Int) -> PixelBox {
        if RetouchTools.eyes.contains(step.tool) {
            let c = eyeCircle(step)
            guard c.r > 0 else { return PixelBox(x0: 0, y0: 0, x1: 0, y1: 0) }
            return PixelBox(x0: Int((c.x - c.r).rounded(.down)) - 1, y0: Int((c.y - c.r).rounded(.down)) - 1,
                            x1: Int((c.x + c.r).rounded(.up)) + 1, y1: Int((c.y + c.r).rounded(.up)) + 1)
                .expanded(by: 0, width: width, height: height)
        }
        if RetouchTools.outlined.contains(step.tool) {
            guard step.points.count >= 3 else { return PixelBox(x0: 0, y0: 0, x1: 0, y1: 0) }
            let xs = step.points.map { $0.x * Double(base.width) }, ys = step.points.map { $0.y * Double(base.height) }
            let soft = softEdge(step) + 1
            return PixelBox(x0: Int((xs.min()! - soft).rounded(.down)), y0: Int((ys.min()! - soft).rounded(.down)),
                            x1: Int((xs.max()! + soft).rounded(.up)) + 1, y1: Int((ys.max()! + soft).rounded(.up)) + 1)
                .expanded(by: 0, width: width, height: height)
        }
        let dabs = self.dabs(step)
        guard !dabs.isEmpty else { return PixelBox(x0: 0, y0: 0, x1: 0, y1: 0) }
        let r = radius(step)
        let box = PixelBox(x0: Int((dabs.map(\.x).min()! - r).rounded(.down)), y0: Int((dabs.map(\.y).min()! - r).rounded(.down)),
                           x1: Int((dabs.map(\.x).max()! + r).rounded(.up)) + 1, y1: Int((dabs.map(\.y).max()! + r).rounded(.up)) + 1)
        return box.expanded(by: 0, width: width, height: height)
    }

    /// An outline's soft edge in pixels: Brush Feather 100 % is 1 % of the photo's long side.
    func softEdge(_ step: Retouch) -> Double {
        Swift.max(1, step.feather / 100 * 0.01 * longSide)
    }

    /// How much the brush covers each pixel of `box` (0…1): round dabs with the step's soft edge, or
    /// the inside of the outline, softened.
    func footprint(_ step: Retouch, in box: PixelBox) -> [Float] {
        if RetouchTools.outlined.contains(step.tool) {
            let path = step.points.map {
                MaskPoint(($0.x * Double(base.width) - Double(box.x0)) / Double(box.width),
                          ($0.y * Double(base.height) - Double(box.y0)) / Double(box.height))
            }
            let inside = MaskRaster.polygon(path, width: box.width, height: box.height)
            return MaskRaster.blur(inside, width: box.width, height: box.height, radius: Swift.max(1, Int(softEdge(step) / 2)))
        }
        var out = [Float](repeating: 0, count: box.width * box.height)
        let r = radius(step)
        let soft = Swift.max(step.feather / 100, 1.5 / r)
        for dab in dabs(step) {
            let ya = Swift.max(box.y0, Int((dab.y - r).rounded(.down))), yb = Swift.min(box.y1 - 1, Int((dab.y + r).rounded(.up)))
            let xa = Swift.max(box.x0, Int((dab.x - r).rounded(.down))), xb = Swift.min(box.x1 - 1, Int((dab.x + r).rounded(.up)))
            guard ya <= yb, xa <= xb else { continue }
            for y in ya...yb {
                let dy = Double(y) + 0.5 - dab.y
                for x in xa...xb {
                    let dx = Double(x) + 0.5 - dab.x
                    let d = (dx * dx + dy * dy).squareRoot() / r
                    guard d < 1 else { continue }
                    let k = (y - box.y0) * box.width + (x - box.x0)
                    out[k] = Swift.max(out[k], Float(1 - Effects.smoothstep(1 - soft, 1, d)))
                }
            }
        }
        return out
    }

    // MARK: - Remove brush

    /// Content-aware fill of the painted area (Inpaint), blended in by the brush's soft edge.
    private func remove(_ step: Retouch, plan: Plan, image: RGBBuffer) -> [Float] {
        let crop = image.crop(plan.read)
        let cover = footprint(step, in: plan.read)
        let filled = Inpaint.fill(crop, hole: cover.map { $0 > 0.02 })
        return blend(filled, over: crop, cover: cover, from: plan.read, to: plan.write)
    }

    // MARK: - Heal

    /// The source's pixels with the membrane added (so they meet the colours around the spot), blended in
    /// by the brush's soft edge.
    private func heal(_ step: Retouch, plan: Plan, image: RGBBuffer) -> [Float] {
        let box = plan.write
        guard let o = pixels(step.offset) else { return image.crop(box).pixels }
        let here = image.crop(box)
        let source = copied(image, box: box, offset: o)
        let cover = footprint(step, in: box)
        let difference = zip(here.pixels, source.pixels).map { $0 - $1 }
        let correction = Healing.membrane(difference, hole: cover.map { $0 > 0.02 }, width: box.width, height: box.height)
        let healed = RGBBuffer(width: box.width, height: box.height, pixels: zip(source.pixels, correction).map { $0 + $1 })
        return blend(healed, over: here, cover: cover, from: box, to: box)
    }

    // MARK: - Content-Aware Move

    /// The area filled from around it, then its old pixels put down `offset` away, matched to the
    /// colours around their new place (the heal membrane) and blended in by the soft edge.
    private func move(_ step: Retouch, plan: Plan, image: RGBBuffer) -> [Float] {
        guard let o = pixels(step.offset) else { return image.crop(plan.write).pixels }
        let read = plan.read
        let crop = image.crop(read)
        let cover = footprint(step, in: read)
        let emptied = RGBBuffer(width: read.width, height: read.height,
                                pixels: blend(Inpaint.fill(crop, hole: cover.map { $0 > 0.02 }), over: crop, cover: cover, from: read, to: read))
        // In the write box: what is there now (emptied), the area's old pixels `offset` back, its cover.
        let box = plan.write
        let n = box.width * box.height
        var under = [Float](repeating: 0, count: 3 * n), moved = under
        var landing = [Float](repeating: 0, count: n)
        for y in 0..<box.height {
            for x in 0..<box.width {
                let ix = box.x0 + x - read.x0, iy = box.y0 + y - read.y0, j = y * box.width + x
                let sx = Swift.min(read.width - 1, Swift.max(0, ix - o.dx)), sy = Swift.min(read.height - 1, Swift.max(0, iy - o.dy))
                let inside = ix - o.dx == sx && iy - o.dy == sy
                landing[j] = inside ? cover[sy * read.width + sx] : 0
                for c in 0..<3 {
                    under[3 * j + c] = emptied.pixels[3 * (iy * read.width + ix) + c]
                    moved[3 * j + c] = crop.pixels[3 * (sy * read.width + sx) + c]
                }
            }
        }
        let correction = Healing.membrane(zip(under, moved).map { $0 - $1 }, hole: landing.map { $0 > 0.02 },
                                          width: box.width, height: box.height)
        var out = under
        for j in 0..<n where landing[j] > 0 {
            for c in 0..<3 {
                let placed = moved[3 * j + c] + correction[3 * j + c]
                out[3 * j + c] = under[3 * j + c] + (placed - under[3 * j + c]) * landing[j]
            }
        }
        return out
    }

    /// The pixels `offset` away from each pixel of `box` (the picture's edge repeated outside it).
    func copied(_ image: RGBBuffer, box: PixelBox, offset o: (dx: Int, dy: Int)) -> RGBBuffer {
        var out = [Float](repeating: 0, count: box.width * box.height * 3)
        for y in 0..<box.height {
            let sy = Swift.min(image.height - 1, Swift.max(0, box.y0 + y + o.dy))
            for x in 0..<box.width {
                let sx = Swift.min(image.width - 1, Swift.max(0, box.x0 + x + o.dx))
                let c = image.color(sx, sy), i = 3 * (y * box.width + x)
                out[i] = c.0
                out[i + 1] = c.1
                out[i + 2] = c.2
            }
        }
        return RGBBuffer(width: box.width, height: box.height, pixels: out)
    }

    /// `top` over `bottom` (both pictures of the `from` box) by `cover`, cut to the `to` box.
    func blend(_ top: RGBBuffer, over bottom: RGBBuffer, cover: [Float], from: PixelBox, to: PixelBox) -> [Float] {
        var out = [Float](repeating: 0, count: to.width * to.height * 3)
        for y in 0..<to.height {
            for x in 0..<to.width {
                let i = (to.y0 - from.y0 + y) * from.width + (to.x0 - from.x0 + x)
                let o = 3 * (y * to.width + x)
                let k = cover[i]
                for c in 0..<3 {
                    out[o + c] = bottom.pixels[3 * i + c] + (top.pixels[3 * i + c] - bottom.pixels[3 * i + c]) * k
                }
            }
        }
        return out
    }
}
