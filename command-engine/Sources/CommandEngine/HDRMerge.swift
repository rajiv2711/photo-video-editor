import Foundation

/// HDR merge of bracketed exposures (no learning):
/// 1. The bracket with the middle brightness is the reference; the others are lined up with it (Align).
/// 2. Each bracket's exposure relative to the reference is measured from the pixels well exposed in
///    both (median ratio of linear brightness), so no EXIF is needed.
/// 3. Deghost: where a bracket disagrees with what the reference predicts for it (something moved),
///    its pixels are replaced by that prediction (the reference at the bracket's exposure), so the
///    reference shows there in every bracket and the tones still match; Low, Medium, High lower the
///    threshold.
/// 4. Output "fusion" (default): exposure fusion (Mertens, Kautz & Van Reeth 2007), each bracket
///    weighted per pixel by contrast × saturation × well-exposedness and blended band by band; ready
///    to edit on any screen. Output "radiance": linear light (Debevec & Malik 1997 style weighted
///    average of each bracket ÷ its exposure), relative to the reference, so highlights it lost come
///    back above white: the HDR switch shows them on an XDR screen.
public enum HDRMerge {
    public enum Output: String {
        case fusion, radiance
    }

    /// Deghost settings: the "deghost" choice's option ids, in order; must match controls.json.
    public static let deghostLevels = ["off", "low", "medium", "high"]
    /// "hdrOutput" option ids, in order; must match controls.json.
    public static let outputs = ["fusion", "radiance"]

    /// How far (sRGB levels of brightness) a bracket may stray from the reference's prediction
    /// before it counts as a ghost, per deghost level (nil = off).
    static func ghostThreshold(_ level: Int) -> Float? {
        switch level {
        case 1: return 0.22
        case 2: return 0.13
        case 3: return 0.07
        default: return nil
        }
    }

    /// The merged picture of `brackets` (RGB on sRGB levels, 0…1, one size): sRGB levels for fusion,
    /// linear light for radiance. `deghost`: index into `deghostLevels`.
    public static func merge(_ brackets: [FloatImage], deghost: Int = 0, output: Output = .fusion) -> FloatImage {
        guard let first = brackets.first else { return FloatImage(width: 0, height: 0, channels: 3) }
        guard brackets.count > 1 else { return output == .fusion ? first : first.map(SRGB.linear) }
        let w = first.width, h = first.height
        let means = brackets.map { $0.luma.mean }
        let order = means.indices.sorted { means[$0] < means[$1] }
        let ref = order[order.count / 2]

        // 1. Line every bracket up with the reference.
        var aligned = brackets
        var valid = [[Float]](repeating: [Float](repeating: 1, count: w * h), count: brackets.count)
        let refLuma = brackets[ref].luma
        for k in brackets.indices where k != ref {
            let shift = Align.translation(reference: refLuma, image: brackets[k].luma)
            (aligned[k], valid[k]) = Align.shifted(brackets[k], by: shift)
        }

        // 2. Exposures relative to the reference.
        let linearLuma = aligned.map { $0.luma.map(SRGB.linear) }
        let encodedLuma = aligned.map { $0.luma }
        let ratios = brackets.indices.map { k -> Float in
            k == ref ? 1 : exposureRatio(linearLuma[k], encodedLuma[k], reference: linearLuma[ref], encodedLuma[ref], valid: valid[k])
        }

        // 3. Ghosts: where a bracket disagrees with the reference, it takes the reference's prediction.
        let keep = valid
        if let threshold = ghostThreshold(deghost) {
            let radius = max(1, min(w, h) / 200)
            let smoothRef = Grid.blur(encodedLuma[ref].data, width: w, height: h, radius: 1)
            for k in brackets.indices where k != ref {
                let smooth = Grid.blur(encodedLuma[k].data, width: w, height: h, radius: 1)
                var ghost = [Float](repeating: 0, count: w * h)
                for i in 0..<(w * h) {
                    let r = smoothRef[i]
                    guard r > 0.03, r < 0.97 else { continue }  // the reference can't say what should be there
                    let predicted = SRGB.encoded(min(1, SRGB.linear(r) * ratios[k]))
                    let seen = smooth[i]
                    guard predicted > 0.03, predicted < 0.97, seen > 0.03, seen < 0.97 else { continue }
                    let d = abs(predicted - seen)
                    ghost[i] = min(1, max(0, (d - threshold) / threshold))
                }
                ghost = Grid.blur(Grid.dilate(ghost, width: w, height: h, radius: 2 * radius), width: w, height: h, radius: radius)
                let reference = aligned[ref]
                for i in 0..<(w * h) where ghost[i] > 0 {
                    let g = min(1, ghost[i] * 2)
                    for c in 0..<3 {
                        let predicted = SRGB.encoded(min(1, SRGB.linear(reference.data[3 * i + c]) * ratios[k]))
                        aligned[k].data[3 * i + c] += g * (predicted - aligned[k].data[3 * i + c])
                    }
                }
            }
        }

        switch output {
        case .fusion:
            var weights = aligned.indices.map { k -> [Float] in
                let wk = fusionWeights(aligned[k])
                return zip(wk, keep[k]).map { $0 * $1 }
            }
            // The reference always has a little say, so pixels every other bracket left are filled.
            for i in 0..<(w * h) { weights[ref][i] = max(weights[ref][i], 1e-6) }
            var fused = Pyramid.blend(aligned, weights: Pyramid.normalize(weights))
            for i in fused.data.indices { fused.data[i] = min(1, max(0, fused.data[i])) }
            return fused
        case .radiance:
            return radiance(aligned, ratios: ratios, keep: keep, reference: ref)
        }
    }

