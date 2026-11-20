import CommandEngine
import CoreImage

/// Masks (local adjustments). Each mask's picture is worked out by MaskRaster in CommandEngine on a
/// grid of half the photo's long side (MaskRaster.gridSize) and stretched smoothly over the photo;
/// PhotoRenderer blends the locally edited photo through it. Grids are kept until the mask's shape
/// or the photo changes, so local sliders stay fast.
final class MaskRenderer {
    let context: CIContext
    /// The photo's pixels for colour and brightness ranges: the picture they came from (the
    /// renderer's input), the lens settings, the grid size, and the numbers.
    private var pixels: (source: CIImage, key: [Double], grid: PixelGrid)?
    /// Mask grids made so far, by shape and grid size.
    private var grids: [GridKey: [Float]] = [:]
    /// The picture the grids were made for (they are dropped when it changes).
    private var gridSource: (source: CIImage, key: [Double])?

    struct GridKey: Hashable {
        let shape: MaskShape
        let width: Int
        let height: Int
    }

    init(context: CIContext) {
        self.context = context
    }

    /// The mask as a grey picture over `extent` (white = full local adjustment).
    /// `photo`: the picture after lens corrections (what range masks look at); `source` and
    /// `lensKey` say when it changed.
    func image(of mask: Mask, photo: CIImage, source: CIImage, lensKey: [Double], extent: CGRect) -> CIImage {
        let size = MaskRaster.gridSize(width: Double(extent.width), height: Double(extent.height))
        if let gridSource, gridSource.source !== source || gridSource.key != lensKey {
            grids = [:]
        }
        gridSource = (source, lensKey)
        let key = GridKey(shape: mask.shape, width: size.width, height: size.height)
        let values: [Float]
        if let known = grids[key] {
            values = known
        } else {
            let grid = MaskRaster.needsPixels(mask)
                ? pixelGrid(photo, source: source, lensKey: lensKey, width: size.width, height: size.height) : nil
            values = MaskRaster.render(mask, width: size.width, height: size.height, pixels: grid)
            if grids.count > 24 { grids = [:] }
            grids[key] = values
        }
        return Filters.mask(values, width: size.width, height: size.height, over: extent)
    }

    /// The photo at the grid's size on sRGB levels, read back once per picture.
    private func pixelGrid(_ photo: CIImage, source: CIImage, lensKey: [Double], width: Int, height: Int) -> PixelGrid {
        if let pixels, pixels.source === source, pixels.key == lensKey,
           pixels.grid.width == width, pixels.grid.height == height {
            return pixels.grid
        }
        let extent = photo.extent
        let scaled = photo.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height)))
        var rgba = [Float](repeating: 0, count: width * height * 4)
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            context.render(scaled, toBitmap: &rgba, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: space)
        }
        let grid = PixelGrid(width: width, height: height, rgba: rgba)
        pixels = (source, lensKey, grid)
        return grid
    }

    /// The photo with a red tint where the mask is (the mask overlay).
    static func overlay(_ image: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0.05, blue: 0.05)).cropped(to: extent)
        return Filters.blend(Filters.mix(image, red, 0.55), over: image, mask: mask)
    }
}
