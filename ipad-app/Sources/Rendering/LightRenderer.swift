import CommandEngine
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Light panel, in Lightroom's order: exposure → contrast → highlights and shadows → one
/// tone-curve pass for the global tone controls (the math is ToneCurve in CommandEngine, so it is
/// tested on Linux).
struct LightRenderer {
    let context: CIContext

    func apply(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        let v = { (id: String) in value(id) ?? 0 }
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

        // Highlights below 0 recover bright areas with Core Image's local highlight/shadow filter
        // (amount 1 = untouched … 0 = strongest). Highlights above 0 brighten through the tone curve.
        let highlightAmount = 1 + min(v("highlights"), 0) / 100
        if highlightAmount != 1 {
            output = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": 0.0,
                "inputRadius": Self.localRadius,
            ])
        }

        output = toneCurve(output, value: value)
        return output
    }

    /// Radius for CIHighlightShadowAdjust's local averaging (its slider range is 0…10).
    static let localRadius = 5.0

    /// One lookup-table pass for every global tone control (see ToneCurve).
    private func toneCurve(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        guard !ToneCurve.isIdentity(value) else { return image }
        let table = ToneCurve.table(value)
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
