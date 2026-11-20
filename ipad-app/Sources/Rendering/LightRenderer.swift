import CommandEngine
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Light panel, in Lightroom's order: exposure → contrast → highlights and shadows (with
/// brilliance) → brilliance's local contrast → one tone-curve pass for the global tone controls →
/// equalize. (The curve math is ToneCurve in CommandEngine, so it is tested on Linux.)
struct LightRenderer {
    let context: CIContext

    /// `hdr`: keep levels above white (the tone curve then runs up to 4× SDR white).
    func apply(_ image: CIImage, value: (String) -> Double?, hdr: Bool) -> CIImage {
        func v(_ id: String) -> Double { value(id) ?? 0 }
        var output = image

        let exposure = v("exposure")  // EV, −3…3
        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(exposure)
            output = filter.outputImage ?? output
        }

        let contrast = v("contrast")  // −100…100 → Core Image 0.5…1.5
        if contrast != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = 0
            filter.saturation = 1
            filter.contrast = Float(1 + contrast / 100 * 0.5)
            output = filter.outputImage ?? output
        }

        // Core Image's local highlight/shadow filter. Highlights below 0 recover bright areas
        // (amount 1 = untouched … 0 = strongest); above 0 they brighten through the tone curve.
        // Shadows lift (up to 1) or deepen (down to −1) the dark areas.
        // Brilliance (Apple Photos) adds a shadow lift and highlight recovery of its own (+), or
        // deepens shadows (−), plus local contrast below.
        let brilliance = v("brilliance") / 100
        let highlightAmount = max(0, 1 + min(v("highlights"), 0) / 100 - 0.4 * max(brilliance, 0))
        let shadowAmount = min(1, max(-1, v("shadows") / 100 + 0.5 * brilliance))
        if highlightAmount != 1 || shadowAmount != 0 {
            output = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": shadowAmount,
                "inputRadius": Self.localRadius,
            ])
        }

        // Brilliance's local contrast: a wide unsharp mask (negative softens it).
        if brilliance != 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = output
            filter.radius = Float(0.02 * max(image.extent.width, image.extent.height))
            filter.intensity = Float(0.4 * brilliance)
            output = filter.outputImage ?? output
        }

        output = toneCurve(output, value: value, maxInput: hdr ? 4 : 1)

        // Equalize: spread the brightness levels evenly, from this picture's own histogram.
        if v("equalize") != 0 {
            let histogram = ImageStats.lumaHistogram(of: output, extent: image.extent, context: context)
            let table = ToneCurve.equalize(histogram: histogram)
            output = Self.curves(output, table: table.flatMap { [Float($0), Float($0), Float($0)] }, maxInput: 1)
        }
        return output
    }

    /// Radius for CIHighlightShadowAdjust's local averaging (its slider range is 0…10).
    static let localRadius = 5.0

    /// One lookup-table pass for every global tone control (see ToneCurve).
    private func toneCurve(_ image: CIImage, value: (String) -> Double?, maxInput: Double) -> CIImage {
        guard !ToneCurve.isIdentity(value) else { return image }
        let table = ToneCurve.table(value, maxInput: maxInput)
        return Self.curves(image, table: table.interleaved, maxInput: table.maxInput)
    }

    /// Applies an interleaved RGB lookup table (0…maxInput, sRGB-encoded levels) with CIColorCurves.
    static func curves(_ image: CIImage, table: [Float], maxInput: Double) -> CIImage {
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB) else { return image }
        let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: CGFloat(maxInput)),
            "inputColorSpace": space,
        ])
    }
}
