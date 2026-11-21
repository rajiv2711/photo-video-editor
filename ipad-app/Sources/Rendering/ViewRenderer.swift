import CommandEngine
import CoreImage
import UIKit

/// The View panel's overlays on the preview (never on the saved photo): before / after, and the
/// warnings, grids and markers drawn over it. Positions come from CommandEngine (Viewing.swift).
final class ViewRenderer {
    let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    /// `edited`: the edited preview; `before`: the photo before its edit; `value`: the controls by id.
    func apply(_ edited: CIImage, before: CIImage, value: (String) -> Double?) -> CIImage {
        let after = Self.atOrigin(edited)
        if (value("showBefore") ?? 0) != 0 { return Self.atOrigin(before) }
        let i = Int(value("compare") ?? 0)
        let mode = CompareLayout.modes.indices.contains(i) ? CompareLayout.modes[i] : "off"
        guard mode != "off" else { return after }
        return compare(after, before: Self.atOrigin(before), mode: mode)
    }

    /// Split (before on the left of the middle, edited on the right) or side by side.
    private func compare(_ after: CIImage, before: CIImage, mode: String) -> CIImage {
        let a = after.extent, b = before.extent
        let place = CompareLayout.place(mode: mode, before: (Double(b.width), Double(b.height)), after: (Double(a.width), Double(a.height)))
        let backdrop = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02))
        let k = CGFloat(place.before.width) / b.width
        let placedBefore = before.transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: CGFloat(place.before.x), y: CGFloat(place.before.y)))
        if let divider = place.divider.map({ CGFloat($0) }) {
            let left = CGRect(x: 0, y: 0, width: divider, height: a.height)
            let line = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: divider - 1, y: 0, width: 2, height: a.height))
            return line.composited(over: placedBefore.composited(over: backdrop).cropped(to: left).composited(over: after)).cropped(to: a)
        }
        let whole = CGRect(x: 0, y: 0, width: CGFloat(place.size.width), height: CGFloat(place.size.height))
        let placedAfter = after.transformed(by: CGAffineTransform(translationX: CGFloat(place.after.x), y: CGFloat(place.after.y)))
        return placedAfter.composited(over: placedBefore).composited(over: backdrop).cropped(to: whole)
    }

    /// The picture moved so its frame starts at 0, 0.
    static func atOrigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard !e.isInfinite, e.minX != 0 || e.minY != 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }
}
