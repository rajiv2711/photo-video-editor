import CommandEngine
import CoreImage
import UIKit

/// Draws the layers that are made of words and lines (text, …) with Core Graphics into a transparent
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
