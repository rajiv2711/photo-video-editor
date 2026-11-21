import Foundation

/// Stickers (Layers panel): a small set of simple vector pictures made here from shapes (no downloaded
/// or licensed art). Each is a list of filled parts in a box of side 1 around its centre (−0.5…0.5,
/// y down), drawn in order; a sticker layer shows it `side` L units across at Layer Scale 100.
public enum Stickers {
    /// "addSticker" option ids, in order; must match controls.json.
    public static let ids = ["heart", "star", "smiley", "sun", "cloud", "flower", "crown", "sparkle", "arrow", "speech"]

    /// A sticker's size, in L units, at Layer Scale 100.
    public static let side = 0.25

    /// One part of a sticker: a filled outline, a filled ellipse or a line `width` wide (box units).
    public enum Shape: Equatable {
        case polygon([Vec2])
        case ellipse(center: Vec2, rx: Double, ry: Double)
        case line([Vec2], width: Double)
    }

    public struct Part: Equatable {
        public let shape: Shape
        /// sRGB levels.
        public let color: RGB
    }

    /// The parts of a sticker, bottom first (empty for an unknown id).
    public static func parts(_ id: String) -> [Part] {
        let ink = RGB(0.2, 0.13, 0.08)
        switch id {
        case "heart":
            // The classic heart curve, scaled into the box.
            let points = (0..<72).map { i -> Vec2 in
                let t = Double(i) / 72 * 2 * .pi
                let x = 16 * pow(sin(t), 3)
                let y = -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))
                return Vec2(x / 34, (y - 2.5) / 34)
            }
            return [Part(shape: .polygon(points), color: RGB(0.9, 0.13, 0.25))]
        case "star":
            return [Part(shape: .polygon(star(points: 5, outer: 0.5, inner: 0.2)), color: RGB(1, 0.8, 0.12))]
        case "sparkle":
            return [Part(shape: .polygon(star(points: 4, outer: 0.5, inner: 0.1)), color: RGB(1, 0.95, 0.6)),
                    Part(shape: .polygon(star(points: 4, outer: 0.2, inner: 0.05).map { $0 * 1 + Vec2(0.3, -0.3) }), color: RGB(1, 0.95, 0.6))]
        case "smiley":
            let smile = (0...16).map { i -> Vec2 in
                let a = (25 + Double(i) / 16 * 130) * .pi / 180
                return Vec2(cos(a) * 0.28, 0.02 + sin(a) * 0.28)
            }
            return [Part(shape: .ellipse(center: Vec2(0, 0), rx: 0.48, ry: 0.48), color: RGB(1, 0.83, 0.15)),
                    Part(shape: .ellipse(center: Vec2(-0.16, -0.12), rx: 0.05, ry: 0.08), color: ink),
                    Part(shape: .ellipse(center: Vec2(0.16, -0.12), rx: 0.05, ry: 0.08), color: ink),
                    Part(shape: .line(smile, width: 0.05), color: ink)]
        case "sun":
            let rays = (0..<12).map { i -> Part in
                let a = Double(i) / 12 * 2 * .pi, w = 0.13
                let tip = Vec2(sin(a) * 0.5, -cos(a) * 0.5)
                let left = Vec2(sin(a - w) * 0.3, -cos(a - w) * 0.3), right = Vec2(sin(a + w) * 0.3, -cos(a + w) * 0.3)
                return Part(shape: .polygon([left, tip, right]), color: RGB(1, 0.55, 0.1))
            }
            return rays + [Part(shape: .ellipse(center: Vec2(0, 0), rx: 0.31, ry: 0.31), color: RGB(1, 0.82, 0.2))]
        case "cloud":
            let white = RGB(0.96, 0.97, 1), shade = RGB(0.72, 0.8, 0.9)
            let puffs: [(Double, Double, Double)] = [(-0.24, 0.06, 0.2), (0.02, -0.1, 0.27), (0.26, 0.06, 0.2)]
            let base = [Vec2(-0.3, 0.06), Vec2(0.3, 0.06), Vec2(0.36, 0.26), Vec2(-0.36, 0.26)]
            // A slightly larger shaded copy behind gives it an edge on light pictures.
            return puffs.map { Part(shape: .ellipse(center: Vec2($0.0, $0.1 + 0.02), rx: $0.2 + 0.025, ry: $0.2 + 0.025), color: shade) }
                + [Part(shape: .polygon(base.map { Vec2($0.x * 1.07, $0.y + 0.02) }), color: shade)]
                + puffs.map { Part(shape: .ellipse(center: Vec2($0.0, $0.1), rx: $0.2, ry: $0.2), color: white) }
                + [Part(shape: .polygon(base), color: white)]
        case "flower":
            let petals = (0..<6).map { i -> Part in
                let a = Double(i) / 6 * 2 * .pi
                let points = (0..<24).map { k -> Vec2 in
                    let u = Double(k) / 24 * 2 * .pi
                    let x = cos(u) * 0.16, y = sin(u) * 0.09 + 0
                    let along = x + 0.27
                    return Vec2(along * cos(a) - y * sin(a), along * sin(a) + y * cos(a))
                }
                return Part(shape: .polygon(points), color: RGB(1, 0.45, 0.7))
            }
            return petals + [Part(shape: .ellipse(center: Vec2(0, 0), rx: 0.13, ry: 0.13), color: RGB(1, 0.8, 0.15))]
        case "crown":
            let gold = RGB(0.95, 0.72, 0.15)
            let body = [Vec2(-0.42, 0.3), Vec2(-0.45, -0.25), Vec2(-0.2, 0.02), Vec2(0, -0.35), Vec2(0.2, 0.02), Vec2(0.45, -0.25),
                        Vec2(0.42, 0.3)]
            return [Part(shape: .polygon(body), color: gold),
                    Part(shape: .polygon([Vec2(-0.42, 0.3), Vec2(0.42, 0.3), Vec2(0.42, 0.4), Vec2(-0.42, 0.4)]), color: RGB(0.8, 0.55, 0.1)),
                    Part(shape: .ellipse(center: Vec2(0, 0.16), rx: 0.06, ry: 0.06), color: RGB(0.85, 0.1, 0.2)),
                    Part(shape: .ellipse(center: Vec2(-0.25, 0.18), rx: 0.045, ry: 0.045), color: RGB(0.15, 0.45, 0.9)),
                    Part(shape: .ellipse(center: Vec2(0.25, 0.18), rx: 0.045, ry: 0.045), color: RGB(0.15, 0.45, 0.9))]
        case "arrow":
            return [Part(shape: .polygon([Vec2(-0.48, -0.1), Vec2(0.1, -0.1), Vec2(0.1, -0.3), Vec2(0.48, 0), Vec2(0.1, 0.3),
                                          Vec2(0.1, 0.1), Vec2(-0.48, 0.1)]), color: RGB(0.15, 0.45, 0.95))]
        case "speech":
            let body = roundedBox(x0: -0.48, y0: -0.4, x1: 0.48, y1: 0.2, radius: 0.15)
            let tail = [Vec2(-0.2, 0.15), Vec2(-0.32, 0.45), Vec2(0.02, 0.15)]
            return [Part(shape: .polygon(body), color: RGB(1, 1, 1)), Part(shape: .polygon(tail), color: RGB(1, 1, 1)),
                    Part(shape: .line(body + [body[0]], width: 0.03), color: ink)]
        default:
            return []
        }
    }

    /// A star of `points` tips (radius `outer`) and dents (radius `inner`), the first tip at the top.
    static func star(points: Int, outer: Double, inner: Double) -> [Vec2] {
        (0..<(2 * points)).map { i in
            let a = Double(i) / Double(2 * points) * 2 * .pi, r = i % 2 == 0 ? outer : inner
            return Vec2(sin(a) * r, -cos(a) * r)
        }
    }

    /// A box with rounded corners as an outline.
    static func roundedBox(x0: Double, y0: Double, x1: Double, y1: Double, radius r: Double) -> [Vec2] {
        let corners: [(Vec2, Double)] = [(Vec2(x1 - r, y0 + r), -90), (Vec2(x1 - r, y1 - r), 0), (Vec2(x0 + r, y1 - r), 90), (Vec2(x0 + r, y0 + r), 180)]
        return corners.flatMap { c, start in
            (0...6).map { k -> Vec2 in
                let a = (start + Double(k) / 6 * 90) * .pi / 180
                return Vec2(c.x + cos(a) * r, c.y + sin(a) * r)
            }
        }
    }

    /// Whether a point is inside an outline (crossings rule), for the tests.
    static func inside(_ p: Vec2, _ polygon: [Vec2]) -> Bool {
        Crop.inside(p, polygon)
    }
}
