import Foundation

/// The photo as the mask maths see it: sRGB levels (0…1), 3 numbers per cell, row by row from the
/// top. The iPad reads it once per photo (after the lens corrections, before other edits), at the
/// mask grid's size.
public final class PixelGrid {
    public let width: Int
    public let height: Int
    /// r, g, b, r, g, b, … on sRGB levels.
    public let rgb: [Float]

    public init(width: Int, height: Int, rgb: [Float]) {
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    /// From RGBA numbers (4 per cell, alpha ignored).
    public convenience init(width: Int, height: Int, rgba: [Float]) {
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<Swift.min(width * height, rgba.count / 4) {
            rgb[3 * i] = rgba[4 * i]
            rgb[3 * i + 1] = rgba[4 * i + 1]
            rgb[3 * i + 2] = rgba[4 * i + 2]
        }
        self.init(width: width, height: height, rgb: rgb)
    }

    /// Colour of one cell.
    func color(_ i: Int) -> (Float, Float, Float) {
        (rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2])
    }

    /// CIE L*a*b* of every cell (L 0…100), worked out the first time a colour range needs it.
    public private(set) lazy var lab: [Float] = {
        var out = [Float](repeating: 0, count: rgb.count)
        for i in 0..<(rgb.count / 3) {
            let c = MaskRaster.lab(rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2])
            out[3 * i] = c.l
            out[3 * i + 1] = c.a
            out[3 * i + 2] = c.b
        }
        return out
    }()
}

/// Mask pictures as numbers: a grid of `width` × `height` cells (0 = untouched, 1 = full local
/// adjustment), row by row from the top, cell centres at ((column + ½) / width, (row + ½) / height).
/// The iPad stretches the grid over the photo. Sizes are shares of the photo, so a mask looks the
/// same on the preview and on the saved photo. Tested on Linux.
public enum MaskRaster {
    /// Grid size for a photo of `width` × `height` pixels: half its long side, but at least 800
    /// cells (or the photo's own size) and at most 2048, the short side in proportion.
    public static func gridSize(width: Double, height: Double) -> (width: Int, height: Int) {
        let long = Swift.max(width, height)
        guard long > 0 else { return (2, 2) }
        let cells = Swift.min(2048, Swift.max(Swift.min(long, 800), long / 2))
        let scale = cells / long
        return (Swift.max(2, Int((width * scale).rounded())), Swift.max(2, Int((height * scale).rounded())))
    }

    /// Whether the mask needs the photo's pixels (colour and brightness ranges, auto mask, …).
    public static func needsPixels(_ mask: Mask) -> Bool {
        mask.components.contains { part in
            ["colorRange", "luminanceRange", "magicWand", "quickSelect"].contains(part.kind)
                || part.strokes.contains { $0.autoMask }
        }
    }

    /// The whole mask: its parts joined in order, then refined.
    public static func render(_ mask: Mask, width: Int, height: Int, pixels: PixelGrid?) -> [Float] {
        let parts = mask.components.map { (part($0, width: width, height: height, pixels: pixels), $0.mode) }
        return combine(parts, count: width * height)
    }

    /// Joins parts in order: add keeps the larger value, subtract takes the part away
    /// (× (1 − part)), intersect keeps only where both are (×).
    public static func combine(_ parts: [([Float], MaskComponent.Mode)], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for (values, mode) in parts where values.count == count {
            for i in 0..<count {
                switch mode {
                case .add: out[i] = Swift.max(out[i], values[i])
                case .subtract: out[i] *= 1 - values[i]
                case .intersect: out[i] *= values[i]
                }
            }
        }
        return out
    }