    /// A bracket's exposure ÷ the reference's: the median ratio of their linear brightness where both
    /// are well exposed (the mean ratio when too few pixels are).
    static func exposureRatio(_ linear: FloatImage, _ encoded: FloatImage, reference linearRef: FloatImage, _ encodedRef: FloatImage,
                              valid: [Float]) -> Float {
        var ratios: [Float] = []
        let step = max(1, linear.count / 50_000)
        for i in stride(from: 0, to: linear.count, by: step) where valid[i] > 0 {
            let a = encoded.data[i], b = encodedRef.data[i]
            guard a > 0.08, a < 0.92, b > 0.08, b < 0.92, linearRef.data[i] > 1e-4 else { continue }
            ratios.append(linear.data[i] / linearRef.data[i])
        }
        if ratios.count >= 20 { return Grid.median(ratios) }
        let m = linearRef.mean
        return m > 1e-6 ? max(1e-3, linear.mean / m) : 1
    }

    /// Exposure fusion weights of one bracket: contrast (|Laplacian| of brightness) × saturation
    /// (spread of R, G, B) × well-exposedness (closeness of each channel to mid-grey).
    public static func fusionWeights(_ image: FloatImage) -> [Float] {
        let w = image.width, h = image.height
        let contrast = Grid.laplacian(image.luma.data, width: w, height: h)
        var out = [Float](repeating: 0, count: w * h)
        let sigma2: Float = 2 * 0.2 * 0.2
        image.data.withUnsafeBufferPointer { d in
            for i in 0..<(w * h) {
                let r = d[3 * i], g = d[3 * i + 1], b = d[3 * i + 2]
                let mu = (r + g + b) / 3
                let saturation = sqrtf(((r - mu) * (r - mu) + (g - mu) * (g - mu) + (b - mu) * (b - mu)) / 3)
                let well = expf(-((r - 0.5) * (r - 0.5) + (g - 0.5) * (g - 0.5) + (b - 0.5) * (b - 0.5)) / sigma2)
                // Small floors so flat grey areas still get a share by exposure.
                out[i] = (contrast[i] + 0.002) * (saturation + 0.01) * well + 1e-12
            }
        }
        return out
    }

    /// Linear radiance relative to the reference: each bracket's linear colour ÷ its exposure, weighted
    /// by how well exposed it is (a wide hat on sRGB levels; clipped channels hardly count).
    static func radiance(_ brackets: [FloatImage], ratios: [Float], keep: [[Float]], reference: Int) -> FloatImage {
        let w = brackets[0].width, h = brackets[0].height
        var out = FloatImage(width: w, height: h, channels: 3)
        // The darkest bracket speaks for clipped highlights, the brightest for black shadows.
        let darkest = ratios.indices.min { ratios[$0] < ratios[$1] } ?? reference
        let brightest = ratios.indices.max { ratios[$0] < ratios[$1] } ?? reference
        for i in 0..<(w * h) {
            var sum: (Float, Float, Float) = (0, 0, 0)
            var total: Float = 0
            for k in brackets.indices {
                let r = brackets[k].data[3 * i], g = brackets[k].data[3 * i + 1], b = brackets[k].data[3 * i + 2]
                let top = max(r, g, b), bottom = min(r, g, b)
                var weight = hat(0.2126 * r + 0.7152 * g + 0.0722 * b)
                if top > 0.985 { weight *= k == darkest ? 0.05 : 0.0005 }
                if bottom < 0.01, k != brightest { weight *= 0.2 }
                weight *= k == reference ? 1 : keep[k][i]
                weight = max(weight, k == reference ? 1e-6 : 0)
                let e = 1 / ratios[k]
                sum.0 += weight * SRGB.linear(r) * e
                sum.1 += weight * SRGB.linear(g) * e
                sum.2 += weight * SRGB.linear(b) * e
                total += weight
            }
            out.data[3 * i] = sum.0 / total
            out.data[3 * i + 1] = sum.1 / total
            out.data[3 * i + 2] = sum.2 / total
        }
        return out
    }

    /// Weight of an sRGB level: 1 in the middle, falling to 0 at black and white.
    static func hat(_ v: Float) -> Float {
        let t = 2 * v - 1
        return max(0.001, 1 - powf(abs(t), 8))
    }
}
