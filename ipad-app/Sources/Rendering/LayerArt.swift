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
