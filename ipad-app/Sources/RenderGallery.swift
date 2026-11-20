import CoreImage
import SwiftUI
import UIKit

/// Cloud-build test mode, started with the launch argument `-renderGallery`.
///
/// For every case in `gallery.json` (test-data/gallery/) it starts from the untouched test photo
/// (about 800 px), or a picture generated from it (`source`), runs the case's command through the
/// same interpreter and renderer as the editor, and writes `Documents/gallery/<id>.jpg` plus
/// `manifest.json`. Then the app quits.
/// `dev-tools/ci_results.py` on the laptop measures the pictures and checks each expectation.
@MainActor
enum RenderGallery {
    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-renderGallery")
    }

    /// One expected change, e.g. {"metric":"p95_luma","dir":"down"}. Passed to the manifest as is.
    struct Expectation: Codable {
        let metric: String
        let dir: String
        /// Case to compare with; the "base" case when missing.
        let vs: String?
        /// Smallest change that counts; ci_results.py has a default per metric.
        let min: Double?
    }

    struct Case: Codable {
        let id: String
        let command: String
        let control: String?
        let expect: [Expectation]
        /// A generated picture to start from instead of the test photo (see `sourceImage`).
        let source: String?
        /// A tap on the photo after the command (picker tools): x, y from the top-left, 0…1.
        let tap: [Double]?
    }

    struct CaseFile: Codable {
        let cases: [Case]
    }

    /// What one rendered case looked like, for the laptop checker.
    struct Entry: Codable {
        let id: String
        let command: String
        let control: String?
        let expect: [Expectation]
        let file: String
        /// The feedback line the editor showed, e.g. "Highlights 0 → -100".
        let feedback: String
        /// Controls that are not at their default after the command.
        let values: [String: Double]
        /// Brightest channel value (linear light) before conversion to 8-bit pixels.
        let peak: Double
    }

    struct Manifest: Codable {
        let photo: String
        let width: Int
        let height: Int
        let cases: [Entry]
        let error: String?
    }

    static let longSide: CGFloat = 800

    static func run() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gallery", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        guard let casesURL = Bundle.main.url(forResource: "gallery", withExtension: "json"),
              let data = try? Data(contentsOf: casesURL) else {
            write(Manifest(photo: "", width: 0, height: 0, cases: [], error: "gallery.json is not in the app bundle"), to: folder)
            return
        }
        let cases: [Case]
        do {
            cases = try JSONDecoder().decode(CaseFile.self, from: data).cases
        } catch {
            write(Manifest(photo: "", width: 0, height: 0, cases: [], error: "gallery.json: \(error)"), to: folder)
            return
        }
        guard let photoURL = Bundle.main.url(forResource: "test", withExtension: "jpg"),
              let photo = CIImage(contentsOf: photoURL, options: [.applyOrientationProperty: true]) else {
            write(Manifest(photo: "", width: 0, height: 0, cases: [], error: "test.jpg is not in the app bundle"), to: folder)
            return
        }

        let small = PhotoRenderer.downscaled(photo, maxSide: longSide)
        // One editor per starting picture, made when a case first needs it.
        var models: [String: EditorModel] = [:]
        func editor(for source: String?) -> EditorModel {
            let key = source ?? "photo"
            if let existing = models[key] { return existing }
            let made = EditorModel(image: sourceImage(source, photo: small), previewSide: longSide)
            models[key] = made
            return made
        }
        var entries: [Entry] = []
        for item in cases {
            let model = editor(for: item.source)
            model.startOver()
            if !item.command.isEmpty {
                model.run(item.command)
            }
            if let tap = item.tap, tap.count == 2 {
                model.tap(atX: tap[0], y: tap[1])
            }
            let edited = model.editedPreview()
            let file = "\(item.id).jpg"
            if let jpeg = model.renderer.jpegData(edited) {
                try? jpeg.write(to: folder.appendingPathComponent(file))
            }
            entries.append(Entry(
                id: item.id,
                command: item.command,
                control: item.control,
                expect: item.expect,
                file: file,
                feedback: model.feedback?.text ?? "",
                values: model.changedValues(),
                peak: model.renderer.peak(of: edited)
            ))
        }
        writeFilterAttributes(to: folder)
        let size = small.extent.integral.size
        write(Manifest(photo: "test.jpg", width: Int(size.width), height: Int(size.height), cases: entries, error: nil), to: folder)
    }

    /// The picture a case starts from: the test photo, or one made from it so colour tools have
    /// something to work on.
    /// - "warm": the test photo with a strong warm cast (white balance, match colour).
    /// - "negative": an orange-masked colour negative of the test photo (film negative conversion).
    /// - "chart": colour patches (8 hues × 3 shades, then neutrals), for the colour-band tools.
    static func sourceImage(_ source: String?, photo: CIImage) -> CIImage {
        switch source {
        case "warm":
            return photo.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.25, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.7, w: 0),
            ])
        case "negative":
            // On sRGB levels: 1 − x, seen through an orange film base.
            let encoded = photo.applyingFilter("CILinearToSRGBToneCurve")
            let negative = encoded.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -0.95, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: -0.62, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -0.38, w: 0),
                "inputBiasVector": CIVector(x: 0.95, y: 0.62, z: 0.38, w: 0),
            ])
            return negative.applyingFilter("CISRGBToneCurveToLinear").cropped(to: photo.extent)
        case "chart":
            return chart(size: photo.extent.integral.size)
        default:
            return photo
        }
    }

    /// Hues of the chart's columns: red, orange, yellow, green, aqua, blue, purple, magenta.
    static let chartHues: [CGFloat] = [0, 30, 60, 120, 180, 240, 270, 300]

    /// 9 columns (the 8 hues, then neutrals) × 4 rows (bright, mid, dark shades; then a grey ramp).
    static func chart(size: CGSize) -> CIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let columns = chartHues.count + 1, rows = 4
            let w = size.width / CGFloat(columns), h = size.height / CGFloat(rows)
            let shades: [(s: CGFloat, b: CGFloat)] = [(0.85, 0.9), (0.6, 0.65), (0.9, 0.4)]
            for col in 0..<columns {
                for row in 0..<rows {
                    let color: UIColor
                    if row == 3 {
                        color = UIColor(white: CGFloat(col) / CGFloat(columns - 1), alpha: 1)
                    } else if col == columns - 1 {
                        color = UIColor(white: [0.95, 0.5, 0.1][row], alpha: 1)
                    } else {
                        color = UIColor(hue: chartHues[col] / 360, saturation: shades[row].s, brightness: shades[row].b, alpha: 1)
                    }
                    color.setFill()
                    ctx.fill(CGRect(x: CGFloat(col) * w, y: CGFloat(row) * h, width: w + 1, height: h + 1))
                }
            }
        }
        guard let cg = picture.cgImage else { return CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size)) }
        return CIImage(cgImage: cg)
    }

    /// Core Image filters whose parameter ranges we rely on; their attributes on this iOS version
    /// go to filters.txt (reports/ci/gallery/filters.txt on the laptop).
    static let filtersToDescribe = ["CIHighlightShadowAdjust", "CIColorCurves", "CIAreaHistogram", "CIUnsharpMask",
                                    "CIVibrance", "CIHueAdjust", "CIColorCubeWithColorSpace", "CIMorphologyGradient",
                                    "CIMorphologyMinimum", "CIDissolveTransition", "CIBlendWithMask"]

    private static func writeFilterAttributes(to folder: URL) {
        var text = ""
        for name in filtersToDescribe {
            guard let filter = CIFilter(name: name) else {
                text += "\(name): not available\n\n"
                continue
            }
            text += "\(name)\n"
            for key in filter.inputKeys {
                let attributes = (filter.attributes[key] as? [String: Any]) ?? [:]
                let shown = attributes
                    .filter { ["CIAttributeDefault", "CIAttributeMin", "CIAttributeMax", "CIAttributeSliderMin",
                               "CIAttributeSliderMax", "CIAttributeIdentity"].contains($0.key) }
                    .map { "\($0.key.replacingOccurrences(of: "CIAttribute", with: "")) \($0.value)" }
                    .sorted()
                text += "  \(key): \(shown.joined(separator: ", "))\n"
            }
            text += "\n"
        }
        try? Data(text.utf8).write(to: folder.appendingPathComponent("filters.txt"))
    }

    /// The manifest is written last (and atomically): the cloud build waits for it.
    private static func write(_ manifest: Manifest, to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }
}

/// Shown while the gallery renders; quits the app when done.
struct RenderGalleryView: View {
    var body: some View {
        Text("Rendering the test gallery…")
            .task {
                await RenderGallery.run()
                exit(0)
            }
    }
}
