import CommandEngine
import CoreImage

/// Small Core Image building blocks shared by the Effects, Detail and Optics panels.
/// Every step that looks at neighbouring pixels first repeats the border pixels outwards
/// (`clampedToExtent`) and cuts back to `extent`, so photo edges don't darken or fade.
enum Filters {
    /// Linear light → sRGB-encoded levels, where perceptual effects work.
    static func encoded(_ image: CIImage) -> CIImage {
        image.applyingFilter("CILinearToSRGBToneCurve")
    }

    /// sRGB-encoded levels → linear light (Core Image's working space).
    static func linear(_ image: CIImage) -> CIImage {
        image.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// Gaussian blur of about `radius` pixels.
    static func blurred(_ image: CIImage, radius: Double, extent: CGRect) -> CIImage {
        guard radius > 0 else { return image }
        return image.cropped(to: extent).clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
    }

    /// Unsharp mask: adds `intensity` × (picture − blurred picture) back.
    static func unsharp(_ image: CIImage, radius: Double, intensity: Double, extent: CGRect) -> CIImage {
        guard radius > 0, intensity > 0 else { return image }
        return image.cropped(to: extent).clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: intensity,
        ]).cropped(to: extent)
    }

    /// Straight mix: `amount` 0 gives `a`, 1 gives `b`.
    static func mix(_ a: CIImage, _ b: CIImage, _ amount: Double) -> CIImage {
        a.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: b,
            kCIInputTimeKey: min(1, max(0, amount)),
        ])
    }

    /// `image` where the mask is 1, `background` where it is 0 (the mask's stored levels).
    static func blend(_ image: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// A grey picture of Rec. 709 luma, on whatever levels come in.
    static func luma(_ image: CIImage) -> CIImage {
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": weights,
            "inputGVector": weights,
            "inputBVector": weights,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }

    /// Each colour channel × `scale` + `bias` (alpha untouched).
    static func affine(_ image: CIImage, scale: Double, bias: Double = 0) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0),
            "inputBiasVector": CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 0),
        ])
    }

    /// Each colour channel × its own `scale` + `bias` (alpha untouched).
    static func affine(_ image: CIImage, scale: RGB, bias: RGB) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scale.r), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scale.g), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale.b), w: 0),
            "inputBiasVector": CIVector(x: CGFloat(bias.r), y: CGFloat(bias.g), z: CGFloat(bias.b), w: 0),
        ])
    }

    /// `image` resized to fill `extent` (smooth sampling; borders repeated so they don't fade).
    static func resized(_ image: CIImage, to extent: CGRect) -> CIImage {
        let from = image.extent
        guard from.width > 0, from.height > 0 else { return image }
        let transform = CGAffineTransform(translationX: extent.minX, y: extent.minY)
            .scaledBy(x: extent.width / from.width, y: extent.height / from.height)
            .translatedBy(x: -from.minX, y: -from.minY)
        return image.clampedToExtent().transformed(by: transform).cropped(to: extent)
    }

    /// Each pixel's levels looked up in `table` (output levels for evenly spaced inputs over 0…1,
    /// see Effects in CommandEngine), on the stored numbers with no colour conversion: for masks
    /// and for pictures already on sRGB levels.
    static func lookup(_ image: CIImage, table: [Double]) -> CIImage {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return image }
        let floats = table.flatMap { [Float($0), Float($0), Float($0)] }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": space,
        ])
    }

    /// Grey picture of the local brightness range (brightest − darkest luma within `radius` pixels):
    /// near 0 on flat areas, high on strong edges.
    static func localRange(_ encoded: CIImage, extent: CGRect, radius: Double) -> CIImage {
        luma(encoded).cropped(to: extent).clampedToExtent()
            .applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: max(1, radius)])
            .cropped(to: extent)
    }
}
