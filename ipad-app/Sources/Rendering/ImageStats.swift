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

    /// The picture's pixels in linear light (RGBA floats, row by row), shrunk to about `side` pixels
    /// on its long side (Match Exposures reads its brightness from them).
    static func linearPixels(of image: CIImage, side: CGFloat = 64, context: CIContext) -> [Float] {
        let small = PhotoRenderer.downscaled(image, maxSide: side)
        let e = small.extent
        guard !e.isInfinite, e.width >= 1, e.height >= 1 else { return [] }
        let w = Int(e.width), h = Int(e.height)
        var pixels = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &pixels, rowBytes: w * 16, bounds: CGRect(x: e.minX, y: e.minY, width: CGFloat(w), height: CGFloat(h)),
                       format: .RGBAf, colorSpace: nil)
        return pixels
    }

    /// Share of pixels per level bin for each channel (sRGB levels), darkest first.
    static func channelHistograms(of image: CIImage, extent: CGRect, context: CIContext, bins: Int = 256)
        -> (red: [Double], green: [Double], blue: [Double]) {
        let histogram = image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIAreaHistogram", parameters: [
            "inputExtent": CIVector(cgRect: extent),
            "inputCount": bins,
            "inputScale": 1.0,
        ])
        var pixels = [Float](repeating: 0, count: bins * 4)
        context.render(histogram, toBitmap: &pixels, rowBytes: bins * 16,
                       bounds: CGRect(x: 0, y: 0, width: bins, height: 1), format: .RGBAf, colorSpace: nil)
        func channel(_ k: Int) -> [Double] { stride(from: k, to: pixels.count, by: 4).map { Double(pixels[$0]) } }
        return (channel(0), channel(1), channel(2))
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
