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
    /// `samplers`: the colour samplers' points (0…1 from the top-left of the edited picture).
    func apply(_ edited: CIImage, before: CIImage, value: (String) -> Double?, samplers: [MaskPoint] = []) -> CIImage {
        var after = Self.atOrigin(edited)
        if (value("showBefore") ?? 0) != 0 { return Self.atOrigin(before) }
        if (value("clippingWarning") ?? 0) != 0 { after = clippingWarning(after) }
        let g = Int(value("gridOverlay") ?? 0)
        if Guides.kinds.indices.contains(g), g > 0 { after = grid(after, kind: Guides.kinds[g]) }
        if !samplers.isEmpty { after = markers(after, at: samplers) }
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

    /// Clipping warnings (Scopes.clipping): red where the brightest channel is at white, blue where
    /// every channel is at black, on sRGB levels.
    private func clippingWarning(_ image: CIImage) -> CIImage {
        let top = image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIMaximumComponent")
        // 0 half a level short of the limit, 1 at it: a steep ramp, clamped.
        let k = 510.0
        let high = Double(Scopes.highlightLevel) / 255, low = Double(Scopes.shadowLevel) / 255
        let highlights = Filters.affine(top, scale: k, bias: -k * (high - 0.5 / 255)).applyingFilter("CIColorClamp")
        let shadows = Filters.affine(top, scale: -k, bias: k * (low + 0.5 / 255)).applyingFilter("CIColorClamp")
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: image.extent)
        let blue = CIImage(color: CIColor(red: 0, green: 0.2, blue: 1)).cropped(to: image.extent)
        return Filters.blend(blue, over: Filters.blend(red, over: image, mask: highlights), mask: shadows).cropped(to: image.extent)
    }

    /// The grid drawn last (its size and kind) and its picture: lines don't change while editing.
    private var gridCache: (key: String, image: CIImage)?

    /// Grid & guides (Guides.lines): thin white lines with a soft dark edge, so they show on light and dark parts.
    private func grid(_ image: CIImage, kind: String) -> CIImage {
        let size = image.extent.size
        guard size.width >= 1, size.height >= 1 else { return image }
        let key = "\(kind) \(Int(size.width)) \(Int(size.height))"
        if let cached = gridCache, cached.key == key { return cached.image.composited(over: image) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let width = max(1, (max(size.width, size.height) / 800).rounded())
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            for (stroke, color) in [(3 * width, UIColor(white: 0, alpha: 0.45)), (width, UIColor(white: 1, alpha: 0.85))] {
                cg.setLineWidth(stroke)
                cg.setStrokeColor(color.cgColor)
                for line in Guides.lines(kind, width: Double(size.width), height: Double(size.height)) {
                    cg.move(to: CGPoint(x: CGFloat(line.from.x) * size.width, y: CGFloat(line.from.y) * size.height))
                    cg.addLine(to: CGPoint(x: CGFloat(line.to.x) * size.width, y: CGFloat(line.to.y) * size.height))
                }
                cg.strokePath()
            }
        }
        guard let cg = picture.cgImage else { return image }
        let lines = CIImage(cgImage: cg)
        gridCache = (key, lines)
        return lines.composited(over: image)
    }

    /// Colour samplers: a white ring with a dark edge and its number at each point.
    private func markers(_ image: CIImage, at points: [MaskPoint]) -> CIImage {
        let size = image.extent.size
        guard size.width >= 1, size.height >= 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let r = max(4, 0.012 * max(size.width, size.height))
            for (i, p) in points.enumerated() {
                let c = CGPoint(x: CGFloat(p.x) * size.width, y: CGFloat(p.y) * size.height)
                let ring = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                ctx.cgContext.setLineWidth(max(2, r / 3))
                UIColor.black.setStroke()
                ctx.cgContext.strokeEllipse(in: ring.insetBy(dx: -max(1, r / 4), dy: -max(1, r / 4)))
                UIColor.white.setStroke()
                ctx.cgContext.strokeEllipse(in: ring)
                let number = "\(i + 1)" as NSString
                number.draw(at: CGPoint(x: c.x + r + 2, y: c.y - 2.6 * r), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 1.8 * r), .foregroundColor: UIColor.white,
                    .strokeColor: UIColor.black, .strokeWidth: -3,
                ])
            }
        }
        guard let cg = picture.cgImage else { return image }
        return CIImage(cgImage: cg).composited(over: image)
    }

    /// The part `rect` (shares from the top-left) of a picture, enlarged `magnification` times back to
    /// about the picture's size (the render gallery's view of a zoom).
    static func zoomed(_ image: CIImage, to rect: ViewRect, magnification: Double) -> CIImage {
        let e = atOrigin(image).extent
        let area = CGRect(x: CGFloat(rect.x) * e.width, y: CGFloat(1 - rect.y - rect.height) * e.height,
                          width: CGFloat(rect.width) * e.width, height: CGFloat(rect.height) * e.height)
        let k = CGFloat(magnification)
        return atOrigin(image).clampedToExtent().cropped(to: area)
            .transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .cropped(to: CGRect(x: 0, y: 0, width: (area.width * k).rounded(), height: (area.height * k).rounded()))
    }

    /// The picture moved so its frame starts at 0, 0.
    static func atOrigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard !e.isInfinite, e.minX != 0 || e.minY != 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }
}
