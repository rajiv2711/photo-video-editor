import CommandEngine
import CoreImage
import UIKit

/// Print (Export panel): the photo as exported, laid out on the printer's paper as Print Size, Print
/// Layout (fit or fill) and Print Margins say (PrintLayout in CommandEngine), through AirPrint.
struct PrintSetup {
    var size = "page"
    var fill = false
    var marginMM = 5.0
}

/// Draws the photo on each printed page (one page) where PrintLayout puts it.
final class PhotoPrintRenderer: UIPrintPageRenderer {
    let image: UIImage
    let setup: PrintSetup

    init(image: UIImage, setup: PrintSetup) {
        self.image = image
        self.setup = setup
        super.init()
    }

    override var numberOfPages: Int { 1 }

    override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        let printable = PrintRect(x: Double(printableRect.minX), y: Double(printableRect.minY),
                                  width: Double(printableRect.width), height: Double(printableRect.height))
        let aspect = Double(image.size.width / max(image.size.height, 1))
        let placed = PrintLayout.place(printable: printable, marginMM: setup.marginMM, size: setup.size, fill: setup.fill, photoAspect: aspect)
        let frame = CGRect(x: placed.frame.x, y: placed.frame.y, width: placed.frame.width, height: placed.frame.height)
        // The whole photo drawn so its cropped part lands on the frame.
        let c = placed.crop
        let drawn = CGRect(x: frame.minX - CGFloat(c.x / c.width) * frame.width, y: frame.minY - CGFloat(c.y / c.height) * frame.height,
                           width: frame.width / CGFloat(c.width), height: frame.height / CGFloat(c.height))
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.clip(to: frame)
        image.draw(in: drawn)
        context.restoreGState()
    }
}

enum PhotoPrinter {
    /// AirPrint's dialog for the photo (photo paper, one page laid out as `setup` says).
    @MainActor
    static func present(_ image: UIImage, name: String, setup: PrintSetup, done: @escaping (String) -> Void) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .photo
        info.jobName = name
        info.orientation = image.size.width > image.size.height ? .landscape : .portrait
        controller.printInfo = info
        controller.printPageRenderer = PhotoPrintRenderer(image: image, setup: setup)
        controller.present(animated: true) { _, completed, error in
            done(error.map { "Printing failed: \($0.localizedDescription)" } ?? (completed ? "Sent \(name) to the printer" : "Printing cancelled"))
        }
    }

    /// The page as it will print, for the render gallery: white paper of `paper` points (1 pixel each)
    /// with the photo where PrintLayout puts it inside `printable`.
    static func preview(_ photo: CIImage, paper: CGSize, printable: CGRect, setup: PrintSetup) -> (page: CIImage, frame: PrintRect) {
        let e = photo.extent
        let placed = PrintLayout.place(printable: PrintRect(x: Double(printable.minX), y: Double(printable.minY),
                                                            width: Double(printable.width), height: Double(printable.height)),
                                       marginMM: setup.marginMM, size: setup.size, fill: setup.fill, photoAspect: Double(e.width / e.height))
        let c = placed.crop
        // The photo's part shown (Core Image counts from the bottom), scaled onto the frame.
        let part = CGRect(x: e.minX + CGFloat(c.x) * e.width, y: e.minY + CGFloat(1 - c.y - c.height) * e.height,
                          width: CGFloat(c.width) * e.width, height: CGFloat(c.height) * e.height)
        let f = placed.frame
        let target = CGRect(x: f.x, y: Double(paper.height) - f.y - f.height, width: f.width, height: f.height)
        let shown = photo.cropped(to: part)
            .transformed(by: CGAffineTransform(translationX: -part.minX, y: -part.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / part.width, y: target.height / part.height))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        let page = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(origin: .zero, size: paper))
        return (shown.composited(over: page).cropped(to: page.extent), placed.frame)
    }
}
