import CommandEngine
import CoreImage
import UIKit

/// Layers (Layers panel) over the finished picture, the lowest first: each layer's content is made
/// over the whole canvas (transparent around it), faded by its opacity and laid over everything below
/// it with its blend mode, through its mask if it has one (worked out by MaskRaster, as the Masks
/// panel's, on the canvas). An adjustment layer's content is everything below it with its own sliders.
/// Positions and sizes are shares of the canvas (see Layers.swift), so the preview and the saved photo agree.
final class LayerRenderer {
    let context: CIContext
    /// Layer mask grids made so far, by shape and grid size.
    private var maskGrids: [MaskKey: [Float]] = [:]

    struct MaskKey: Hashable {
        let shape: MaskShape
        let width: Int
        let height: Int
    }

    init(context: CIContext) {
        self.context = context
    }

    /// The layers over `base` (the finished picture). `photos`: the pictures photo layers show (by the
    /// layer's "photo" number); `adjust`: an adjustment layer's sliders on the picture below it.
    func apply(_ base: CIImage, layers: [Layer], photos: [CIImage], adjust: (CIImage, Layer) -> CIImage) -> CIImage {
        let extent = base.extent
        guard !layers.isEmpty, extent.width > 0, extent.height > 0 else { return base }
        var out = base
        for layer in layers where layer.isVisible && layer.opacity > 0 {
            let made: CIImage?
            if layer.kind == "adjustment" {
                made = adjust(out, layer).cropped(to: extent)
            } else {
                made = content(of: layer, extent: extent, photos: photos)
            }
            guard var drawn = made else { continue }
            if let mask = layer.mask, !mask.components.isEmpty {
                drawn = drawn.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: Self.clear(extent),
                    kCIInputMaskImageKey: maskImage(mask, extent: extent),
                ])
            }
            out = composite(drawn, over: out, layer: layer, extent: extent)
        }
        return out.cropped(to: extent)
    }

    /// A layer's mask as a grey picture over the canvas (white = the layer shows).
    private func maskImage(_ mask: Mask, extent: CGRect) -> CIImage {
        let size = MaskRaster.gridSize(width: Double(extent.width), height: Double(extent.height))
        let key = MaskKey(shape: mask.shape, width: size.width, height: size.height)
        let values: [Float]
        if let known = maskGrids[key] {
            values = known
        } else {
            values = MaskRaster.render(mask, width: size.width, height: size.height, pixels: nil)
            if maskGrids.count > 16 { maskGrids = [:] }
            maskGrids[key] = values
        }
        return Filters.mask(values, width: size.width, height: size.height, over: extent)
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

    /// The layer's content laid over `base`, faded by its opacity, with its blend mode. Blend modes
    /// work on sRGB levels as in Photoshop (LayerBlend has the formulas): the layer's colours, made
    /// opaque, are blended with the picture below by Core Image's filter of that mode, and the result
    /// shows through the layer's own coverage and opacity.
    private func composite(_ content: CIImage, over base: CIImage, layer: Layer, extent: CGRect) -> CIImage {
        let faded = layer.opacity < 1 ? Filters.mix(Self.clear(extent), content, layer.opacity) : content
        let mode = LayerBlend.mode(layer.value("layerBlend", 0))
        guard mode != "normal", let filter = Self.blendFilters[mode] else {
            return faded.composited(over: base).cropped(to: extent)
        }
        let top = Filters.encoded(content.applyingFilter("CIUnpremultiply").settingAlphaOne(in: extent))
        let blended = Filters.linear(top.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: Filters.encoded(base)]))
        return blended.cropped(to: extent).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: base,
            kCIInputMaskImageKey: faded,
        ]).cropped(to: extent)
    }

    /// Core Image's filter for each blend mode (the layer is the input, the picture below the background).
    static let blendFilters: [String: String] = [
        "multiply": "CIMultiplyBlendMode", "screen": "CIScreenBlendMode", "overlay": "CIOverlayBlendMode",
        "softLight": "CISoftLightBlendMode", "hardLight": "CIHardLightBlendMode", "darken": "CIDarkenBlendMode",
        "lighten": "CILightenBlendMode", "colorDodge": "CIColorDodgeBlendMode", "colorBurn": "CIColorBurnBlendMode",
        "difference": "CIDifferenceBlendMode", "exclusion": "CIExclusionBlendMode", "hue": "CIHueBlendMode",
        "saturation": "CISaturationBlendMode", "color": "CIColorBlendMode", "luminosity": "CILuminosityBlendMode",
    ]
}
