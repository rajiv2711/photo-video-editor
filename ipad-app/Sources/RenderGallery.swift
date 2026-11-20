import CoreImage
import SwiftUI
import UIKit

/// Cloud-build test mode, started with the launch argument `-renderGallery`.
///
/// For every case in `gallery.json` (test-data/gallery/) it starts from the untouched test photo
/// (about 800 px), runs the case's command through the same interpreter and renderer as the editor,
/// and writes `Documents/gallery/<id>.jpg` plus `manifest.json`. Then the app quits.
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
        let model = EditorModel(image: small, previewSide: longSide)
        var entries: [Entry] = []
        for item in cases {
            model.startOver()
            if !item.command.isEmpty {
                model.run(item.command)
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

    /// Core Image filters whose parameter ranges we rely on; their attributes on this iOS version
    /// go to filters.txt (reports/ci/gallery/filters.txt on the laptop).
    static let filtersToDescribe = ["CIHighlightShadowAdjust", "CIColorCurves", "CIAreaHistogram", "CIUnsharpMask"]

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
