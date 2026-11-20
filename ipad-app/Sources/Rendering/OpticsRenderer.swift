import CommandEngine
import CoreImage

/// The Optics panel. It runs first, on the photo as shot (as in Lightroom, lens fixes come before any
/// tone or colour work): lens profile correction, chromatic aberration, manual distortion, lens
/// vignetting, defringe. The geometry is LensWarp in CommandEngine, a CPU pass on a float copy of the
/// picture; its result is kept until the picture or the optics settings change, so the other sliders
/// stay fast. Lens vignetting and defringe are ordinary Core Image passes after it.
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
    /// Remove Chromatic Aberration: the red and blue scales measured on the last picture.
    private var measuredCA: (source: CIImage, red: Double, blue: Double)?
    /// The last defringe colour cube and the settings it was made for.
    private var cachedDefringe: (key: [Double], data: Data)?
    /// The last lens vignetting gain grid and its settings (grid size, amount, midpoint).
    private var cachedVignetting: (key: [Double], values: [Double])?

    init(context: CIContext) {
        self.context = context
    }

    func apply(_ image: CIImage, value: (String) -> Double?) -> CIImage {
        func v(_ id: String) -> Double { value(id) ?? 0 }
        var warp = LensWarp()
        if v("lensProfile") != 0 {
            warp.profile = profile?.correction
        }
        // Chromatic aberration: measured (Remove Chromatic Aberration), then the manual fringe sliders.
        if v("removeCA") != 0 {
            let found = chromaticAberration(of: image)
            warp.redScale = found.red
            warp.blueScale = found.blue
        }
        warp.redScale *= ChromaticAberration.scale(slider: v("caRedCyan"))
        warp.blueScale *= ChromaticAberration.scale(slider: v("caBlueYellow"))
        warp.distortion = v("distortion") / 100
        var output = warp.isIdentity ? image : warped(image, warp)

        // Lens vignetting: corners brighter (or darker) by up to a stop, in linear light.
        let vignetting = v("lensVignetting") / 100
        if vignetting != 0 {
            output = lensVignetting(output, amount: vignetting, midpoint: (value("lensVignettingMidpoint") ?? 50) / 100)
        }

        // Defringe: purple and green fringes along strong edges lose their colour.
        let purple = v("defringePurple") / 100, green = v("defringeGreen") / 100
        if purple > 0 || green > 0 {
            let key = [purple, value("defringePurpleHue") ?? 50, green, value("defringeGreenHue") ?? 50]
            output = defringe(output, key: key)
        }
        return output
    }

    /// The gain grid (Vignette.lensMask in CommandEngine), stretched over the photo and multiplied in.
    private func lensVignetting(_ image: CIImage, amount: Double, midpoint: Double) -> CIImage {
        let extent = image.extent
        let grid = Vignette.gridSize(width: Double(extent.width), height: Double(extent.height))
        let key = [Double(grid.width), Double(grid.height), amount, midpoint]
        let values: [Double]
        if let cachedVignetting, cachedVignetting.key == key {
            values = cachedVignetting.values
        } else {
            values = Vignette.lensMask(width: grid.width, height: grid.height, amount: amount, midpoint: midpoint)
            cachedVignetting = (key, values)
        }
        let gain = Filters.mask(values, width: grid.width, height: grid.height, over: extent)
        return image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain])
    }

    /// The defringe colour cube (Defringe in CommandEngine) on sRGB levels, used near strong edges only.
    private func defringe(_ image: CIImage, key: [Double]) -> CIImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let data: Data
        if let cachedDefringe, cachedDefringe.key == key {
            data = cachedDefringe.data
        } else {
            let cube = Defringe.cube(purple: key[0], purpleHue: Defringe.purpleHue(key[1]),
                                     green: key[2], greenHue: Defringe.greenHue(key[3]), size: ColorRenderer.cubeSize)
            data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
            cachedDefringe = (key, data)
        }
        let extent = image.extent
        let defringed = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": ColorRenderer.cubeSize,
            "inputCubeData": data,
            "inputColorSpace": space,
        ])
        let side = Double(max(extent.width, extent.height))
        let range = Filters.localRange(Filters.encoded(image), extent: extent, radius: Detail.pixels(3, longSide: side))
        return Filters.blend(defringed, over: image, mask: Filters.lookup(range, table: Defringe.edgeMask()))
    }

    /// Red and blue scales that line their edges up with green's, measured on a small copy.
    private func chromaticAberration(of image: CIImage) -> (red: Double, blue: Double) {
        if let measuredCA, measuredCA.source === image {
            return (measuredCA.red, measuredCA.blue)
        }
        let small = Self.floats(PhotoRenderer.downscaled(image, maxSide: 512), context: context)
        let found = ChromaticAberration.estimate(small.pixels, width: small.width, height: small.height)
        measuredCA = (image, found.red, found.blue)
        return found
    }

    private func warped(_ image: CIImage, _ warp: LensWarp) -> CIImage {
        if let cache, cache.source === image, cache.warp == warp {
            return cache.output
        }
        let output = Self.remap(image, warp, context: context)
        cache = (image, warp, output)
        return output
    }

    /// The picture through a LensWarp: rendered to 32-bit floats (linear light), remapped, wrapped again.
    static func remap(_ image: CIImage, _ warp: LensWarp, context: CIContext) -> CIImage {
        let source = floats(image, context: context)
        guard source.width > 1, source.height > 1, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            return image
        }
        let corrected = warp.apply(source.pixels, width: source.width, height: source.height)
        let data = corrected.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: source.width * 16,
                       size: CGSize(width: source.width, height: source.height), format: .RGBAf, colorSpace: space)
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
    }

    /// The picture as RGBA floats in linear light, row by row (edges repeated to whole pixels).
    static func floats(_ image: CIImage, context: CIContext) -> (pixels: [Float], width: Int, height: Int) {
        let extent = image.extent
        let width = Int(extent.width.rounded(.up)), height = Int(extent.height.rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            return ([], 0, 0)
        }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(image.clampedToExtent(), toBitmap: &pixels, rowBytes: width * 16,
                       bounds: CGRect(x: extent.minX, y: extent.minY, width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf, colorSpace: space)
        return (pixels, width, height)
    }
}
