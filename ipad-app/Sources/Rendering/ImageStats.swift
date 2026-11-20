import CoreImage

/// Measurements of a picture, read back from the GPU (Equalize and Auto use them).
enum ImageStats {
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
