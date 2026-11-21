import CommandEngine
import CoreImage
import Foundation

/// The Merge panel's merges. The photos are read into float pictures on sRGB levels (at most
/// `maxSide` pixels on the long side, the first photo's shape), merged by CommandEngine (HDRMerge, …)
/// on the CPU, and the result comes back as a picture that becomes the photo being edited.
final class MergeRenderer {
    let context: CIContext
    /// Long side of the pictures merged pixel by pixel (memory and time stay reasonable on an iPad).
    static let maxSide: CGFloat = 3072

    init(context: CIContext) {
        self.context = context
    }

    /// The merged picture of `photos` for a kind of merge ("hdr", …) with the panel's settings
    /// (`value` gives a control's value by id); nil when there are too few photos.
    func merge(_ kind: String, photos: [CIImage], value: (String) -> Double?) -> CIImage? {
        switch kind {
        case "hdr":
            guard photos.count >= 2 else { return nil }
            let size = Self.size(of: photos[0], maxSide: Self.maxSide)
            let brackets = photos.map { floats($0, width: size.width, height: size.height) }
            let output = HDRMerge.Output(rawValue: option(value("hdrOutput"), HDRMerge.outputs)) ?? .fusion
            let merged = HDRMerge.merge(brackets, deghost: Int(value("deghost") ?? 0), output: output)
            return picture(merged, linear: output == .radiance)
        default:
            return nil
        }
    }

    /// The option id a choice's value stands for.
    private func option(_ value: Double?, _ ids: [String]) -> String {
        let i = Int(value ?? 0)
        return ids.indices.contains(i) ? ids[i] : ids[0]
    }

    /// Whole-pixel size of a picture scaled down to at most `maxSide` on the long side.
    static func size(of image: CIImage, maxSide: CGFloat) -> (width: Int, height: Int) {
        let e = image.extent
        let scale = min(1, maxSide / max(e.width, e.height, 1))
        return (max(1, Int((e.width * scale).rounded())), max(1, Int((e.height * scale).rounded())))
    }

    /// A picture as RGB floats on sRGB levels (0…1), stretched smoothly to `width` × `height`.
    func floats(_ image: CIImage, width: Int, height: Int) -> FloatImage {
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let e = image.extent
        let scaled = image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / max(e.width, 1), y: CGFloat(height) / max(e.height, 1))
                .translatedBy(x: -e.minX, y: -e.minY))
            .cropped(to: target)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return FloatImage(width: width, height: height, channels: 3) }
        context.render(scaled, toBitmap: &rgba, rowBytes: width * 16, bounds: target, format: .RGBAf, colorSpace: space)
        var out = FloatImage(width: width, height: height, channels: 3)
        for i in 0..<(width * height) {
            for c in 0..<3 { out.data[3 * i + c] = min(1, max(0, rgba[4 * i + c])) }
        }
        return out
    }

    /// Floats back into a picture at the origin: sRGB levels, or linear light (levels above 1 kept).
    func picture(_ image: FloatImage, linear: Bool = false) -> CIImage {
        let name = linear ? CGColorSpace.extendedLinearSRGB : CGColorSpace.extendedSRGB
        guard image.width > 0, image.height > 0, let space = CGColorSpace(name: name) else { return CIImage.empty() }
        let rgb = image.rgb
        let data = rgb.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: image.width * 16, size: CGSize(width: image.width, height: image.height),
                       format: .RGBAf, colorSpace: space)
    }
}
