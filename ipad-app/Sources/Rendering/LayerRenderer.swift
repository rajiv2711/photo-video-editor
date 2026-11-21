import CommandEngine
import CoreImage
import UIKit

/// Layers (Layers panel) over the finished picture, the lowest first: each layer's content is made
/// over the whole canvas (transparent around it), faded by its opacity and laid over everything below
/// it with its blend mode, through its mask if it has one (worked out by MaskRaster, as the Masks
/// panel's, on the canvas), with its styles (drop shadow, outer glow, stroke, bevel) worked out from
/// its shape. An adjustment layer's content is everything below it with its own sliders.
/// Positions and sizes are shares of the canvas (see Layers.swift), so the preview and the saved photo agree.
final class LayerRenderer {
    let context: CIContext
    /// Layer mask grids made so far, by shape and grid size.
    private var maskGrids: [MaskKey: [Float]] = [:]
    /// Text and the other drawn layers.
    private let art = LayerArt()

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
            if layer.kind != "adjustment" { drawn = styled(drawn, layer: layer, extent: extent) }
            out = composite(drawn, over: out, layer: layer, extent: extent)
        }
        return out.cropped(to: extent)
    }

    // MARK: - Watermark

    /// The watermark over the finished picture: its words (white, with a soft shadow so they read on
    /// light and dark parts) or the logo, Watermark Size tall, placed and faded as the panel says.
    func watermark(_ image: CIImage, text: String, logo: CIImage?, value: (String) -> Double?) -> CIImage {
        let extent = image.extent
        let style = Int(value("watermark") ?? 0)
        guard Watermark.styles.indices.contains(style), extent.width > 0 else { return image }
        let long = Double(max(extent.width, extent.height))
        let height = (value("watermarkSize") ?? 4) / 100 * long
        var stamp: CIImage?
        switch Watermark.styles[style] {
        case "text" where !text.isEmpty:
            stamp = art.stamp(text, size: height)
        case "logo":
            if let logo, logo.extent.height > 0 {
                let k = height / Double(logo.extent.height)
                let moved = logo.transformed(by: CGAffineTransform(translationX: -logo.extent.minX, y: -logo.extent.minY))
                stamp = k < 0.9 ? moved.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
                    : moved.transformed(by: CGAffineTransform(scaleX: CGFloat(k), y: CGFloat(k)))
            }
        default:
            break
        }
        guard let stamp, stamp.extent.width > 0 else { return image }
        let i = Int(value("watermarkPosition") ?? 0)
        let position = Watermark.positions.indices.contains(i) ? Watermark.positions[i] : "bottomRight"
        let size = stamp.extent
        let at = Watermark.origin(position, width: Double(size.width), height: Double(size.height),
                                  canvasWidth: Double(extent.width), canvasHeight: Double(extent.height))
        // Core Image's y is up: the stamp's bottom is that far above the picture's bottom.
        let placed = stamp.transformed(by: CGAffineTransform(translationX: extent.minX + CGFloat(at.x) - size.minX,
                                                             y: extent.maxY - CGFloat(at.y) - size.height - size.minY))
            .composited(over: Self.clear(extent)).cropped(to: extent)
        let opacity = min(1, max(0, (value("watermarkOpacity") ?? 50) / 100))
        return Filters.mix(Self.clear(extent), placed, opacity).composited(over: image).cropped(to: extent)
    }

    // MARK: - Layer styles

    /// The layer's styles, made from its shape (its coverage): the content bevelled, with a stroke
    /// around it, a glow and a shadow beneath. Sizes are shares of the canvas's long side.
    private func styled(_ content: CIImage, layer: Layer, extent: CGRect) -> CIImage {
        let long = Double(max(extent.width, extent.height))
        var top = content
        if layer.value("bevel", 0) != 0 {
            top = bevelled(top, reach: 0.004 * long, extent: extent)
        }
        let stroke = layer.value("layerStroke", 0) / 1000 * long
        if stroke > 0.3 {
            let ring = Self.tinted(content, Layers.color(layer.value("strokeColor", 1)) ?? RGB(0, 0, 0), extent: extent)
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: min(stroke, 200)])
            top = top.composited(over: ring.cropped(to: extent))
        }
        let shape = top
        if layer.value("outerGlow", 0) != 0 {
            let glow = Filters.blurred(Self.tinted(shape, RGB(1, 0.93, 0.7), extent: extent), radius: 0.012 * long, extent: extent)
            top = top.composited(over: glow.composited(over: glow))
        }
        if layer.value("dropShadow", 0) != 0 {
            // Down and to the right (Core Image's y is up), soft, 60 % black.
            let d = CGFloat(0.012 * long)
            let shadow = Filters.blurred(Self.tinted(shape, RGB(0, 0, 0), extent: extent), radius: 0.006 * long, extent: extent)
                .transformed(by: CGAffineTransform(translationX: d, y: -d))
            top = top.composited(over: Filters.mix(Self.clear(extent), shadow, 0.6))
        }
        return top.cropped(to: extent)
    }

    /// A colour (sRGB levels) where `shape` is, as much as it covers.
    static func tinted(_ shape: CIImage, _ rgb: RGB, extent: CGRect) -> CIImage {
        let color = CIImage(color: CIColor(red: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b))).cropped(to: extent)
        return color.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear(extent),
            kCIInputMaskImageKey: shape,
        ])
    }

    /// Bevel: the content lit from the top-left as if its shape were raised, its edges rounded over
    /// `reach` pixels (the slope of its blurred coverage).
    private func bevelled(_ content: CIImage, reach: Double, extent: CGRect) -> CIImage {
        guard let kernel = Self.bevelKernel else { return content }
        let height = content.clampedToExtent().applyingGaussianBlur(sigma: reach).cropped(to: extent)
        let r = CGFloat(reach) + 2
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -r, dy: -r) },
                            arguments: [height, content, reach, 1.6] as [Any]) ?? content
    }

    /// Lights (towards white) the edges whose coverage rises to the bottom-right, darkens the others;
    /// premultiplied colours, so only the content changes.
    private static let bevelKernel: CIKernel? = CIKernel(source: """
        kernel vec4 bevel(sampler height, sampler image, float reach, float strength) {
            vec2 d = destCoord();
            float a = sample(height, samplerTransform(height, d + vec2(-reach, reach))).a;
            float b = sample(height, samplerTransform(height, d + vec2(reach, -reach))).a;
            vec4 c = sample(image, samplerTransform(image, d));
            float light = clamp((b - a) * strength, -0.6, 0.6);
            vec3 rgb = c.rgb + max(light, 0.0) * (vec3(c.a) - c.rgb);
            return vec4(rgb * (1.0 - max(-light, 0.0)), c.a);
        }
        """)

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
        case "text", "shape", "paint", "fill", "sticker":
            return art.image(of: layer, extent: extent)
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
