import Foundation

// Merging several photos into one (the Merge panel): HDR merge, panorama, focus stacking, stacks,
// double exposure, Live Photo effects. No learning anywhere: the photos are lined up by classical
// image registration (Align.swift), then combined pixel by pixel or band by band (Laplacian
// pyramids, Burt & Adelson 1983). The app reads the photos into FloatImages, calls these, and the
// result becomes the photo being edited; every other panel then works on it as usual.

/// The Merge panel's actions and settings.
public enum MergeTools {
    /// Merge actions and the kind of merge each makes.
    public static let actions: [String: String] = ["hdrMerge": "hdr", "panoramaMerge": "panorama", "hdrPanorama": "hdrPanorama",
                                                   "focusStack": "focus", "stackAverage": "stack", "doubleExposure": "double"]

    /// "Photos to Merge": how many of the last photos picked a merge uses (0 = all of them).
    public static let countID = "mergeCount"

    /// The settings each kind of merge reads: changing one merges again a photo that merge made.
    public static func settings(for kind: String) -> [String] {
        switch kind {
        case "hdr": return [countID, "deghost", "hdrOutput"]
        case "panorama": return [countID, "panoramaProjection", "boundaryWarp", "fillEdges"]
        case "hdrPanorama": return [countID, "deghost", "hdrOutput", "panoramaProjection", "boundaryWarp", "fillEdges"]
        case "stack": return [countID, "stackMode"]
        case "double": return [countID, "blendMode", "blendAmount"]
        default: return [countID]
        }
    }

    /// The choice an action's option sets ("stack median" → Stack Mode).
    public static let optionSetting: [String: String] = ["stackAverage": "stackMode"]

    /// The last `count` photos of `picked` (all of them for 0 or more than there are).
    public static func chosen<T>(_ picked: [T], count: Double) -> [T] {
        let n = Int(count)
        return n > 0 && n < picked.count ? Array(picked.suffix(n)) : picked
    }
}

/// A picture as floats, `channels` numbers per pixel (1 = grey, 3 = RGB), row by row from the top.
public struct FloatImage: Equatable {
    public var width: Int
    public var height: Int
    public var channels: Int
    public var data: [Float]

    public init(width: Int, height: Int, channels: Int, data: [Float]) {
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data
    }

    public init(width: Int, height: Int, channels: Int, value: Float = 0) {
        self.init(width: width, height: height, channels: channels, data: [Float](repeating: value, count: width * height * channels))
    }

    /// An RGB picture from a buffer (same layout).
    public init(_ rgb: RGBBuffer) {
        self.init(width: rgb.width, height: rgb.height, channels: 3, data: rgb.pixels)
    }

    /// As an RGB buffer (grey pictures repeat their one channel).
    public var rgb: RGBBuffer {
        if channels == 3 { return RGBBuffer(width: width, height: height, pixels: data) }
        var pixels = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            let v = data[i * channels]
            pixels[3 * i] = v
            pixels[3 * i + 1] = v
            pixels[3 * i + 2] = v
        }
        return RGBBuffer(width: width, height: height, pixels: pixels)
    }

    public var count: Int { width * height }

    /// The number of channel `c` at a pixel.
    public subscript(x: Int, y: Int, c: Int) -> Float {
        get { data[(y * width + x) * channels + c] }
        set { data[(y * width + x) * channels + c] = newValue }
    }

    /// Rec. 709 luma as a one-channel picture (grey pictures come back as they are).
    public var luma: FloatImage {
        guard channels == 3 else { return self }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBufferPointer { d in
            for i in 0..<count { out[i] = 0.2126 * d[3 * i] + 0.7152 * d[3 * i + 1] + 0.0722 * d[3 * i + 2] }
        }
        return FloatImage(width: width, height: height, channels: 1, data: out)
    }

    /// Every number through `f`.
    public func map(_ f: (Float) -> Float) -> FloatImage {
        FloatImage(width: width, height: height, channels: channels, data: data.map(f))
    }

    /// Mean of all numbers.
    public var mean: Float {
        data.isEmpty ? 0 : Float(data.reduce(0.0) { $0 + Double($1) } / Double(data.count))
    }
}

/// sRGB levels ↔ linear light.
public enum SRGB {
    public static func linear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((max(v, 0) + 0.055) / 1.055, 2.4)
    }

    public static func encoded(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1 / 2.4) - 0.055
    }
}

/// Gaussian and Laplacian pyramids (5-tap binomial filter, as Burt & Adelson): each level half the
/// size of the one below. Blending pictures band by band through them hides seams without blurring
/// the detail (exposure fusion, focus stacking, panorama seams).
public enum Pyramid {
    static let kernel: [Float] = [1 / 16, 4 / 16, 6 / 16, 4 / 16, 1 / 16]