    /// One part's picture (inverted when its Invert is on).
    public static func part(_ part: MaskComponent, width: Int, height: Int, pixels: PixelGrid?) -> [Float] {
        var values: [Float]
        switch part.kind {
        case "brush":
            values = strokes(part.strokes, width: width, height: height, pixels: pixels)
        case "linear":
            values = linear(angle: part.values["linearAngle"] ?? 0, position: part.values["linearPosition"] ?? 25,
                            fade: part.values["linearWidth"] ?? 50, width: width, height: height)
        case "colorRange":
            values = colorRange(part, width: width, height: height, pixels: pixels)
        case "radial":
            let v = part.values
            values = radial(x: v["radialX"] ?? 50, y: v["radialY"] ?? 50, size: v["radialSize"] ?? 60, aspect: v["radialAspect"] ?? 0,
                            angle: v["radialAngle"] ?? 0, feather: v["radialFeather"] ?? 50, width: width, height: height)
        default:
            values = [Float](repeating: 0, count: width * height)
        }
        if part.inverted {
            for i in values.indices { values[i] = 1 - values[i] }
        }
        return values
    }

    // MARK: - Linear gradient

    /// Full on one side of a line, fading to nothing across `fade` % of the photo's span in that
    /// direction. `angle`: the full side, 0 = top, turning clockwise (90 = right, 180 = bottom,
    /// −90 = left); `position`: where the middle of the fade sits, % across from the full side.
    public static func linear(angle: Double, position: Double, fade: Double, width: Int, height: Int) -> [Float] {
        let a = angle * .pi / 180
        let nx = -sin(a), ny = cos(a)  // from the full side towards none
        let w = Double(width), h = Double(height)
        let span = abs(nx) * w + abs(ny) * h
        let offset = (position / 100 - 0.5) * span
        let length = Swift.max(1, fade / 100 * span)
        var out = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let y = Double(row) + 0.5 - h / 2
            for column in 0..<width {
                let x = Double(column) + 0.5 - w / 2
                let t = (x * nx + y * ny - offset) / length + 0.5
                out[row * width + column] = Float(1 - Effects.smoothstep(0, 1, t))
            }
        }
        return out
    }

    // MARK: - Radial gradient

    /// An ellipse, full inside and fading out towards its edge. `x`, `y`: its centre, % of the
    /// width and height from the top-left; `size`: its radius, % of half the short side; `aspect`
    /// −100…100 (+ wider, − taller); `angle`: turned clockwise, degrees; `feather` 0…100: 0 a hard
    /// edge, 100 fading all the way from the centre.
    public static func radial(x: Double, y: Double, size: Double, aspect: Double, angle: Double, feather: Double,
                              width: Int, height: Int) -> [Float] {
        let w = Double(width), h = Double(height)
        let radii = MaskGeometry.radialRadii(size: size, aspect: aspect, width: w, height: h)
        let rx = Swift.max(0.5, radii.x), ry = Swift.max(0.5, radii.y)
        let cx = x / 100 * w, cy = y / 100 * h
        let a = angle * .pi / 180, c = cos(a), s = sin(a)
        let soft = Swift.max(feather / 100, 1.5 / Swift.min(rx, ry))
        var out = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let dy = Double(row) + 0.5 - cy
            for column in 0..<width {
                let dx = Double(column) + 0.5 - cx
                let u = (dx * c + dy * s) / rx, v = (dy * c - dx * s) / ry
                let d = (u * u + v * v).squareRoot()
                out[row * width + column] = d >= 1 ? 0 : Float(1 - Effects.smoothstep(1 - soft, 1, d))
            }
        }
        return out
    }

    // MARK: - Color range

    /// Colour range: colours like the one tapped (its `point`, averaged over 3 × 3 cells), or a
    /// named hue (its "hue" value, degrees: every shade of that hue with some colour in it).
    /// Color Range Refine (0…100) widens it.
    public static func colorRange(_ part: MaskComponent, width: Int, height: Int, pixels: PixelGrid?) -> [Float] {
        let refine = part.values["colorRangeRefine"] ?? 50
        guard let pixels, pixels.width == width, pixels.height == height else {
            return [Float](repeating: 0, count: width * height)
        }
        if let point = part.point {
            return similarColors(to: sample(pixels.lab, at: point, width: width, height: height), refine: refine, lab: pixels.lab)
        }
        if let hue = part.values["hue"] {
            return hueRange(hue, refine: refine, pixels: pixels)
        }
        return [Float](repeating: 0, count: width * height)
    }

    /// Cells whose colour is within reach of `target` (L*a*b*): full up to half the reach, none
    /// beyond it. Brightness counts half as much as colour. Reach 10…60 ΔE by `refine` 0…100.
    static func similarColors(to target: (l: Float, a: Float, b: Float), refine: Double, lab: [Float]) -> [Float] {
        let reach = Float(10 + 0.5 * Swift.min(100, Swift.max(0, refine)))
        var out = [Float](repeating: 0, count: lab.count / 3)
        for i in out.indices {
            let dl = 0.5 * (lab[3 * i] - target.l), da = lab[3 * i + 1] - target.a, db = lab[3 * i + 2] - target.b
            let d = (dl * dl + da * da + db * db).squareRoot()
            out[i] = d >= reach ? 0 : Float(1 - Effects.smoothstep(Double(reach / 2), Double(reach), Double(d)))
        }
        return out
    }

    /// Cells of one hue (sRGB hue, degrees), full within half the band, none beyond it (band
    /// 15…45° by `refine`); greys and nearly-greys are left out.
    static func hueRange(_ hue: Double, refine: Double, pixels: PixelGrid) -> [Float] {
        let band = 15 + 0.3 * Swift.min(100, Swift.max(0, refine))
        var out = [Float](repeating: 0, count: pixels.width * pixels.height)
        for i in out.indices {
            let (r, g, b) = pixels.color(i)
            let hi = Swift.max(r, g, b), lo = Swift.min(r, g, b)
            let chroma = Double(hi - lo)
            guard chroma > 0.06 else { continue }
            var h: Double
            if hi == r {
                h = 60 * Double((g - b) / (hi - lo))
            } else if hi == g {
                h = 60 * (2 + Double((b - r) / (hi - lo)))
            } else {
                h = 60 * (4 + Double((r - g) / (hi - lo)))
            }
            h = (h - hue).truncatingRemainder(dividingBy: 360)
            if h > 180 { h -= 360 } else if h < -180 { h += 360 }
            out[i] = Float(Effects.smoothstep(0.06, 0.16, chroma) * (1 - Effects.smoothstep(band / 2, band, abs(h))))
        }
        return out
    }

    /// Average L*a*b* of the 3 × 3 cells around a point.
    static func sample(_ lab: [Float], at point: MaskPoint, width: Int, height: Int) -> (l: Float, a: Float, b: Float) {
        let cx = Swift.min(width - 1, Swift.max(0, Int(point.x * Double(width))))
        let cy = Swift.min(height - 1, Swift.max(0, Int(point.y * Double(height))))
        var sum: (Float, Float, Float) = (0, 0, 0)
        var n: Float = 0
        for y in Swift.max(0, cy - 1)...Swift.min(height - 1, cy + 1) {
            for x in Swift.max(0, cx - 1)...Swift.min(width - 1, cx + 1) {
                let i = 3 * (y * width + x)
                sum = (sum.0 + lab[i], sum.1 + lab[i + 1], sum.2 + lab[i + 2])
                n += 1
            }
        }
        return (sum.0 / n, sum.1 / n, sum.2 / n)
    }

    /// sRGB levels → CIE L*a*b* (D65).
    static func lab(_ r: Float, _ g: Float, _ b: Float) -> (l: Float, a: Float, b: Float) {
        func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
        let rl = linear(r), gl = linear(g), bl = linear(b)
        let x = (0.4124 * rl + 0.3576 * gl + 0.1805 * bl) / 0.95047
        let y = 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
        let z = (0.0193 * rl + 0.1192 * gl + 0.9505 * bl) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    // MARK: - Brush

    /// Brush strokes in painting order. Each stroke is a row of round dabs (every quarter of the
    /// radius) that build up by its flow, up to its density; an eraser stroke takes away.
    /// With auto mask a dab only covers colours close to the one under its centre.
    public static func strokes(_ strokes: [MaskStroke], width: Int, height: Int, pixels: PixelGrid?) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        let long = Double(Swift.max(width, height))
        for stroke in strokes {
            let radius = Swift.max(0.5, stroke.size / 100 * long / 2)
            let dabs = resample(stroke.points.map { (x: $0.x * Double(width), y: $0.y * Double(height)) },
                                spacing: Swift.max(0.5, radius / 4))
            guard !dabs.isEmpty else { continue }
            // The stroke's own coverage, on the box it touches.
            let x0 = Swift.max(0, Int((dabs.map(\.x).min()! - radius).rounded(.down)))
            let x1 = Swift.min(width - 1, Int((dabs.map(\.x).max()! + radius).rounded(.up)))
            let y0 = Swift.max(0, Int((dabs.map(\.y).min()! - radius).rounded(.down)))
            let y1 = Swift.min(height - 1, Int((dabs.map(\.y).max()! + radius).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            let boxWidth = x1 - x0 + 1
            var cover = [Float](repeating: 0, count: boxWidth * (y1 - y0 + 1))
            let flow = Float(Swift.min(1, Swift.max(0, stroke.flow / 100)))
            let soft = Swift.max(stroke.feather / 100, 1.5 / radius)
            let autoMask = stroke.autoMask ? pixels.flatMap { $0.width == width && $0.height == height ? $0 : nil } : nil
            for dab in dabs {
                var centre: (Float, Float, Float)?
                if let grid = autoMask {
                    let cx = Swift.min(width - 1, Swift.max(0, Int(dab.x))), cy = Swift.min(height - 1, Swift.max(0, Int(dab.y)))
                    centre = grid.color(cy * width + cx)
                }
                let ya = Swift.max(y0, Int((dab.y - radius).rounded(.down))), yb = Swift.min(y1, Int((dab.y + radius).rounded(.up)))
                let xa = Swift.max(x0, Int((dab.x - radius).rounded(.down))), xb = Swift.min(x1, Int((dab.x + radius).rounded(.up)))
                guard ya <= yb, xa <= xb else { continue }
                for y in ya...yb {
                    let dy = Double(y) + 0.5 - dab.y
                    for x in xa...xb {
                        let dx = Double(x) + 0.5 - dab.x
                        let d = (dx * dx + dy * dy).squareRoot() / radius
                        guard d < 1 else { continue }
                        var p = Float(1 - Effects.smoothstep(1 - soft, 1, d))
                        if let grid = autoMask, let c = centre {
                            p *= similarity(grid.color(y * width + x), c)
                        }
                        let k = (y - y0) * boxWidth + (x - x0)
                        cover[k] += flow * p * (1 - cover[k])
                    }
                }
            }
            let density = Float(Swift.min(1, Swift.max(0, stroke.density / 100)))
            for y in y0...y1 {
                for x in x0...x1 {
                    let c = Swift.min(1, cover[(y - y0) * boxWidth + (x - x0)]) * density
                    let i = y * width + x
                    out[i] = stroke.erase ? out[i] * (1 - c) : Swift.max(out[i], c)
                }
            }
        }
        return out
    }

    /// Auto mask: 1 for the same colour, fading to 0 by a distance of 0.2 (sRGB levels).
    static func similarity(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        let d = Double((dr * dr + dg * dg + db * db).squareRoot())
        return Float(1 - Effects.smoothstep(0.08, 0.2, d))
    }

    /// Points along a path every `spacing` (the first and last always), in grid cells.
    static func resample(_ points: [(x: Double, y: Double)], spacing: Double) -> [(x: Double, y: Double)] {
        guard var last = points.first else { return [] }
        var out = [last]
        var carried = 0.0
        for next in points.dropFirst() {
            let dx = next.x - last.x, dy = next.y - last.y
            let length = (dx * dx + dy * dy).squareRoot()
            var t = spacing - carried
            while t <= length {
                out.append((last.x + dx * t / length, last.y + dy * t / length))
                t += spacing
            }
            carried = length - (t - spacing)
            last = next
        }
        if let end = points.last, points.count > 1, let placed = out.last, placed.x != end.x || placed.y != end.y {
            out.append(end)
        }
        return out
    }
}
