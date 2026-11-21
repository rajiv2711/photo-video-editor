import CommandEngine
import CoreImage
import UIKit

/// Draws the layers that are made of words and lines (text, shapes, …) with Core Graphics into a transparent
/// picture the canvas's size, placed, scaled and turned as the layer says (see Layers.swift). Pictures
/// are kept until the layer's look or the canvas size changes, so moving a slider elsewhere is quick.
final class LayerArt {
    /// Pictures drawn so far, by what decides them.
    private var drawn: [Key: CIImage] = [:]

    struct Key: Hashable {
        let layer: Layer
        let width: Int
        let height: Int
    }

    /// The layer drawn over `extent` (nil when it has nothing to draw).
    func image(of layer: Layer, extent: CGRect) -> CIImage? {
        let width = max(1, Int(extent.width.rounded())), height = max(1, Int(extent.height.rounded()))
        // Only what changes the drawing counts (opacity, blend and mask are applied afterwards).
        var look = layer
        for id in ["layerOpacity", "layerBlend", "layerVisible"] { look.values[id] = nil }
        look.mask = nil
        let key = Key(layer: look, width: width, height: height)
        if let known = drawn[key] {
            return known.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let size = CGSize(width: width, height: height)
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
            Self.draw(layer, in: context.cgContext, width: Double(width), height: Double(height))
        }
        guard let cg = picture.cgImage else { return nil }
        // Stretched to the canvas exactly (its size may not be whole pixels).
        let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                                                            y: extent.height / CGFloat(height)))
        if drawn.count > 24 { drawn = [:] }
        drawn[key] = image
        return image.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// Draws a layer into a context whose y points down (UIKit's), `width` × `height` pixels.
    static func draw(_ layer: Layer, in context: CGContext, width: Double, height: Double) {
        if layer.kind == "fill" {
            drawFill(layer, in: context, width: width, height: height)
            return
        }
        let t = layer.transform
        context.saveGState()
        defer { context.restoreGState() }
        // The layer's centre, turn and scale; content is then drawn in pixels of the canvas's long side.
        context.translateBy(x: CGFloat(t.x * width), y: CGFloat(t.y * height))
        context.rotate(by: CGFloat(t.angle * .pi / 180))
        context.scaleBy(x: CGFloat(t.scale), y: CGFloat(t.scale))
        let long = max(width, height)
        switch layer.kind {
        case "text":
            drawText(layer, in: context, long: long)
        case "shape":
            drawShape(layer, in: context, long: long)
        case "paint":
            drawPaint(layer, in: context, long: long)
        case "sticker":
            drawSticker(layer, in: context, long: long)
        default:
            break
        }
    }

    /// The words, centred on the layer, line by line.
    private static func drawText(_ layer: Layer, in context: CGContext, long: Double) {
        let size = CGFloat(Layers.fontSize(layer) * long)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(Int(layer.value("textFont", 0)), size: size),
            .foregroundColor: color(Layers.color(layer.value("textColor", 0)) ?? .white),
            .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: layer.text.isEmpty ? " " : layer.text, attributes: attributes)
        let bounds = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPushContext(context)
        text.draw(with: CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
    }

    /// A rectangle, ellipse, regular polygon or closed pen path filled with Shape Fill (or, with no
    /// fill, outlined in Stroke Colour); a line or open path drawn Line Width wide.
    private static func drawShape(_ layer: Layer, in context: CGContext, long: Double) {
        let size = Layers.shapeSize(layer)
        let w = CGFloat(size.width * long), h = CGFloat(size.height * long)
        let fill = Layers.color(layer.value("shapeFill", 7), none: true)
        let line = CGFloat(layer.value("lineWidth", 1) / 100 * long)
        let path = CGMutablePath()
        var closed = true
        switch layer.shapeType {
        case "ellipse":
            path.addEllipse(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        case "polygon":
            let corners = Layers.polygon(sides: Int(layer.value("polygonSides", 6)), width: Double(w), height: Double(h))
            path.addLines(between: corners.map { CGPoint(x: $0.x, y: $0.y) })
            path.closeSubpath()
        case "line":
            path.move(to: CGPoint(x: -w / 2, y: 0))
            path.addLine(to: CGPoint(x: w / 2, y: 0))
            closed = false
        case "path":
            func p(_ v: Vec2) -> CGPoint { CGPoint(x: v.x * long, y: v.y * long) }
            let pieces = Layers.bezier(layer.path, closed: layer.closed)
            guard let first = pieces.first else {
                // A single point so far: a dot where it is.
                if let node = layer.path.first {
                    path.addEllipse(in: CGRect(x: node.point.x * long - Double(line), y: node.point.y * long - Double(line),
                                               width: 2 * Double(line), height: 2 * Double(line)))
                }
                break
            }
            path.move(to: p(first.0))
            for piece in pieces { path.addCurve(to: p(piece.3), control1: p(piece.1), control2: p(piece.2)) }
            if layer.closed { path.closeSubpath() } else { closed = false }
        default:
            path.addRect(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }
        context.addPath(path)
        if closed, let fill {
            context.setFillColor(color(fill).cgColor)
            context.fillPath()
        } else {
            // No fill: outlined in Stroke Colour.
            context.setStrokeColor(color(fill ?? Layers.color(layer.value("strokeColor", 1)) ?? .white).cgColor)
            context.setLineWidth(line)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }

    /// A fill over the whole canvas: one colour, or a gradient from Fill Colour to Fill End Colour (or
    /// to transparent), blended on sRGB levels as Photoshop's are.
    private static func drawFill(_ layer: Layer, in context: CGContext, width: Double, height: Double) {
        let start = Layers.color(layer.value("fillColor", 1)) ?? RGB(0, 0, 0)
        let i = Int(layer.value("fillStyle", 0))
        let style = Layers.fillStyles.indices.contains(i) ? Layers.fillStyles[i] : "solid"
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        guard style != "solid" else {
            context.setFillColor(color(start).cgColor)
            context.fill(all)
            return
        }
        let end = Layers.color(layer.value("fillEndColor", 0), none: true)
        let colors = [color(start).cgColor, end.map { color($0).cgColor } ?? color(start).withAlphaComponent(0).cgColor] as CFArray
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
        let beyond: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if style == "radial" {
            let r = Layers.radialFill(layer, width: width, height: height)
            let c = CGPoint(x: r.centre.x, y: r.centre.y)
            context.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(r.radius), options: beyond)
        } else {
            let ends = Layers.linearFill(layer, width: width, height: height)
            context.drawLinearGradient(gradient, start: CGPoint(x: ends.start.x, y: ends.start.y), end: CGPoint(x: ends.end.x, y: ends.end.y),
                                       options: beyond)
        }
    }

    /// A sticker's parts (Stickers in CommandEngine), Stickers.side of the long side across.
    private static func drawSticker(_ layer: Layer, in context: CGContext, long: Double) {
        let i = Int(layer.value("sticker", 0))
        guard Stickers.ids.indices.contains(i) else { return }
        let k = Stickers.side * long
        func p(_ v: Vec2) -> CGPoint { CGPoint(x: v.x * k, y: v.y * k) }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for part in Stickers.parts(Stickers.ids[i]) {
            let ink = color(part.color).cgColor
            switch part.shape {
            case .polygon(let points):
                context.addLines(between: points.map(p))
                context.closePath()
                context.setFillColor(ink)
                context.fillPath()
            case .ellipse(let c, let rx, let ry):
                context.setFillColor(ink)
                context.fillEllipse(in: CGRect(x: (c.x - rx) * k, y: (c.y - ry) * k, width: 2 * rx * k, height: 2 * ry * k))
            case .line(let points, let width):
                context.addLines(between: points.map(p))
                context.setStrokeColor(ink)
                context.setLineWidth(CGFloat(width * k))
                context.strokePath()
            }
        }
    }

    /// Paint strokes, piece by piece so the width follows the Pencil (round ends join them smoothly).
    private static func drawPaint(_ layer: Layer, in context: CGContext, long: Double) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in layer.strokes {
            let ink = color(Layers.color(stroke.color) ?? RGB(0.89, 0.12, 0.14)).cgColor
            context.setStrokeColor(ink)
            context.setFillColor(ink)
            let points = stroke.points.map { CGPoint(x: $0.x * long, y: $0.y * long) }
            guard points.count > 1 else {
                if let p = points.first {
                    let r = CGFloat(stroke.width(at: 0) * long / 2)
                    context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                }
                continue
            }
            for i in 1..<points.count {
                context.setLineWidth(CGFloat((stroke.width(at: i - 1) + stroke.width(at: i)) / 2 * long))
                context.move(to: points[i - 1])
                context.addLine(to: points[i])
                context.strokePath()
            }
        }
    }

    /// The watermark's words: white, `size` pixels tall, with a soft dark shadow, on a transparent
    /// picture just big enough (kept until the words or the size change).
    func stamp(_ text: String, size: Double) -> CIImage? {
        let key = Key(layer: Layer(kind: "watermark", values: ["size": size.rounded()], text: text), width: 0, height: 0)
        if let known = drawn[key] { return known }
        let shadow = NSShadow()
        shadow.shadowColor = UIColor(white: 0, alpha: 0.6)
        shadow.shadowBlurRadius = CGFloat(size * 0.12)
        shadow.shadowOffset = CGSize(width: 0, height: size * 0.04)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: CGFloat(size), weight: .semibold),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
        ]
        let words = NSAttributedString(string: text, attributes: attributes)
        let bounds = words.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin], context: nil)
        let pad = CGFloat(size * 0.2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let canvas = CGSize(width: ceil(bounds.width + 2 * pad), height: ceil(bounds.height + 2 * pad))
        let picture = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            words.draw(with: CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height), options: [.usesLineFragmentOrigin], context: nil)
        }
        guard let cg = picture.cgImage else { return nil }
        let image = CIImage(cgImage: cg)
        if drawn.count > 24 { drawn = [:] }
        drawn[key] = image
        return image
    }

    /// Text Font's typefaces (Layers.fonts), all on the iPad already.
    static func font(_ index: Int, size: CGFloat) -> UIFont {
        let id = Layers.fonts.indices.contains(index) ? Layers.fonts[index] : "sans"
        let system = UIFont.systemFont(ofSize: size, weight: .bold)
        func design(_ d: UIFontDescriptor.SystemDesign) -> UIFont {
            system.fontDescriptor.withDesign(d).map { UIFont(descriptor: $0, size: size) } ?? system
        }
        switch id {
        case "serif": return design(.serif)
        case "rounded": return design(.rounded)
        case "mono": return design(.monospaced)
        case "script": return UIFont(name: "SnellRoundhand-Bold", size: size) ?? system
        case "display": return UIFont(name: "Futura-CondensedExtraBold", size: size) ?? system
        case "typewriter": return UIFont(name: "AmericanTypewriter-Bold", size: size) ?? system
        case "marker": return UIFont(name: "MarkerFelt-Wide", size: size) ?? system
        default: return system
        }
    }

    /// A colour of the colour choices (sRGB levels).
    static func color(_ rgb: RGB) -> UIColor {
        UIColor(red: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b), alpha: 1)
    }
}