    /// How many levels a picture of this size gets (until the small side is under 8 pixels, at most `cap`).
    public static func levels(width: Int, height: Int, cap: Int = 8) -> Int {
        var n = 1, w = width, h = height
        while n < cap, min(w, h) >= 16 {
            w = (w + 1) / 2
            h = (h + 1) / 2
            n += 1
        }
        return n
    }

    /// Blurred and halved (odd sizes round up).
    public static func reduce(_ image: FloatImage) -> FloatImage {
        let w = image.width, h = image.height, c = image.channels
        let w2 = (w + 1) / 2, h2 = (h + 1) / 2
        var across = [Float](repeating: 0, count: w2 * h * c)
        image.data.withUnsafeBufferPointer { src in
            across.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x2 in 0..<w2 {
                        for k in 0..<5 {
                            let x = min(max(2 * x2 + k - 2, 0), w - 1)
                            let weight = kernel[k]
                            for ch in 0..<c { dst[(y * w2 + x2) * c + ch] += weight * src[(y * w + x) * c + ch] }
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w2 * h2 * c)
        across.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y2 in 0..<h2 {
                    for k in 0..<5 {
                        let y = min(max(2 * y2 + k - 2, 0), h - 1)
                        let weight = kernel[k]
                        let from = y * w2 * c, to = y2 * w2 * c
                        for i in 0..<(w2 * c) { dst[to + i] += weight * src[from + i] }
                    }
                }
            }
        }
        return FloatImage(width: w2, height: h2, channels: c, data: out)
    }

    /// For one output position along a side of `size` made from `small` coarse samples: the coarse
    /// samples it reads and their weights (the binomial filter over the doubled grid, normalized).
    private static func taps(size: Int, small: Int) -> [[(Int, Float)]] {
        (0..<size).map { x in
            var list: [(Int, Float)] = []
            var total: Float = 0
            for k in 0..<5 {
                let z = x + k - 2
                guard z >= 0, z % 2 == 0, z / 2 < small else { continue }
                list.append((z / 2, kernel[k]))
                total += kernel[k]
            }
            if list.isEmpty { list = [(min(x / 2, small - 1), 1)]; total = 1 }
            return list.map { ($0.0, $0.1 / total) }
        }
    }

