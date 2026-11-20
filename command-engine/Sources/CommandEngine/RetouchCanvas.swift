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
/// works out what really changed. The iPad keeps one canvas per picture (preview or full size).
public final class RetouchCanvas {
    /// The picture before any retouching.
    public let base: RGBBuffer
    /// The last render: the steps as given, as drawn (sources filled in), and the picture.
    private var last: (given: [Retouch], drawn: [Retouch], image: RGBBuffer)?
    /// Results of single steps: (step without opacity, checksum of what it read) → its pixels in its box.
    private var results: [StepKey: [Float]] = [:]
    private var cachedFloats = 0

    struct StepKey: Hashable {
        let step: Retouch
        let read: UInt64
    }

    public init(base: RGBBuffer) {
        self.base = base
    }

    /// The photo's long side in pixels (brush sizes are shares of it).
    var longSide: Double { Double(Swift.max(base.width, base.height)) }

    /// The picture with `steps` drawn in order.
    public func render(_ steps: [Retouch]) -> RetouchResult {
        var image = base
        var drawn: [Retouch] = []
        // Steps already drawn last time (the usual case: one more step at the end) are not drawn again.
        if let last, last.given.count <= steps.count,
           zip(last.given, steps).enumerated().allSatisfy({ $0.element.0 == $0.element.1 || last.drawn[$0.offset] == $0.element.1 }) {
            image = last.image
            drawn = last.drawn
        }
        for step in steps.dropFirst(drawn.count) {
            drawn.append(draw(step, on: &image))
        }
        last = (steps, drawn, image)
        return RetouchResult(image: image, sources: [:])
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
        default:
            return nil
        }
    }

    /// Fills in what a step leaves to the canvas (none so far).
    func resolve(_ step: Retouch, on image: RGBBuffer) -> Retouch {
        step
    }

    /// The step's pixels in its write box, at full opacity.
    private func compute(_ step: Retouch, plan: Plan, image: RGBBuffer) -> [Float] {
        switch step.tool {
        case "remove":
            return remove(step, plan: plan, image: image)
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

    /// The pixels the brush touches.
    func footprintBox(_ step: Retouch, width: Int, height: Int) -> PixelBox {
        let dabs = self.dabs(step)
        guard !dabs.isEmpty else { return PixelBox(x0: 0, y0: 0, x1: 0, y1: 0) }
        let r = radius(step)
        let box = PixelBox(x0: Int((dabs.map(\.x).min()! - r).rounded(.down)), y0: Int((dabs.map(\.y).min()! - r).rounded(.down)),
                           x1: Int((dabs.map(\.x).max()! + r).rounded(.up)) + 1, y1: Int((dabs.map(\.y).max()! + r).rounded(.up)) + 1)
        return box.expanded(by: 0, width: width, height: height)
    }

    /// How much the brush covers each pixel of `box` (0…1): round dabs with the step's soft edge.
    func footprint(_ step: Retouch, in box: PixelBox) -> [Float] {
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
