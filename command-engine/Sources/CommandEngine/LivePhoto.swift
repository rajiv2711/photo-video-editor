import Foundation

/// Live Photo effects (as Apple Photos has them), from the short video a Live Photo keeps:
/// - Live: the photo, or any frame of the video as the Key Frame.
/// - Loop: the video repeating, its end crossfaded into its start so the jump doesn't show.
/// - Bounce: the video forwards, then backwards.
/// - Long Exposure: every frame lined up with the key frame and averaged, so moving water and lights
///   smear while the rest stays sharp.
/// Loop and Bounce are saved as an animation; the photo shows the key frame meanwhile.
public enum LivePhoto {
    public enum Effect: String {
        case live, loop, bounce, longExposure
    }

    /// "livePhotoEffect" option ids, in order; must match controls.json.
    public static let effects = ["live", "loop", "bounce", "longExposure"]

    /// One frame of an exported animation: video frame `a`, mixed with frame `b` by `t` (0 = only `a`).
    public struct Step: Equatable {
        public var a: Int
        public var b: Int
        public var t: Float

        public init(_ a: Int, _ b: Int = 0, _ t: Float = 0) {
            self.a = a
            self.b = b
            self.t = t
        }
    }

    /// The frames of the animation for Loop or Bounce, from a video of `count` frames. Loop: the last
    /// `fade` frames are not shown on their own but fade out over the first ones, so the last frame
    /// shown leads straight into the first. Bounce: forwards, then back without repeating the ends.
    public static func animation(_ effect: Effect, count: Int, fade: Int = 8) -> [Step] {
        guard count > 1 else { return count == 1 ? [Step(0)] : [] }
        switch effect {
        case .bounce:
            return (0..<count).map { Step($0) } + stride(from: count - 2, to: 0, by: -1).map { Step($0) }
        case .loop:
            let f = min(fade, count / 3)
            guard f > 0 else { return (0..<count).map { Step($0) } }
            return (0..<(count - f)).map { i in
                // Output i < f: frame i, with frame (count − f + i) fading out over it.
                i < f ? Step(i, count - f + i, 1 - Float(i + 1) / Float(f + 1)) : Step(i)
            }
        default:
            return []
        }
    }

    /// The video frame (0-based) a Key Frame value stands for: nil for 0 (the photo itself), else
    /// frame value − 1, kept inside the video.
    public static func frame(forKey key: Double, count: Int) -> Int? {
        let k = Int(key.rounded())
        guard k > 0, count > 0 else { return nil }
        return min(k, count) - 1
    }

    /// Long exposure: frames added one at a time (so a whole video never has to be in memory), each
    /// lined up with the reference first, then averaged.
    public struct LongExposure {
        let reference: FloatImage
        var sum: [Double]
        var weight: [Double]

        /// `reference`: the frame the others are lined up with (RGB, the frames' size).
        public init(reference: FloatImage) {
            self.reference = reference
            sum = reference.data.map(Double.init)
            weight = [Double](repeating: 1, count: reference.count)
        }

        /// Adds a frame (its own repeated edges, where it was moved, don't count).
        public mutating func add(_ frame: FloatImage) {
            guard frame.width == reference.width, frame.height == reference.height else { return }
            let shift = Align.translation(reference: reference.luma, image: frame.luma)
            let (moved, valid) = Align.shifted(frame, by: shift)
            let c = frame.channels
            for i in 0..<frame.count where valid[i] > 0 {
                weight[i] += 1
                for ch in 0..<c { sum[i * c + ch] += Double(moved.data[i * c + ch]) }
            }
        }

        /// The average so far.
        public var result: FloatImage {
            var out = reference
            let c = reference.channels
            for i in 0..<reference.count {
                for ch in 0..<c { out.data[i * c + ch] = Float(sum[i * c + ch] / weight[i]) }
            }
            return out
        }
    }
}