    /// Enlarged to `width` × `height` (smoothly, the inverse of `reduce`).
    public static func expand(_ image: FloatImage, width: Int, height: Int) -> FloatImage {
        let w = image.width, h = image.height, c = image.channels
        let xs = taps(size: width, small: w), ys = taps(size: height, small: h)
        var across = [Float](repeating: 0, count: width * h * c)
        image.data.withUnsafeBufferPointer { src in
            across.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x in 0..<width {
                        for (sx, weight) in xs[x] {
                            for ch in 0..<c { dst[(y * width + x) * c + ch] += weight * src[(y * w + sx) * c + ch] }
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: width * height * c)
        across.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for (sy, weight) in ys[y] {
                        let from = sy * width * c, to = y * width * c
                        for i in 0..<(width * c) { dst[to + i] += weight * src[from + i] }
                    }
                }
            }
        }
        return FloatImage(width: width, height: height, channels: c, data: out)
    }

    /// The picture and its ever smaller blurred copies (`levels` in all).
    public static func gaussian(_ image: FloatImage, levels: Int) -> [FloatImage] {
        var out = [image]
        while out.count < levels { out.append(reduce(out[out.count - 1])) }
        return out
    }

    /// Band-pass levels (each Gaussian level minus the next one enlarged), the last one the smallest blur.
    public static func laplacian(_ image: FloatImage, levels: Int) -> [FloatImage] {
        let g = gaussian(image, levels: levels)
        var out: [FloatImage] = []
        for i in 0..<(g.count - 1) {
            let up = expand(g[i + 1], width: g[i].width, height: g[i].height)
            out.append(subtract(g[i], up))
        }
        out.append(g[g.count - 1])
        return out
    }

    /// The picture back from its Laplacian levels.
    public static func collapse(_ levels: [FloatImage]) -> FloatImage {
        guard var current = levels.last else { return FloatImage(width: 0, height: 0, channels: 1) }
        for i in stride(from: levels.count - 2, through: 0, by: -1) {
            current = add(levels[i], expand(current, width: levels[i].width, height: levels[i].height))
        }
        return current
    }

    static func subtract(_ a: FloatImage, _ b: FloatImage) -> FloatImage {
        var out = a
        for i in out.data.indices { out.data[i] -= b.data[i] }
        return out
    }

    static func add(_ a: FloatImage, _ b: FloatImage) -> FloatImage {
        var out = a
        for i in out.data.indices { out.data[i] += b.data[i] }
        return out
    }

    /// Blends pictures through per-pixel weights band by band: each picture's Laplacian levels times
    /// its weights' Gaussian levels, summed and divided by the summed weights. Pictures are taken one
    /// at a time, so only one pyramid of each kind is held at once.
    public static func blend(_ images: [FloatImage], weights: [[Float]], levels: Int? = nil) -> FloatImage {
        guard let first = images.first else { return FloatImage(width: 0, height: 0, channels: 3) }
        var sum = Accumulator(width: first.width, height: first.height, channels: first.channels,
                              levels: levels ?? Pyramid.levels(width: first.width, height: first.height))
        for (image, weight) in zip(images, weights) { sum.add(image, weight: weight) }
        return sum.result()
    }

    /// Band-by-band blending, one picture at a time (multi-band blending, Burt & Adelson 1983).
    public struct Accumulator {
        let levels: Int
        var bands: [FloatImage] = []
        var weights: [FloatImage] = []

        public init(width: Int, height: Int, channels: Int, levels: Int) {
            self.levels = levels
            var w = width, h = height
            for _ in 0..<levels {
                bands.append(FloatImage(width: w, height: h, channels: channels))
                weights.append(FloatImage(width: w, height: h, channels: 1))
                w = (w + 1) / 2
                h = (h + 1) / 2
            }
        }

        /// Adds a picture where `weight` (one number per pixel) says how much it counts.
        public mutating func add(_ image: FloatImage, weight: [Float]) {
            let lap = laplacian(image, levels: levels)
            let gauss = gaussian(FloatImage(width: image.width, height: image.height, channels: 1, data: weight), levels: levels)
            for l in 0..<levels {
                let c = lap[l].channels
                bands[l].data.withUnsafeMutableBufferPointer { s in
                    weights[l].data.withUnsafeMutableBufferPointer { ws in
                        lap[l].data.withUnsafeBufferPointer { b in
                            gauss[l].data.withUnsafeBufferPointer { wt in
                                for i in 0..<wt.count {
                                    let k = wt[i]
                                    if k == 0 { continue }
                                    ws[i] += k
                                    for ch in 0..<c { s[i * c + ch] += k * b[i * c + ch] }
                                }
                            }
                        }
                    }
                }
            }
        }

        /// The blended picture (pixels no picture covered come out 0).
        public func result() -> FloatImage {
            var normalized = bands
            for l in 0..<levels {
                let c = normalized[l].channels
                for i in 0..<weights[l].count {
                    let k = weights[l].data[i]
                    for ch in 0..<c { normalized[l].data[i * c + ch] = k > 1e-6 ? normalized[l].data[i * c + ch] / k : 0 }
                }
            }
            return collapse(normalized)
        }
    }

    /// Weights scaled to add up to 1 at every pixel (equal shares where they are all 0).
    public static func normalize(_ weights: [[Float]]) -> [[Float]] {
        guard let n = weights.first?.count else { return weights }
        var out = weights
        for i in 0..<n {
            var total: Float = 0
            for k in weights.indices { total += weights[k][i] }
            for k in weights.indices { out[k][i] = total > 1e-12 ? weights[k][i] / total : 1 / Float(weights.count) }
        }
        return out
    }
}

/// Small helpers on one-channel grids (masks, weights).
public enum Grid {
    /// About a Gaussian blur of `radius` pixels (three box blurs).
    public static func blur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        MaskRaster.blur(values, width: width, height: height, radius: radius)
    }

    /// Largest value within `radius` pixels (grows bright areas).
    public static func dilate(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        MaskRaster.extreme(values, width: width, height: height, radius: radius, grow: true)
    }

    /// |Laplacian| of a grey picture (3 × 3, edges repeated): high on fine detail.
    public static func laplacian(_ grey: [Float], width w: Int, height h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        grey.withUnsafeBufferPointer { g in
            for y in 0..<h {
                let up = max(y - 1, 0), down = min(y + 1, h - 1)
                for x in 0..<w {
                    let left = max(x - 1, 0), right = min(x + 1, w - 1)
                    let v = 4 * g[y * w + x] - g[up * w + x] - g[down * w + x] - g[y * w + left] - g[y * w + right]
                    out[y * w + x] = abs(v)
                }
            }
        }
        return out
    }

    /// The median of some numbers (0 for none).
    public static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
