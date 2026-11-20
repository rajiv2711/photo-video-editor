import Foundation

/// Liquify (Photoshop's push, twirl, pucker, bloat and reconstruct brushes): every liquify stroke
/// changes one displacement field, and the picture is read through it once. The field is a grid the
/// size of the mask grid (half the photo's long side, 800…2048 cells; displacements are smooth), each
/// cell saying where its pixels come from: output point x shows the picture at x + d(x), in cells.
/// It is worked out again from the strokes kept in the edit (nothing is baked in), so a stroke can
/// be deleted and the saved photo matches the preview.
public struct LiquifyField: Equatable {
    public let width: Int
    public let height: Int
    /// Displacement across and down, in cells, row by row from the top.
    var dx: [Float]
    var dy: [Float]
    /// Cells that may have moved (nil: none).
    var touched: PixelBox?

    /// The modes, as the "liquifyMode" choice orders them.
    public static let modes = ["push", "twirl", "pucker", "bloat", "reconstruct"]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        dx = [Float](repeating: 0, count: width * height)
        dy = dx
    }

    public var isEmpty: Bool { touched == nil }

    /// The displacement at a point in cells (cell centres at whole numbers + ½), blended from the four nearest.
    public func displacement(x: Double, y: Double) -> (x: Double, y: Double) {
        let fx = Swift.min(Swift.max(x - 0.5, 0), Double(width - 1)), fy = Swift.min(Swift.max(y - 0.5, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = Swift.min(x0 + 1, width - 1), y1 = Swift.min(y0 + 1, height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func at(_ v: [Float]) -> Double {
            let top = Double(v[y0 * width + x0]) * (1 - tx) + Double(v[y0 * width + x1]) * tx
            let bottom = Double(v[y1 * width + x0]) * (1 - tx) + Double(v[y1 * width + x1]) * tx
            return top * (1 - ty) + bottom * ty
        }
        return (at(dx), at(dy))
    }

    /// Adds one liquify stroke. Its brush (size, % of the long side), points, pressure, mode
    /// ("liquifyMode") and strength ("toolStrength" × opacity) come from the step. A tap works as if
    /// the brush were held still for a moment (ten dabs).
    public mutating func apply(_ step: Retouch) {
        let long = Double(Swift.max(width, height))
        let r = Swift.max(1, step.size / 100 * long / 2)
        let points = step.points.map { (x: $0.x * Double(width), y: $0.y * Double(height)) }
        var dabs = MaskRaster.resample(points, spacing: Swift.max(0.5, r / 4))
        var pressure = dabs.map { _ in 1.0 }
        if !step.pressure.isEmpty, step.pressure.count == step.points.count {
            // Each dab takes the pressure of the nearest stroke point.
            pressure = dabs.map { dab in
                let nearest = points.indices.min { a, b in
                    hypot(points[a].x - dab.x, points[a].y - dab.y) < hypot(points[b].x - dab.x, points[b].y - dab.y)
                }
                return nearest.map { step.pressure[$0] } ?? 1
            }
        }
        if dabs.count == 1 {
            dabs = Array(repeating: dabs[0], count: 10)
            pressure = Array(repeating: pressure[0], count: 10)
        }
        let mode = Int(step.values["liquifyMode"] ?? 0)
        let strength = Swift.min(1, Swift.max(0, (step.values["toolStrength"] ?? 50) / 100)) * step.opacity
        for (i, dab) in dabs.enumerated() {
            let s = strength * pressure[i]
            guard s > 0 else { continue }
            switch mode {
            case 0:  // push: the pixels under the brush go along with it
                guard i > 0 else { continue }
                let v = ((dab.x - dabs[i - 1].x) * s, (dab.y - dabs[i - 1].y) * s)
                guard v.0 != 0 || v.1 != 0 else { continue }
                warp(around: dab, radius: r) { x, y, w in (x - w * v.0, y - w * v.1) }
            case 1:  // twirl: clockwise around the brush's middle
                let angle = 0.15 * s
                warp(around: dab, radius: r) { x, y, w in
                    let a = -angle * w, ux = x - dab.x, uy = y - dab.y
                    return (dab.x + ux * cos(a) - uy * sin(a), dab.y + ux * sin(a) + uy * cos(a))
                }
            case 2, 3:  // pucker: towards the middle; bloat: away from it
                let k = (mode == 2 ? 1 : -1) * 0.06 * s
                warp(around: dab, radius: r) { x, y, w in (dab.x + (x - dab.x) * (1 + k * w), dab.y + (y - dab.y) * (1 + k * w)) }
            default:  // reconstruct: back towards the picture as it was
                relax(around: dab, radius: r, by: 0.5 * s)
            }
        }
    }

    /// The brush's weight at distance `d` from its middle: 1 there, 0 at the edge, smooth.
    static func falloff(_ d: Double, _ r: Double) -> Double {
        guard d < r else { return 0 }
        let t = 1 - (d / r) * (d / r)
        return t * t
    }

    /// One dab of a moving brush: inside it each point x now shows what the field showed at
    /// `source(x, y, weight)`. New field: d'(x) = source − x + d(source).
    private mutating func warp(around c: (x: Double, y: Double), radius r: Double, source: (Double, Double, Double) -> (Double, Double)) {
        guard let box = cells(around: c, radius: r) else { return }
        var newX = [Float](repeating: 0, count: box.width * box.height), newY = newX
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let w = Self.falloff(hypot(px - c.x, py - c.y), r)
                let k = (y - box.y0) * box.width + (x - box.x0)
                guard w > 0 else {
                    newX[k] = dx[y * width + x]
                    newY[k] = dy[y * width + x]
                    continue
                }
                let from = source(px, py, w)
                let d = displacement(x: from.0, y: from.1)
                newX[k] = Float(from.0 - px + d.x)
                newY[k] = Float(from.1 - py + d.y)
            }
        }
        store(newX, newY, in: box)
    }

    /// Reconstruct: the field shrinks towards none by up to `amount` at the brush's middle.
    private mutating func relax(around c: (x: Double, y: Double), radius r: Double, by amount: Double) {
        guard let box = cells(around: c, radius: r) else { return }
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let w = Self.falloff(hypot(Double(x) + 0.5 - c.x, Double(y) + 0.5 - c.y), r)
                let i = y * width + x
                dx[i] *= Float(1 - amount * w)
                dy[i] *= Float(1 - amount * w)
            }
        }
    }

    /// The cells a dab reaches, inside the grid.
    private func cells(around c: (x: Double, y: Double), radius r: Double) -> PixelBox? {
        let box = PixelBox(x0: Int((c.x - r).rounded(.down)), y0: Int((c.y - r).rounded(.down)),
                           x1: Int((c.x + r).rounded(.up)) + 1, y1: Int((c.y + r).rounded(.up)) + 1)
            .expanded(by: 0, width: width, height: height)
        return box.isEmpty ? nil : box
    }

    private mutating func store(_ newX: [Float], _ newY: [Float], in box: PixelBox) {
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let k = (y - box.y0) * box.width + (x - box.x0)
                dx[y * width + x] = newX[k]
                dy[y * width + x] = newY[k]
            }
        }
        if let t = touched {
            touched = PixelBox(x0: Swift.min(t.x0, box.x0), y0: Swift.min(t.y0, box.y0), x1: Swift.max(t.x1, box.x1), y1: Swift.max(t.y1, box.y1))
        } else {
            touched = box
        }
    }

    /// The picture read through the field (only the part the strokes reached is worked out).
    public func warped(_ image: RGBBuffer) -> RGBBuffer {
        guard let t = touched, image.width > 0, image.height > 0 else { return image }
        let sx = Double(image.width) / Double(width), sy = Double(image.height) / Double(height)
        let box = PixelBox(x0: Int(Double(t.x0) * sx) - 1, y0: Int(Double(t.y0) * sy) - 1,
                           x1: Int((Double(t.x1) * sx).rounded(.up)) + 1, y1: Int((Double(t.y1) * sy).rounded(.up)) + 1)
            .expanded(by: 0, width: image.width, height: image.height)
        var out = image
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let d = displacement(x: (Double(x) + 0.5) / sx, y: (Double(y) + 0.5) / sy)
                guard d.x != 0 || d.y != 0 else { continue }
                let c = image.bilinear(x: Double(x) + d.x * sx, y: Double(y) + d.y * sy)
                let i = 3 * (y * image.width + x)
                out.pixels[i] = c.0
                out.pixels[i + 1] = c.1
                out.pixels[i + 2] = c.2
            }
        }
        return out
    }

    /// Where a point on the liquified picture (from the top-left, 0…1) was before liquify.
    public func unwarp(_ p: MaskPoint) -> MaskPoint {
        guard !isEmpty else { return p }
        let d = displacement(x: p.x * Double(width), y: p.y * Double(height))
        return MaskPoint(p.x + d.x / Double(width), p.y + d.y / Double(height))
    }
}
