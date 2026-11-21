import CommandEngine
import CoreImage
import UIKit

/// Layers (Layers panel) over the finished picture, the lowest first: each layer's content is made
/// over the whole canvas (transparent around it), faded by its opacity and laid over everything below
/// it. Positions and sizes are shares of the canvas (see Layers.swift), so the preview and the saved
/// photo agree.
final class LayerRenderer {
    let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    /// The layers over `base` (the finished picture). `photos`: the pictures photo layers show (by the
    /// layer's "photo" number).
    func apply(_ base: CIImage, layers: [Layer], photos: [CIImage]) -> CIImage {
        let extent = base.extent
        guard !layers.isEmpty, extent.width > 0, extent.height > 0 else { return base }
        var out = base
        for layer in layers where layer.isVisible && layer.opacity > 0 {
            guard let content = content(of: layer, extent: extent, photos: photos) else { continue }
            out = composite(content, over: out, layer: layer, extent: extent)
        }
        return out.cropped(to: extent)
    }

    /// A transparent picture the size of the canvas.
    static func clear(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
    }

    /// The layer's content over the canvas (premultiplied, transparent where it has none).
    private func content(of layer: Layer, extent: CGRect, photos: [CIImage]) -> CIImage? {
        switch layer.kind {
        case "photo":
            let i = Int(layer.value("photo", -1))
            guard photos.indices.contains(i) else { return nil }
            return place(photos[i], side: Layers.photoSide, layer: layer, extent: extent)
        default:
            return nil
        }
    }

    /// A picture as a layer's content: its long side `side` L units at Layer Scale 100, centred on the
    /// layer and turned with it.
    func place(_ picture: CIImage, side: Double, layer: Layer, extent: CGRect) -> CIImage {
        let from = picture.extent
        guard from.width > 0, from.height > 0 else { return Self.clear(extent) }
        let t = layer.transform
        let long = Double(max(extent.width, extent.height))
        // Smooth downscaling first (Lanczos), then the turn and the move.
        var image = picture.transformed(by: CGAffineTransform(translationX: -from.minX, y: -from.minY))
        let k = side * long * t.scale / Double(max(from.width, from.height))
        if k < 0.9 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        }
        let size = image.extent
        let m = t.pictureMap(contentWidth: Double(size.width), contentHeight: Double(size.height), side: side,
                             width: Double(extent.width), height: Double(extent.height))
        let map = CGAffineTransform(a: CGFloat(m[0]), b: CGFloat(m[1]), c: CGFloat(m[2]), d: CGFloat(m[3]),
                                    tx: CGFloat(m[4]) + extent.minX, ty: CGFloat(m[5]) + extent.minY)
        return image.transformed(by: CGAffineTransform(translationX: -size.minX, y: -size.minY).concatenating(map))
            .composited(over: Self.clear(extent)).cropped(to: extent)
    }

    /// The layer's content laid over `base`, faded by its opacity.
    private func composite(_ content: CIImage, over base: CIImage, layer: Layer, extent: CGRect) -> CIImage {
        let faded = layer.opacity < 1 ? Filters.mix(Self.clear(extent), content, layer.opacity) : content
        return faded.composited(over: base).cropped(to: extent)
    }
}
