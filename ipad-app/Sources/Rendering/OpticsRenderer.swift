import CommandEngine
import CoreImage

/// The Optics panel. It runs first, on the photo as shot (as in Lightroom, lens fixes come before any
/// tone or colour work): lens profile correction. The geometry is LensWarp in CommandEngine, a CPU
/// pass on a float copy of the picture; its result is kept until the picture or the optics settings
/// change, so the other sliders stay fast.
final class OpticsRenderer {
    let context: CIContext
    /// The photo's lens (EXIF); setting it looks up its profile.
    var lens = PhotoLens() {
        didSet {
            profile = LensProfile.correction(for: lens)
            cache = nil
        }
    }
    /// The bundled profile found for `lens`, and its correction at the photo's focal length and aperture.
    private(set) var profile: (profile: LensProfile, correction: LensCorrection)?
    /// The last warped picture: its source, the settings, the result.
    private var cache: (source: CIImage, warp: LensWarp, output: CIImage)?

    init(context: CIContext) {
        self.context = context
    }

    func apply(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        func v(_ id: String) -> Double { value(id) ?? 0 }
        var warp = LensWarp()
        if v("lensProfile") != 0 {
            warp.profile = profile?.correction
        }
        return warp.isIdentity ? image : warped(image, warp)
    }

    /// The picture through LensWarp: rendered to 32-bit floats (linear light), remapped, wrapped again.
    private func warped(_ image: CIImage, _ warp: LensWarp) -> CIImage {
        if let cache, cache.source === image, cache.warp == warp {
            return cache.output
        }
        let extent = image.extent
        let width = Int(extent.width.rounded(.up)), height = Int(extent.height.rounded(.up))
        guard width > 1, height > 1, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return image }
        let bounds = CGRect(x: extent.minX, y: extent.minY, width: CGFloat(width), height: CGFloat(height))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(image.clampedToExtent(), toBitmap: &pixels, rowBytes: width * 16, bounds: bounds,
                       format: .RGBAf, colorSpace: space)
        let corrected = warp.apply(pixels, width: width, height: height)
        let data = corrected.withUnsafeBufferPointer { Data(buffer: $0) }
        let output = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                             format: .RGBAf, colorSpace: space)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        cache = (image, warp, output)
        return output
    }
}
