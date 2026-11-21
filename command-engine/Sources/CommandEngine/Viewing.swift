import Foundation

// The View panel: how the photo is looked at while editing, never part of the edit or the saved photo
// (before/after, scopes, clipping warnings, samplers, zoom, grids, targeted adjustment, soft proofing).
// The maths lives here so it is tested on Linux; the iPad draws it over the preview.

/// A rectangle in pixels (x, y from the bottom-left as Core Image has them, or from the top-left: the
/// layouts here are the same either way).
public struct ViewRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Before / after: where the photo before its edit and the edited one go.
public enum CompareLayout {
    /// "compare" option ids, in order; must match controls.json.
    public static let modes = ["off", "split", "sideBySide"]

    /// Split: the picture before its edit fitted into the edited one's frame (centred), shown left of
    /// `divider` (x, the middle); the edited one keeps its frame. Side by side: the one before scaled to
    /// the edited one's height on the left, a gap of 2 % of the edited width, then the edited one; `size`
    /// is the whole picture's.
    public static func place(mode: String, before: (width: Double, height: Double), after: (width: Double, height: Double))
        -> (before: ViewRect, after: ViewRect, size: (width: Double, height: Double), divider: Double?) {
        guard before.width > 0, before.height > 0, after.width > 0, after.height > 0 else {
            return (ViewRect(0, 0, after.width, after.height), ViewRect(0, 0, after.width, after.height), after, nil)
        }
        switch mode {
        case "split":
            let k = min(after.width / before.width, after.height / before.height)
            let w = before.width * k, h = before.height * k
            return (ViewRect((after.width - w) / 2, (after.height - h) / 2, w, h), ViewRect(0, 0, after.width, after.height), after,
                    after.width / 2)
        case "sideBySide":
            let k = after.height / before.height
            let w = (before.width * k).rounded()
            let gap = (0.02 * after.width).rounded()
            return (ViewRect(0, 0, w, after.height), ViewRect(w + gap, 0, after.width, after.height),
                    (w + gap + after.width, after.height), nil)
        default:
            return (ViewRect(0, 0, after.width, after.height), ViewRect(0, 0, after.width, after.height), after, nil)
        }
    }
}

/// The scopes (Histogram, …), read from a small copy of the preview as it is shown: sRGB levels,
/// 4 bytes per pixel (red, green, blue, alpha), row by row.
public enum Scopes {
    /// How many pixels have each level (0…255), per channel and for luma (Rec. 709 of the levels).
    public struct Histogram: Equatable {
        public var red: [Int]
        public var green: [Int]
        public var blue: [Int]
        public var luma: [Int]
        /// Pixels counted.
        public var count: Int
    }

    /// The histogram of the opaque pixels.
    public static func histogram(rgba: [UInt8]) -> Histogram {
        var h = Histogram(red: Array(repeating: 0, count: 256), green: Array(repeating: 0, count: 256),
                          blue: Array(repeating: 0, count: 256), luma: Array(repeating: 0, count: 256), count: 0)
        var i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] >= 128 {
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                h.red[r] += 1
                h.green[g] += 1
                h.blue[b] += 1
                h.luma[Swift.min(255, (2126 * r + 7152 * g + 722 * b + 5000) / 10000)] += 1
                h.count += 1
            }
            i += 4
        }
        return h
    }

    /// Clipping warnings: a pixel whose brightest channel is at white (254 or 255 of 255) has lost
    /// highlight detail (shown red); one with every channel at black (0 or 1) has lost shadow detail
    /// (shown blue). 1 = highlights, -1 = shadows, 0 = neither.
    public static func clipping(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        let top = Swift.max(r, g, b)
        return top >= highlightLevel ? 1 : top <= shadowLevel ? -1 : 0
    }

    /// The levels that count as clipped (of 255), as the iPad's warning overlay uses them.
    public static let highlightLevel: UInt8 = 254
    public static let shadowLevel: UInt8 = 1

    /// The shares (0…1) of opaque pixels with clipped highlights and clipped shadows.
    public static func clippedShares(rgba: [UInt8]) -> (highlights: Double, shadows: Double) {
        var high = 0, low = 0, count = 0
        var i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] >= 128 {
                switch clipping(rgba[i], rgba[i + 1], rgba[i + 2]) {
                case 1: high += 1
                case -1: low += 1
                default: break
                }
                count += 1
            }
            i += 4
        }
        guard count > 0 else { return (0, 0) }
        return (Double(high) / Double(count), Double(low) / Double(count))
    }

    /// A colour's place on the vectorscope: its blue and red colour differences (Rec. 709 Cb, Cr of the
    /// sRGB levels, each −0.5…0.5; greys at 0, 0).
    public static func chroma(_ r: Double, _ g: Double, _ b: Double) -> (cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((b - y) / 1.8556, (r - y) / 1.5748)
    }

    /// The skin-tone line: skin of every complexion lies close to this angle (degrees, counterclockwise
    /// from the +Cb axis, as on broadcast vectorscopes).
    public static let skinToneAngle = 123.0

    /// The vectorscope: how many pixels fall in each cell of a `size` × `size` grid over Cb (left to
    /// right) and Cr (bottom to top), −0.5…0.5 each; cells row by row from the top.
    public static func vectorscope(rgba: [UInt8], size: Int = 128) -> [Int] {
        var cells = [Int](repeating: 0, count: size * size)
        var i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] >= 128 {
                let c = chroma(Double(rgba[i]) / 255, Double(rgba[i + 1]) / 255, Double(rgba[i + 2]) / 255)
                let x = Swift.min(size - 1, Swift.max(0, Int((c.cb + 0.5) * Double(size))))
                let y = Swift.min(size - 1, Swift.max(0, Int((0.5 - c.cr) * Double(size))))
                cells[y * size + x] += 1
            }
            i += 4
        }
        return cells
    }

    /// Cell brightness 0…1 to draw: the log of each count over the log of the largest, so faint colours show.
    public static func intensities(_ cells: [Int]) -> [Double] {
        let top = log(1 + Double(cells.max() ?? 0))
        guard top > 0 else { return cells.map { _ in 0 } }
        return cells.map { log(1 + Double($0)) / top }
    }

    /// Colour sampler: a colour on sRGB levels (0…1) as the readout shows it: red, green and blue
    /// 0…255, and CIE L*a*b* (D65; L 0…100).
    public static func readout(_ r: Double, _ g: Double, _ b: Double) -> (rgb: [Int], lab: [Double]) {
        func level(_ v: Double) -> Int { Int((Swift.min(1, Swift.max(0, v)) * 255).rounded()) }
        let lab = MaskRaster.lab(Float(Swift.min(1, Swift.max(0, r))), Float(Swift.min(1, Swift.max(0, g))), Float(Swift.min(1, Swift.max(0, b))))
        return ([level(r), level(g), level(b)], [Double(lab.l), Double(lab.a), Double(lab.b)])
    }

    /// At most this many colour samplers at once (the oldest goes).
    public static let maxSamplers = 4

    /// Bar heights 0…1 to draw: each bin over a reference height, the tallest bin but one in a hundred
    /// (so a spike of clipped pixels doesn't flatten the rest; spikes are cut at the top).
    public static func heights(_ bins: [Int]) -> [Double] {
        let sorted = bins.sorted()
        let reference = Double(Swift.max(1, sorted.isEmpty ? 1 : sorted[Swift.min(sorted.count - 1, sorted.count * 99 / 100)]))
        return bins.map { Swift.min(1, Double($0) / reference) }
    }
}

