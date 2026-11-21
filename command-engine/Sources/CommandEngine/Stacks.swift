import Foundation

/// Lines photos of one scene up with the middle one (Align), as focus stacking and stack averaging do.
enum Lineup {
    /// The photos moved onto the middle one (the reference), and which pixels of each are its own (1)
    /// or repeated edge (0). `blur`: a share of the small side both are blurred by while lining up
    /// (photos sharp in different places, or noisy).
    static func aligned(_ photos: [FloatImage], blur: Double = 0) -> (photos: [FloatImage], valid: [[Float]], reference: Int) {
        let ref = photos.count / 2
        let refLuma = photos[ref].luma
        let radius = blur > 0 ? max(1, Int(blur * Double(min(refLuma.width, refLuma.height)))) : 0
        var out = photos
        var valid = [[Float]](repeating: [Float](repeating: 1, count: photos[ref].count), count: photos.count)
        for k in photos.indices where k != ref {
            let shift = Align.translation(reference: refLuma, image: photos[k].luma, blur: radius)
            (out[k], valid[k]) = Align.shifted(photos[k], by: shift)
        }
        return (out, valid, ref)
    }
}

/// Focus stacking: photos focused at different distances become one sharp photo. Each photo's
/// sharpness is measured per pixel (energy of the Laplacian, averaged over a small neighbourhood);
/// every pixel takes the photo sharpest there, and the choices are blended band by band (multi-band
/// blending) so the joins don't show. The photos are lined up first (hand-held slices).
public enum FocusStack {
    /// The sharp picture of `slices` (RGB on sRGB levels, one size).
    public static func merge(_ slices: [FloatImage]) -> FloatImage {
        guard let first = slices.first else { return FloatImage(width: 0, height: 0, channels: 3) }
        guard slices.count > 1 else { return first }
        // Blurred alike while lining up (1.5 % of the small side), so their sharpness doesn't matter.
        let (photos, valid, _) = Lineup.aligned(slices, blur: 0.015)
        let w = first.width, h = first.height
        let measures = photos.indices.map { k in zip(sharpness(photos[k]), valid[k]).map { $0 * $1 } }
        // Each pixel: the sharpest photo.
        var masks = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: photos.count)
        for i in 0..<(w * h) {
            var best = 0
            for k in 1..<photos.count where measures[k][i] > measures[best][i] { best = k }
            masks[best][i] = 1
        }
        var out = Pyramid.blend(photos, weights: masks)
        for i in out.data.indices { out.data[i] = min(1, max(0, out.data[i])) }
        return out
    }

    /// How sharp each pixel is: |Laplacian| of the (slightly blurred) brightness, squared, averaged
    /// over about 1 % of the picture's small side.
    public static func sharpness(_ image: FloatImage) -> [Float] {
        let w = image.width, h = image.height
        let grey = Grid.blur(image.luma.data, width: w, height: h, radius: 1)
        let lap = Grid.laplacian(grey, width: w, height: h).map { $0 * $0 }
        return Grid.blur(lap, width: w, height: h, radius: max(2, min(w, h) / 100))
    }
}

/// Stack averaging: a burst of photos of one scene, lined up and combined pixel by pixel. Median keeps
/// what most photos agree on (people walking through, passing cars disappear); Mean averages
/// everything (noise falls by √n; moving things smear like a long exposure).
public enum Stack {
    public enum Mode: String {
        case median, mean
    }

    /// "stackMode" option ids, in order; must match controls.json (and the Stack Average action's options).
    public static let modes = ["median", "mean"]

    /// The combined picture of `photos` (RGB, one size). `align`: line them up with the middle one first.
    public static func merge(_ photos: [FloatImage], mode: Mode, align: Bool = true) -> FloatImage {
        guard let first = photos.first else { return FloatImage(width: 0, height: 0, channels: 3) }
        guard photos.count > 1 else { return first }
        // (A light blur while lining up keeps noise out of it.)
        let lined: (photos: [FloatImage], valid: [[Float]], reference: Int) =
            align ? Lineup.aligned(photos, blur: 0.004) : (photos, [[Float]](repeating: [], count: photos.count), 0)
        let n = photos.count, count = first.count, channels = first.channels
        var out = first
        var values = [Float](repeating: 0, count: n)
        for i in 0..<count {
            for c in 0..<channels {
                var m = 0
                for k in 0..<n where lined.valid[k].isEmpty || lined.valid[k][i] > 0 {
                    values[m] = lined.photos[k].data[i * channels + c]
                    m += 1
                }
                if m == 0 { continue }
                switch mode {
                case .mean:
                    var sum: Float = 0
                    for j in 0..<m { sum += values[j] }
                    out.data[i * channels + c] = sum / Float(m)
                case .median:
                    let sorted = values[0..<m].sorted()
                    out.data[i * channels + c] = m % 2 == 1 ? sorted[m / 2] : (sorted[m / 2 - 1] + sorted[m / 2]) / 2
                }
            }
        }
        return out
    }
}
