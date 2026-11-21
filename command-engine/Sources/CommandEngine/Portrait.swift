import Foundation

/// Portrait depth editing for iPhone Portrait photos, from the depth (disparity) map and portrait
/// matte they keep inside the file. Nothing is estimated: a photo without them has no depth effects.
/// - Aperture: background blur by distance from the focus depth, more at small f-numbers (f/16 none).
/// - Focus depth: the distance kept sharp (100 = nearest), set by a tap on the photo.
/// - Lighting: Natural, Studio (the subject brighter), Contour (shading towards the subject's edges),
///   Stage (the background black), Stage Mono, High-Key Mono (grey subject on white). The subject is
///   the portrait matte, or the near part of the depth map (split by Otsu's threshold).
public enum Portrait {
    /// "portraitLighting" option ids, in order; must match controls.json.
    public static let lightings = ["natural", "studio", "contour", "stage", "stageMono", "highKeyMono"]

    /// A photo's depth: `values` 0 (far) … 1 (near) on a grid of `width` × `height` cells (row by row
    /// from the top), the matte (1 = the subject) on the same grid if the photo has one, and the
    /// depth that splits subject from background.
    public struct DepthMap: Equatable {
        public let width: Int
        public let height: Int
        public let values: [Float]
        public let matte: [Float]?
        public let threshold: Float

        /// From raw disparity (bigger = nearer; any units) and an optional matte on the same grid:
        /// stretched so the 2nd–98th percentiles span 0…1.
        public init(disparity: [Float], width: Int, height: Int, matte: [Float]? = nil) {
            self.width = width
            self.height = height
            let finite = disparity.filter { $0.isFinite }
            let sorted = finite.sorted()
            let low = sorted.isEmpty ? 0 : sorted[sorted.count * 2 / 100]
            let high = sorted.isEmpty ? 1 : sorted[min(sorted.count - 1, sorted.count * 98 / 100)]
            let span = max(high - low, 1e-6)
            values = disparity.map { $0.isFinite ? min(1, max(0, ($0 - low) / span)) : 0 }
            self.matte = matte?.count == width * height ? matte : nil
            threshold = Portrait.otsu(values)
        }

        /// The depth at a point (x, y from the top-left, 0…1): the median of the 3 × 3 cells around it.
        public func depth(at p: MaskPoint) -> Float {
            let cx = min(width - 1, max(0, Int(p.x * Double(width)))), cy = min(height - 1, max(0, Int(p.y * Double(height))))
            var around: [Float] = []
            for y in max(0, cy - 1)...min(height - 1, cy + 1) {
                for x in max(0, cx - 1)...min(width - 1, cx + 1) { around.append(values[y * width + x]) }
            }
            return Grid.median(around)
        }

        /// The subject: the matte, or the near side of the threshold (softly, over ±0.08 of depth).
        public var subject: [Float] {
            if let matte { return matte }
            return values.map { v in
                let t = min(1, max(0, (v - (threshold - 0.08)) / 0.16))
                return t * t * (3 - 2 * t)
            }
        }
    }

    /// Otsu's threshold of values in 0…1 (the split that best separates two groups), on 64 bins.
    public static func otsu(_ values: [Float]) -> Float {
        let bins = 64
        var histogram = [Double](repeating: 0, count: bins)
        for v in values { histogram[min(bins - 1, max(0, Int(v * Float(bins))))] += 1 }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0.5 }
        let sumAll = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
        var weightBelow = 0.0, sumBelow = 0.0
        var between = [Double](repeating: 0, count: bins)
        for t in 0..<bins {
            weightBelow += histogram[t]
            sumBelow += Double(t) * histogram[t]
            let weightAbove = total - weightBelow
            guard weightBelow > 0, weightAbove > 0 else { continue }
            between[t] = weightBelow * weightAbove * pow(sumBelow / weightBelow - (sumAll - sumBelow) / weightAbove, 2)
        }
        // Empty bins between the groups split them equally well: take the middle of that gap.
        let best = between.max() ?? 0
        guard best > 0 else { return 0.5 }
        let ties = between.indices.filter { between[$0] >= best * 0.999 }
        return (Float(ties.first! + ties.last!) / 2 + 1) / Float(bins)
    }

    /// The largest blur (pixels) for an f-number on a photo with this long side: none at f/16, 2 % of
    /// the long side at f/1.4, in proportion to 1/N (the aperture's size) between.
    public static func blurRadius(aperture: Double, longSide: Double) -> Double {
        let n = min(16, max(1.4, aperture))
        return 0.02 * longSide * (1 / n - 1 / 16) / (1 / 1.4 - 1 / 16)
    }

    /// How blurred each cell is (0…1 of the largest blur): nothing within ±0.04 of the focus depth
    /// (0…1), full at 0.35 away. With a matte, the subject stays sharp while the focus is on it.
    public static func blurMask(_ map: DepthMap, focus: Float) -> [Float] {
        let onSubject = map.matte != nil && focus >= map.threshold
        return map.values.indices.map { i in
            let d = abs(map.values[i] - focus)
            var m = min(1, max(0, (d - 0.04) / 0.31))
            if onSubject, let matte = map.matte { m *= 1 - matte[i] }
            return m
        }
    }
}
