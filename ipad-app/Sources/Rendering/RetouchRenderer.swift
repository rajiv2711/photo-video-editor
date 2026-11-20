import CommandEngine
import CoreImage
import Foundation

/// The Retouch panel's steps (spots and strokes), drawn by RetouchCanvas in CommandEngine on a float
/// copy of the photo after lens corrections (sRGB levels), before white balance and every other slider.
/// A canvas keeps each step's result, so a new step only works out that step, and the other sliders
/// never redo any retouching. For the live preview the work runs on a background queue and the last
/// finished picture shows meanwhile; the render gallery and saving wait for it.
final class RetouchRenderer {
    let context: CIContext
    /// Called on the main thread when background work finished: render again.
    var onFinish: (() -> Void)?

    /// Canvas work, one job at a time, off the main thread.
    private let queue = DispatchQueue(label: "retouch", qos: .userInitiated)
    /// One canvas per picture (the preview and the full-size photo while saving), newest first.
    private var slots: [Slot] = []
    /// The steps the newest background job should draw (read on the queue, so behind a lock).
    private let lock = NSLock()
    private var wanted: [Retouch]?

    /// A picture's canvas and what it shows.
    final class Slot {
        let source: CIImage
        let key: [Double]
        let extent: CGRect
        /// Used on the queue only.
        var canvas: RetouchCanvas?
        /// The last finished picture, the steps it shows and the sources picked for them (main thread).
        var finished: (steps: [Retouch], image: CIImage, sources: [Int: MaskPoint])?
        /// Steps a background job is drawing (main thread).
        var pending: [Retouch]?

        init(source: CIImage, key: [Double], extent: CGRect) {
            self.source = source
            self.key = key
            self.extent = extent
        }
    }

    init(context: CIContext) {
        self.context = context
    }

    /// The steps the last finished render of the preview drew and the sources it picked for them.
    var finished: (steps: [Retouch], sources: [Int: MaskPoint])? {
        slots.first?.finished.map { (steps: $0.steps, sources: $0.sources) }
    }

    /// `image` (the photo after lens corrections) with the steps drawn. `source` and `key` (the
    /// renderer's input and the lens settings) say when the picture changed. With `wait` false the
    /// result may come later (`onFinish`); meanwhile the last finished picture is shown.
    func apply(_ image: CIImage, steps: [Retouch], source: CIImage, key: [Double], wait: Bool) -> CIImage {
        guard !steps.isEmpty else { return image }
        let slot = self.slot(for: image, source: source, key: key)
        if let finished = slot.finished, finished.steps == steps { return finished.image }
        let extent = slot.extent
        if wait {
            var result: RetouchResult?
            queue.sync { result = slot.canvas?.render(steps) }
            guard let result else { return image }
            let picture = Self.picture(result.image, extent: extent)
            slot.finished = (steps: steps, image: picture, sources: result.sources)
            slot.pending = nil
            return picture
        }
        if slot.pending != steps {
            slot.pending = steps
            lock.lock()
            wanted = steps
            lock.unlock()
            queue.async { [weak self, slot] in
                guard let self, self.isWanted(steps), let result = slot.canvas?.render(steps) else { return }
                let picture = Self.picture(result.image, extent: extent)
                DispatchQueue.main.async {
                    guard slot.pending == steps else { return }
                    slot.pending = nil
                    slot.finished = (steps: steps, image: picture, sources: result.sources)
                    self.onFinish?()
                }
            }
        }
        return slot.finished?.image ?? image
    }

    private func isWanted(_ steps: [Retouch]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wanted == steps
    }

    /// The canvas for this picture, made (from its pixels) the first time it is seen.
    private func slot(for image: CIImage, source: CIImage, key: [Double]) -> Slot {
        let extent = image.extent
        if let i = slots.firstIndex(where: { $0.source === source && $0.key == key && $0.extent == extent }) {
            let slot = slots.remove(at: i)
            slots.insert(slot, at: 0)
            return slot
        }
        let slot = Slot(source: source, key: key, extent: extent)
        // The last picture of the same size stays on screen while the new canvas works.
        if let old = slots.first(where: { $0.extent == extent })?.finished {
            slot.finished = (steps: [], image: old.image, sources: [:])
        }
        let base = read(image)
        queue.async { slot.canvas = RetouchCanvas(base: base) }
        slots.insert(slot, at: 0)
        if slots.count > 2 { slots.removeLast() }
        return slot
    }

    /// The picture as numbers on sRGB levels (HDR levels kept above 1).
    private func read(_ image: CIImage) -> RGBBuffer {
        let extent = image.extent
        let width = Int(extent.width.rounded(.up)), height = Int(extent.height.rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.extendedSRGB) else {
            return RGBBuffer(width: 0, height: 0, pixels: [])
        }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        context.render(image.clampedToExtent(), toBitmap: &rgba, rowBytes: width * 16,
                       bounds: CGRect(x: extent.minX, y: extent.minY, width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf, colorSpace: space)
        return RGBBuffer(width: width, height: height, rgba: rgba)
    }

    /// Numbers back into a picture over `extent`.
    static func picture(_ buffer: RGBBuffer, extent: CGRect) -> CIImage {
        guard buffer.width > 0, buffer.height > 0, let space = CGColorSpace(name: CGColorSpace.extendedSRGB) else {
            return CIImage.empty()
        }
        let data = buffer.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16, size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf, colorSpace: space)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
