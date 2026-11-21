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

    /// Long side of each photo of a panorama, and of the whole panorama at most.
    static let panoramaPhotoSide: CGFloat = 2048
    static let panoramaSide = 8192

    /// A merge's result: the picture and how many photos went into it.
    struct Merged {
        let image: CIImage
        let used: Int
    }

    /// The merged picture of `photos` for a kind of merge ("hdr", "panorama", …) with the panel's
    /// settings (`value` gives a control's value by id); nil when they can't be merged.
    func merge(_ kind: String, photos: [CIImage], value: (String) -> Double?) -> Merged? {
        switch kind {
        case "hdr":
            guard photos.count >= 2 else { return nil }
            let size = Self.size(of: photos[0], maxSide: Self.maxSide)
            let brackets = photos.map { floats($0, width: size.width, height: size.height) }
            let output = HDRMerge.Output(rawValue: option(value("hdrOutput"), HDRMerge.outputs)) ?? .fusion
            let merged = HDRMerge.merge(brackets, deghost: Int(value("deghost") ?? 0), output: output)
            return Merged(image: picture(merged, linear: output == .radiance), used: photos.count)
        case "focus":
            guard photos.count >= 2 else { return nil }
            let size = Self.size(of: photos[0], maxSide: Self.maxSide)
            let slices = photos.map { floats($0, width: size.width, height: size.height) }
            return Merged(image: picture(FocusStack.merge(slices)), used: photos.count)
        case "stack":
            guard photos.count >= 2 else { return nil }
            let size = Self.size(of: photos[0], maxSide: Self.maxSide)
            let burst = photos.map { floats($0, width: size.width, height: size.height) }
            let mode = Stack.Mode(rawValue: option(value("stackMode"), Stack.modes)) ?? .median
            return Merged(image: picture(Stack.merge(burst, mode: mode)), used: photos.count)
        case "double":
            // The first photo's frame; the others fill it (cut to its shape, centred).
            guard photos.count >= 2 else { return nil }
            let size = Self.size(of: photos[0], maxSide: Self.maxSide)
            let layers = photos.enumerated().map { floats($0.element, width: size.width, height: size.height, fill: $0.offset > 0) }
            let mode = DoubleExposure.Mode(rawValue: option(value("blendMode"), DoubleExposure.modes)) ?? .screen
            let merged = DoubleExposure.merge(layers, mode: mode, amount: Float((value("blendAmount") ?? 100) / 100))
            return Merged(image: picture(merged), used: photos.count)
        case "panorama":
            guard photos.count >= 2 else { return nil }
            let pictures = photos.map { photo -> FloatImage in
                let size = Self.size(of: photo, maxSide: Self.panoramaPhotoSide)
                return floats(photo, width: size.width, height: size.height)
            }
            guard let result = Panorama.stitch(pictures, settings: panoramaSettings(value), focal: focal(of: photos[0], picture: pictures[0]),
                                               maxSide: Self.panoramaSide) else { return nil }
            return Merged(image: picture(result.image, alpha: result.coverage), used: result.used)
        case "hdrPanorama":
            // Each position's brackets share the first one's size.
            guard photos.count >= 4 else { return nil }
            var pictures: [FloatImage] = []
            for photo in photos {
                let size = Self.size(of: photo, maxSide: Self.panoramaPhotoSide)
                let first = pictures.first.map { (width: $0.width, height: $0.height) }
                let same = first.map { abs(Double($0.width) / Double($0.height) - Double(size.width) / Double(size.height)) < 0.01 } ?? false
                pictures.append(floats(photo, width: same ? first!.width : size.width, height: same ? first!.height : size.height))
            }
            let output = HDRMerge.Output(rawValue: option(value("hdrOutput"), HDRMerge.outputs)) ?? .fusion
            guard let merged = HDRPanorama.merge(pictures, deghost: Int(value("deghost") ?? 0), output: output,
                                                 settings: panoramaSettings(value), focal: focal(of: photos[0], picture: pictures[0]),
                                                 maxSide: Self.panoramaSide) else { return nil }
            return Merged(image: picture(merged.result.image, linear: merged.linear, alpha: merged.result.coverage), used: merged.result.used)
        default:
            return nil
        }
    }

    /// The Panorama section's settings.
    private func panoramaSettings(_ value: (String) -> Double?) -> Panorama.Settings {
        Panorama.Settings(projection: Panorama.Projection(rawValue: option(value("panoramaProjection"), Panorama.projections)) ?? .spherical,
                          boundaryWarp: (value("boundaryWarp") ?? 0) / 100, fillEdges: (value("fillEdges") ?? 0) != 0)
    }

    /// A photo's focal length in pixels of `picture` (its copy being merged), from the 35 mm
    /// equivalent focal length in its EXIF data (nil when it has none).
    private func focal(of photo: CIImage, picture: FloatImage) -> Double? {
        let exif = photo.properties["{Exif}"] as? [String: Any]
        guard let f35 = (exif?["FocalLenIn35mmFilm"] as? NSNumber)?.doubleValue, f35 > 0 else { return nil }
        // A 35 mm frame's diagonal is 43.27 mm.
        return f35 * hypot(Double(picture.width), Double(picture.height)) / 43.27
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

    /// A picture as RGB floats on sRGB levels (0…1), stretched smoothly to `width` × `height`, or
    /// (`fill`) scaled to cover it and cut to its shape around the middle.
    func floats(_ image: CIImage, width: Int, height: Int, fill: Bool = false) -> FloatImage {
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let e = image.extent
        var sx = CGFloat(width) / max(e.width, 1), sy = CGFloat(height) / max(e.height, 1)
        if fill { sx = max(sx, sy); sy = sx }
        let dx = (CGFloat(width) - e.width * sx) / 2, dy = (CGFloat(height) - e.height * sy) / 2
        let scaled = image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: dx, y: dy).scaledBy(x: sx, y: sy).translatedBy(x: -e.minX, y: -e.minY))
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

    /// Floats back into a picture at the origin: sRGB levels, or linear light (levels above 1 kept);
    /// `alpha` (one number per pixel) makes uncovered parts transparent.
    func picture(_ image: FloatImage, linear: Bool = false, alpha: [Float]? = nil) -> CIImage {
        let name = linear ? CGColorSpace.extendedLinearSRGB : CGColorSpace.extendedSRGB
        guard image.width > 0, image.height > 0, let space = CGColorSpace(name: name) else { return CIImage.empty() }
        var rgba = image.rgb.rgba
        if let alpha, alpha.count == image.width * image.height {
            for i in alpha.indices where alpha[i] < 1 {
                let a = max(0, alpha[i])
                for c in 0..<3 { rgba[4 * i + c] *= a }
                rgba[4 * i + 3] = a
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: image.width * 16, size: CGSize(width: image.width, height: image.height),
                       format: .RGBAf, colorSpace: space)
    }
}
