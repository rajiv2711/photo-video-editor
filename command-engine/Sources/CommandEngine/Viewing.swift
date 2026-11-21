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

    /// Bar heights 0…1 to draw: each bin over a reference height, the tallest bin but one in a hundred
    /// (so a spike of clipped pixels doesn't flatten the rest; spikes are cut at the top).
    public static func heights(_ bins: [Int]) -> [Double] {
        let sorted = bins.sorted()
        let reference = Double(Swift.max(1, sorted.isEmpty ? 1 : sorted[Swift.min(sorted.count - 1, sorted.count * 99 / 100)]))
        return bins.map { Swift.min(1, Double($0) / reference) }
    }
}