/// Zoom and pan: how big the photo is shown and which part of it.
public enum Viewport {
    /// The Zoom choice's levels, in % of the photo's own pixels (100 = 1:1, each pixel of the photo on
    /// one of the screen); 0 = fit the whole photo. Must match controls.json's option order.
    public static let levels: [Double] = [0, 25, 50, 100, 200, 400, 800]

    /// How many times larger than "fit" the photo shows at `percent` of its own pixels, when it is
    /// `full` pixels long and fits the screen at `fit` pixels; never smaller than fit.
    public static func magnification(percent: Double, full: Double, fit: Double) -> Double {
        guard percent > 0, full > 0, fit > 0 else { return 1 }
        return Swift.max(1, percent / 100 * full / fit)
    }

    /// The percent at which the photo just fits.
    public static func fitPercent(full: Double, fit: Double) -> Double {
        full > 0 ? fit / full * 100 : 100
    }

    /// The first level above fit ("zoom in" from fit goes there): its index in `levels`.
    public static func firstLevel(above fitPercent: Double) -> Int {
        levels.indices.first { levels[$0] > fitPercent + 0.5 } ?? levels.count - 1
    }

    /// The part of the photo shown (shares of its width and height, from the top-left) at a
    /// magnification, around `center`, which is moved in so the view stays inside the photo.
    public static func visible(magnification: Double, center: (x: Double, y: Double)) -> ViewRect {
        let size = 1 / Swift.max(1, magnification)
        func place(_ c: Double) -> Double { Swift.min(1 - size / 2, Swift.max(size / 2, c)) - size / 2 }
        return ViewRect(place(center.x), place(center.y), size, size)
    }
}

/// Grid & guides over the photo (View panel): composition lines, shares of the picture from the top-left.
public enum Guides {
    /// "gridOverlay" option ids, in order; must match controls.json.
    public static let kinds = ["off", "thirds", "goldenRatio", "grid", "diagonals", "center"]

    /// A line from one point to another.
    public typealias Line = (from: MaskPoint, to: MaskPoint)

    /// The lines of a guide on a `width` × `height` picture: thirds (1/3, 2/3 each way), the golden
    /// ratio (0.382, 0.618), a grid of square cells (8 along the long side), corner-to-corner diagonals,
    /// or a cross through the middle.
    public static func lines(_ kind: String, width: Double, height: Double) -> [Line] {
        func vertical(_ x: Double) -> Line { (MaskPoint(x, 0), MaskPoint(x, 1)) }
        func horizontal(_ y: Double) -> Line { (MaskPoint(0, y), MaskPoint(1, y)) }
        switch kind {
        case "thirds":
            return [vertical(1.0 / 3), vertical(2.0 / 3), horizontal(1.0 / 3), horizontal(2.0 / 3)]
        case "goldenRatio":
            let a = 1 - 1 / 1.618033988749895
            return [vertical(a), vertical(1 - a), horizontal(a), horizontal(1 - a)]
        case "grid":
            guard width > 0, height > 0 else { return [] }
            let cell = Swift.max(width, height) / 8
            let across = Swift.max(1, Int((width / cell).rounded())), down = Swift.max(1, Int((height / cell).rounded()))
            return (1..<across).map { vertical(Double($0) / Double(across)) } + (1..<down).map { horizontal(Double($0) / Double(down)) }
        case "diagonals":
            return [(MaskPoint(0, 0), MaskPoint(1, 1)), (MaskPoint(1, 0), MaskPoint(0, 1))]
        case "center":
            return [vertical(0.5), horizontal(0.5)]
        default:
            return []
        }
    }
}
