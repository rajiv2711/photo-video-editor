import AVFoundation
import CommandEngine
import CoreImage
import ImageIO
import Photos
import UniformTypeIdentifiers

/// A Live Photo: its photo and the frames of its short video, read one at a time when needed (so the
/// whole video is never held in memory). The render gallery makes one from pictures instead.
final class LiveFrames {
    let still: CIImage
    /// Frames of the video (at most `maxFrames`, spread evenly over it) and how many play per second.
    let count: Int
    let fps: Double
    private let read: (Int) -> CIImage?

    static let maxFrames = 90

    init(still: CIImage, count: Int, fps: Double, read: @escaping (Int) -> CIImage?) {
        self.still = still
        self.count = count
        self.fps = fps
        self.read = read
    }

    /// Frames held as pictures (the render gallery).
    convenience init(still: CIImage, frames: [CIImage], fps: Double = 15) {
        self.init(still: still, count: frames.count, fps: fps) { i in frames.indices.contains(i) ? frames[i] : nil }
    }

    /// Frame `i` (0-based), or nil.
    func frame(_ i: Int) -> CIImage? {
        i >= 0 && i < count ? read(i) : nil
    }

    /// The frames of the video file next to a Live Photo's photo (at most 1920 pixels across).
    static func load(still: CIImage, video url: URL) async -> LiveFrames? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
        let rate = (try? await track.load(.nominalFrameRate)) ?? 30
        let total = max(1, Int(duration.seconds * Double(rate > 0 ? rate : 30)))
        let count = min(total, maxFrames)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let step = duration.seconds / Double(count)
        return LiveFrames(still: still, count: count, fps: Double(count) / duration.seconds) { i in
            let time = CMTime(seconds: (Double(i) + 0.5) * step, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return CIImage(cgImage: cg)
        }
    }

    /// The video of a Live Photo picked in the library, copied to a temporary file.
    static func pairedVideo(of livePhoto: PHLivePhoto) async -> URL? {
        let resources = PHAssetResource.assetResources(for: livePhoto)
        guard let video = resources.first(where: { $0.type == .pairedVideo }) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        do {
            try await PHAssetResourceManager.default().writeData(for: video, toFile: url, options: nil)
            return url
        } catch {
            return nil
        }
    }

    /// An animated GIF (looping forever) of Loop or Bounce: each frame of the animation, edited by
    /// `edit` (the editor's sliders), at most `side` pixels across.
    func gif(_ effect: LivePhoto.Effect, side: CGFloat, context: CIContext, edit: (CIImage) -> CIImage) -> Data? {
        let steps = LivePhoto.animation(effect, count: count)
        guard !steps.isEmpty else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, steps.count, nil) else { return nil }
        let loop: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let frameProperties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(0.02, 1 / max(fps, 1))]]
        let delay = frameProperties as CFDictionary
        for step in steps {
            autoreleasepool {
                guard var picture = frame(step.a) else { return }
                if step.t > 0, let other = frame(step.b) { picture = Filters.mix(picture, other, Double(step.t)) }
                let edited = edit(PhotoRenderer.downscaled(picture, maxSide: side))
                if let cg = context.createCGImage(edited, from: edited.extent) {
                    CGImageDestinationAddImage(destination, cg, delay)
                }
            }
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
