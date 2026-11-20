import CommandEngine
import CoreImage

/// Measurements of a picture, read back from the GPU (Equalize, Auto and white balance use them).
enum ImageStats {
    /// Average colour of an area (the whole picture by default), in linear light.
    static func averageColor(of image: CIImage, in area: CGRect? = nil, context: CIContext) -> RGB {
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: area ?? image.extent),
        ])
        guard let output = filter?.outputImage else { return RGB(0, 0, 0) }
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return RGB(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    /// Average and spread of each channel on sRGB levels (Match color).
    static func levelStats(of image: CIImage, extent: CGRect, context: CIContext) -> MatchColor.Stats {
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        let squared = encoded.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: encoded])
        return MatchColor.Stats(mean: averageColor(of: encoded, in: extent, context: context),
                                meanOfSquares: averageColor(of: squared, in: extent, context: context))
    }

    /// Average of (brightest − darkest channel) per pixel on sRGB levels: 0 for a grey picture.
    static func meanChroma(of image: CIImage, context: CIContext) -> Double {
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        let chroma = encoded.applyingFilter("CIMinimumComponent").applyingFilter("CISubtractBlendMode", parameters: [
            kCIInputBackgroundImageKey: encoded.applyingFilter("CIMaximumComponent"),
        ])
        return averageColor(of: chroma, in: image.extent, context: context).r
    }

    /// Share of pixels per brightness bin (Rec. 709 luma of sRGB-encoded levels), darkest first.
    static func lumaHistogram(of image: CIImage, extent: CGRect, context: CIContext, bins: Int = 256) -> [Double] {
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let luma = encoded.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": weights,
            "inputGVector": weights,
            "inputBVector": weights,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        let histogram = luma.applyingFilter("CIAreaHistogram", parameters: [
            "inputExtent": CIVector(cgRect: extent),
            "inputCount": bins,
            "inputScale": 1.0,
        ])
        var pixels = [Float](repeating: 0, count: bins * 4)
        context.render(histogram, toBitmap: &pixels, rowBytes: bins * 16,
                       bounds: CGRect(x: 0, y: 0, width: bins, height: 1), format: .RGBAf, colorSpace: nil)
        return stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0]) }
    }
}
