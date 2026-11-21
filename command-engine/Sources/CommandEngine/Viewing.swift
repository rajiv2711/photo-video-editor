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
