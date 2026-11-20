import Foundation

/// Match color: gives a photo the colour mood of a reference picture by matching each channel's
/// average and spread (Reinhard's colour transfer, per R, G, B channel on sRGB levels).
/// Shared by the iPad renderer and the Linux tests.
///
///     let t = MatchColor.transfer(from: photoStats, to: referenceStats, amount: 1)
///     // new level = old level × t.scale + t.bias, per channel
public enum MatchColor {
    /// Option ids of the Match Color choice, in controls.json order (the reference pictures).
    public static let referenceIDs = ["none", "testPhoto", "sunset"]

    /// Average and spread (standard deviation) of each channel of a picture.
    public struct Stats: Equatable {
        public var mean: RGB
        public var deviation: RGB

        public init(mean: RGB, deviation: RGB) {
            self.mean = mean
            self.deviation = deviation
        }

        /// From the averages of the levels and of the squared levels.
        public init(mean: RGB, meanOfSquares: RGB) {
            func sd(_ m: Double, _ m2: Double) -> Double { Swift.max(m2 - m * m, 0).squareRoot() }
            self.mean = mean
            deviation = RGB(sd(mean.r, meanOfSquares.r), sd(mean.g, meanOfSquares.g), sd(mean.b, meanOfSquares.b))
        }
    }

    /// Per-channel multiplier and offset that move `source` statistics onto `reference`, mixed with
    /// "no change" by `amount` (0…1). The spread ratio is kept within ⅓…3 so flat pictures don't explode.
    public static func transfer(from source: Stats, to reference: Stats, amount: Double) -> (scale: RGB, bias: RGB) {
        func channel(_ ms: Double, _ ss: Double, _ mr: Double, _ sr: Double) -> (Double, Double) {
            let k = Swift.min(Swift.max(sr / Swift.max(ss, 1e-4), 1.0 / 3), 3)
            // x → (x − ms)·k + mr, then mixed: x + amount·(that − x).
            return (1 + amount * (k - 1), amount * (mr - k * ms))
        }
        let r = channel(source.mean.r, source.deviation.r, reference.mean.r, reference.deviation.r)
        let g = channel(source.mean.g, source.deviation.g, reference.mean.g, reference.deviation.g)
        let b = channel(source.mean.b, source.deviation.b, reference.mean.b, reference.deviation.b)
        return (RGB(r.0, g.0, b.0), RGB(r.1, g.1, b.1))
    }
}
