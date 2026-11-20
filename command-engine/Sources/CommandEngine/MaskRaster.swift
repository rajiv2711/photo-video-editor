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
        default:
            values = [Float](repeating: 0, count: width * height)
        }
        if part.inverted {
            for i in values.indices { values[i] = 1 - values[i] }
        }
        return values
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
