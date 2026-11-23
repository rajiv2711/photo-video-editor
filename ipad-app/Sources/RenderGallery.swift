import CommandEngine
import CoreImage
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Cloud-build test mode, started with the launch argument `-renderGallery`.
///
/// For every case in `gallery.json` (test-data/gallery/) it starts from the untouched test photo
/// (about 800 px), or a picture generated from it (`source`), runs the case's command through the
/// same interpreter and renderer as the editor, draws its strokes and taps the photo if it has
/// them, and writes `Documents/gallery/<id>.jpg` plus `manifest.json`. Then the app quits.
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
        /// Measure only this box of the pictures: x0, y0, x1, y1 from the top-left, 0…1 (masks).
        let region: [Double]?
        /// metric "field": a manifest field (see `Entry.fields`) and the value it must have.
        let field: String?
        let value: String?
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
        /// Lines drawn on the photo after the command (brush strokes, lasso outlines, gradient drags):
        /// each a list of x, y points from the top-left, 0…1.
        let strokes: [[[Double]]]?
        /// More commands, strokes and taps, in order, after the strokes ("eraser", then a stroke).
        let steps: [Step]?
        /// Pictures picked for merging before the command (generated, see `sourceImage`), in order.
        let photos: [String]?
        /// A Live Photo to edit: its photo, then its video's frames (generated, see `sourceImage`).
        let live: [String]?
        /// What to save instead of the edited photo: "overlay", the preview with the View panel's
        /// overlays, as the screen shows it; "batch", the first picture Batch Edit made; "export", the
        /// file the photo is exported as, read back (its details go into the manifest's fields); "print",
        /// the A4 page as it prints (where the photo goes, in the fields).
        let view: String?
        /// Pictures imported into an empty library before the command (generated, see `sourceImage`),
        /// with the capture times and places of `libraryImport`; the first one is opened.
        let library: [String]?
    }

    /// One step: a command, a stroke, a tap, or a photo opened (generated, see `sourceImage`).
    struct Step: Codable {
        let command: String?
        let stroke: [[Double]]?
        let tap: [Double]?
        let open: String?
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
        /// Library and export details (photo count, the photo's place, an exported file's format…).
        let fields: [String: String]
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
        // Each editor keeps its library in a folder of its own, emptied for every case.
        func newEditor(_ source: String?) -> EditorModel {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-library-" + UUID().uuidString, isDirectory: true)
            let made = EditorModel(image: sourceImage(source, photo: small), previewSide: longSide, libraryFolder: folder)
            made.waitsForRetouch = true
            made.waitsForMerge = true
            made.showsPreview = false  // only the final picture of each case is saved
            made.keepsPresets = false  // each case starts with no presets of its own
            made.keepsLibrary = false  // and an empty library
            made.exportsFiles = false  // nothing goes to Photos or Files
            made.cropSlidersShowCropTool = false  // crop sliders crop the render (no crop tool on screen)
            return made
        }
        // One editor per starting picture, made when a case first needs it.
        var models: [String: EditorModel] = [:]
        func editor(for source: String?) -> EditorModel {
            let key = source ?? "photo"
            if let existing = models[key] { return existing }
            let made = newEditor(source)
            if source == "portrait" { made.useDepth(disparity: portraitDepth(small)) }
            models[key] = made
            return made
        }
        var entries: [Entry] = []
        for item in cases {
            // A case that opens another photo gets an editor of its own (the shared one keeps its photo).
            let opens = item.steps?.contains { $0.open != nil } ?? false || item.library != nil
            let model = opens ? newEditor(item.source) : editor(for: item.source)
            model.startOver()
            if let photos = item.photos {
                model.pickForMerge(photos.map { sourceImage($0, photo: small) })
            }
            if let library = item.library {
                model.importPictures(library.enumerated().compactMap { libraryImport($0.element, index: $0.offset, photo: small) })
            }
            if let live = item.live, live.count >= 2 {
                let pictures = live.map { sourceImage($0, photo: small) }
                model.useLive(LiveFrames(still: pictures[0], frames: Array(pictures.dropFirst())))
            }
            if !item.command.isEmpty {
                model.run(item.command)
            }
            for stroke in item.strokes ?? [] {
                model.draw(stroke.filter { $0.count == 2 }.map { MaskPoint($0[0], $0[1]) })
            }
            for step in item.steps ?? [] {
                if let command = step.command { model.run(command) }
                if let stroke = step.stroke { model.draw(stroke.filter { $0.count == 2 }.map { MaskPoint($0[0], $0[1]) }) }
                if let tap = step.tap, tap.count == 2 { model.tap(atX: tap[0], y: tap[1]) }
                if let name = step.open { model.open(sourceImage(name, photo: small)) }
            }
            if let tap = item.tap, tap.count == 2 {
                model.tap(atX: tap[0], y: tap[1])
            }
            // "overlay": what the screen shows (before / after, warnings, grids…); "batch": a batch picture.
            var edited = item.view == "overlay" ? model.shownPreview() : model.editedPreview()
            if item.view == "batch", let first = model.lastBatch.first { edited = first }
            var fields = model.galleryFields()
            if item.view == "print" {
                // The page as it prints: A4 (595 × 842 points, a pixel each), 18 points the printer can't reach.
                let page = PhotoPrinter.preview(model.printPicture(), paper: CGSize(width: 595, height: 842),
                                                printable: CGRect(x: 18, y: 18, width: 559, height: 806), setup: model.printSetup)
                edited = page.page
                fields["print.x"] = String(Int(page.frame.x.rounded()))
                fields["print.y"] = String(Int(page.frame.y.rounded()))
                fields["print.width"] = String(Int(page.frame.width.rounded()))
                fields["print.height"] = String(Int(page.frame.height.rounded()))
            }
            if item.view == "export" {
                // The exported file itself, and its pixels and details as read back.
                if let exported = model.exportFile() {
                    let ext = UTType(exported.type)?.preferredFilenameExtension ?? "bin"
                    try? exported.data.write(to: folder.appendingPathComponent("\(item.id).export.\(ext)"))
                    if let decoded = LibraryStore.decode(exported.data) { edited = decoded.image }
                    fields.merge(Exporter.readBack(exported.data)) { _, new in new }
                    fields["export.name"] = exported.name
                    if let note = exported.note { fields["export.note"] = note }
                } else {
                    fields["export.type"] = "failed"
                }
            }
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
                peak: model.renderer.peak(of: edited),
                fields: fields
            ))
        }
        writeFilterAttributes(to: folder)
        let size = small.extent.integral.size
        write(Manifest(photo: "test.jpg", width: Int(size.width), height: Int(size.height), cases: entries, error: nil), to: folder)
    }

    /// Seconds after 2026-11-21 10:00 (UTC) at which the library's generated photos were taken, in import
    /// order: three a second apart (a burst), two more a minute later, then one every five minutes.
    static let libraryTimes: [Double] = [0, 1, 2, 60, 61, 300, 600, 900]

    /// A generated picture as a JPEG file to import, with EXIF saying when it was taken (`libraryTimes`)
    /// and, for every other one (the 1st, 3rd, …), where: 51.50° N, 0.12° W, then 0.01° further north-west each.
    static func libraryImport(_ source: String, index: Int, photo: CIImage) -> LibraryImport? {
        // The camera raw is imported as the file it is.
        if source == "raw" {
            return rawData.map { LibraryImport(data: $0, name: "test.dng", asset: nil) }
        }
        let picture = sourceImage(source, photo: photo)
        let context = CIContext()
        guard let cg = context.createCGImage(picture, from: picture.extent.integral) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil),
              let start = PhotoMetadata.date("2026:11:21 10:00:00") else { return nil }
        let taken = start.addingTimeInterval(libraryTimes[index % libraryTimes.count] + Double(index / libraryTimes.count) * 3600)
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: PhotoMetadata.exifText(taken)] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Gallery", kCGImagePropertyTIFFModel: "Test Camera"] as [CFString: Any],
        ]
        if index % 2 == 0 {
            let step = 0.01 * Double(index / 2)
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 51.5 + step, kCGImagePropertyGPSLatitudeRef: "N",
                                                        kCGImagePropertyGPSLongitude: 0.12 + step, kCGImagePropertyGPSLongitudeRef: "W"] as [CFString: Any]
        }
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return LibraryImport(data: data as Data, name: source + ".jpg", asset: nil)
    }

    /// The bundled camera raw (test-data/raw/test.dng, made by dev-tools/make_dng.py): 320 × 240, four
    /// upright bands (red, green, blue, grey) darkening downwards, its camera's white balance D65 (≈ 6500 K).
    static var rawData: Data? {
        Bundle.main.url(forResource: "test", withExtension: "dng").flatMap { try? Data(contentsOf: $0) }
    }

    /// The picture a case starts from: the test photo, or one made from it so colour tools have
    /// something to work on.
    /// - "warm": the test photo with a strong warm cast (white balance, match colour).
    /// - "negative": an orange-masked colour negative of the test photo (film negative conversion).
    /// - "chart": colour patches (8 hues × 3 shades, then neutrals), for the colour-band tools.
    /// - "haze": the test photo seen through a bluish-grey haze (dehaze).
    /// - "noise": the test photo with strong brightness and colour noise (noise reduction).
    /// - "moire": the test photo with fine magenta and green stripes over it (moiré removal).
    /// - "grid": soft dark lines every 40 px on light grey (the optics tools bend and fringe them).
    /// - "lens": the grid, with EXIF saying it was shot on a Canon EF-S 18-55mm at 18 mm, f/3.5
    ///   (a lens in the bundled profiles), for Lens Profile Correction.
    /// - "lateral-ca": the grid with red spread 0.4 % wider than green and blue 0.4 % narrower
    ///   (red/cyan and blue/yellow fringes towards the corners), for chromatic aberration.
    /// - "fringe": bright lines on dark (the grid inverted) with red and blue more blurred than green:
    ///   purple fringes outside the lines, green inside (defringe).
    /// - "fisheye": the grid as a 120° fisheye lens would show it (fisheye correction).
    /// - "dust": the test photo with five dark dust spots on the background (radius 7 px, at
    ///   `dustSpots`) and a thin dark wire across the top (retouching).
    /// - "red-eye": two eyes on skin, their pupils flash-red (red eye).
    /// - "pet-eye": two animal eyes on dark fur, their pupils glowing pale green (pet eye).
    /// - "tilted": the grid turned 6° anticlockwise, filling the frame (straighten).
    /// - "building": the grid seen looking up, its upright lines leaning in towards the top (upright).
    /// - "skewed": the colour chart as a tilted page on a dark table (perspective crop), its corners at
    ///   `skewedCorners`.
    /// - "bracket-dark", "bracket-mid", "bracket-bright": the test photo as the scene of an exposure
    ///   bracket, at ½, 2 and 8 × its light (clipped at white), for HDR merge; "bracket-ghost": the dark
    ///   one with a pale disc passing over the lens (at `ghostDisc`), for deghosting.
    /// - "pano-left", "pano-middle", "pano-right": overlapping crops of the test photo (60 % of its width,
    ///   92 % of its height, each a little higher or lower, at 0.9, 1 and 1.1 × its light), for panoramas.
    /// - "hdrpano-left-dark" … "hdrpano-right-bright": "pano-left" and "pano-right" as the dark, mid and
    ///   bright brackets (for HDR panorama).
    /// - "focus-top", "focus-bottom": the test photo sharp in its top or bottom half only (focus stacking).
    /// - "burst-1" … "burst-4": the test photo with its own noise each and a dark disc passing along
    ///   the top (stack averaging; see `burst`).
    /// - "live-0" … "live-7": a Live Photo's photo and frames: the test photo with a little camera
    ///   shake and a dark disc crossing the top (see `liveFrame`).
    /// - "raw": the bundled camera raw (`rawData`), decoded as the library decodes raws.
    /// - "portrait": the lens of the test photo in front of the soft grid, with a made-up depth map
    ///   (`portraitDepth`: the lens near, the grid far, a little nearer towards the bottom).
    static func sourceImage(_ source: String?, photo: CIImage) -> CIImage {
        if source == "raw" {
            return rawData.flatMap { LibraryStore.decode($0)?.image } ?? photo
        }
        if let source, source.hasPrefix("hdrpano-") {
            let parts = source.split(separator: "-")
            guard parts.count == 3 else { return photo }
            let bracket = sourceImage("bracket-" + String(parts[2]), photo: photo)
            return sourceImage("pano-" + String(parts[1]), photo: bracket)
        }
        if let source, source.hasPrefix("burst-"), let n = Int(source.dropFirst(6)), (1...4).contains(n) {
            return burst(photo, frame: n)
        }
        if let source, source.hasPrefix("live-"), let n = Int(source.dropFirst(5)), liveShake.indices.contains(n) {
            return liveFrame(photo, n)
        }
        switch source {
        case "portrait":
            // The lens (the subject) in front of the soft grid.
            guard let grid = softGrid(size: photo.extent.integral.size) else { return photo }
            let background = CIImage(cgImage: grid).transformed(by: CGAffineTransform(translationX: photo.extent.minX, y: photo.extent.minY))
            return Filters.blend(photo, over: background, mask: portraitSubject(photo)).cropped(to: photo.extent)
        case "focus-top", "focus-bottom":
            // Sharp above or below the middle, blurred (3 px) on the other side, with a soft change.
            let e = photo.extent
            let blurred = photo.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: e)
            let sharpTop = source == "focus-top"
            let mask = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: e.midX, y: e.minY + 0.45 * e.height),
                "inputPoint1": CIVector(x: e.midX, y: e.minY + 0.55 * e.height),
                "inputColor0": sharpTop ? CIColor(red: 0, green: 0, blue: 0) : CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": sharpTop ? CIColor(red: 1, green: 1, blue: 1) : CIColor(red: 0, green: 0, blue: 0),
            ])?.outputImage?.cropped(to: e)
            guard let mask else { return photo }
            return Filters.blend(photo, over: blurred, mask: mask)
        case "pano-left", "pano-middle", "pano-right":
            // x0, y0 from the top-left (shares), and the light.
            let parts: [String: (x: CGFloat, y: CGFloat, gain: Double)] = ["pano-left": (0, 0.04, 0.9), "pano-middle": (0.2, 0, 1),
                                                                         "pano-right": (0.4, 0.08, 1.1)]
            let part = parts[source ?? ""] ?? (0, 0, 1)
            let e = photo.extent
            let box = CGRect(x: e.minX + (part.x * e.width).rounded(), y: e.minY + ((1 - part.y - 0.92) * e.height).rounded(),
                             width: (0.6 * e.width).rounded(), height: (0.92 * e.height).rounded())
            let lit = Filters.affine(photo, scale: part.gain).applyingFilter("CIColorClamp")
            return lit.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        case "bracket-dark", "bracket-mid", "bracket-bright", "bracket-ghost":
            let gains: [String: Double] = ["bracket-mid": 2, "bracket-bright": 8]
            let gain = gains[source ?? ""] ?? 0.5
            let bracket = Filters.affine(photo, scale: gain).applyingFilter("CIColorClamp").cropped(to: photo.extent)
            guard source == "bracket-ghost" else { return bracket }
            let size = photo.extent.size
            let centre = CGPoint(x: ghostDisc.x * size.width, y: (1 - ghostDisc.y) * size.height)
            let disc = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(cgPoint: centre),
                "inputRadius0": ghostDisc.r * size.width,
                "inputRadius1": ghostDisc.r * size.width + 1,
                "inputColor0": CIColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            ])?.outputImage
            return disc.map { $0.composited(over: bracket).cropped(to: photo.extent) } ?? bracket
        case "skewed":
            let size = photo.extent.integral.size
            func corner(_ i: Int) -> CIVector {
                CIVector(x: skewedCorners[i].x * size.width, y: (1 - skewedCorners[i].y) * size.height)
            }
            let page = chart(size: size).applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": corner(0), "inputTopRight": corner(1), "inputBottomRight": corner(2), "inputBottomLeft": corner(3),
            ])
            let table = CIImage(color: CIColor(red: 0.03, green: 0.03, blue: 0.035)).cropped(to: CGRect(origin: .zero, size: size))
            return page.composited(over: table).cropped(to: CGRect(origin: .zero, size: size))
        case "building":
            // A grid twice the size, its top 30 % narrower on each side, cut from the middle.
            let size = photo.extent.integral.size
            guard let grid = softGrid(size: CGSize(width: 2 * size.width, height: 2 * size.height)) else { return photo }
            let big = CIImage(cgImage: grid)
            let w = 2 * size.width, h = 2 * size.height, inset = 0.3 * w
            let leaning = big.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(x: inset, y: h),
                "inputTopRight": CIVector(x: w - inset, y: h),
                "inputBottomRight": CIVector(x: w, y: 0),
                "inputBottomLeft": CIVector(x: 0, y: 0),
            ])
            return leaning.cropped(to: CGRect(x: size.width / 2, y: size.height / 2, width: size.width, height: size.height))
                .transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2))
        case "tilted":
            let size = photo.extent.integral.size
            guard let grid = softGrid(size: size) else { return photo }
            let image = CIImage(cgImage: grid)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let turn = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: 6 * .pi / 180).scaledBy(x: 1.3, y: 1.3)
                .translatedBy(x: -c.x, y: -c.y)
            return image.clampedToExtent().transformed(by: turn).cropped(to: image.extent)
        case "dust":
            return dusty(photo)
        case "red-eye", "pet-eye":
            return eyes(size: photo.extent.integral.size, pet: source == "pet-eye")
        case "fringe":
            // High contrast, as where real fringes show: the sharp grid inverted (bright lines on dark).
            guard let grid = gridPicture(size: photo.extent.integral.size) else { return photo }
            let inverted = CIImage(cgImage: grid).applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIColorInvert").applyingFilter("CISRGBToneCurveToLinear")
            let lines = inverted.clampedToExtent().applyingGaussianBlur(sigma: 0.7).cropped(to: inverted.extent)
            let spread = inverted.clampedToExtent().applyingGaussianBlur(sigma: 2.5).cropped(to: inverted.extent)
            let redBlue = spread.applyingFilter("CIColorMatrix", parameters: [
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            let greenOnly = lines.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            return redBlue.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: greenOnly])
        case "grid", "lens", "lateral-ca", "fisheye":
            let size = photo.extent.integral.size
            guard let grid = softGrid(size: size) else { return photo }
            switch source {
            case "lens":
                let exif: [String: Any] = ["LensModel": "EF-S18-55mm f/3.5-5.6 IS STM", "FocalLength": 18, "FNumber": 3.5]
                let tiff: [String: Any] = ["Make": "Canon", "Model": "Canon EOS 250D"]
                return CIImage(cgImage: grid, options: [.properties: ["{Exif}": exif, "{TIFF}": tiff]])
            case "lateral-ca":
                let fringes = LensWarp(redScale: 1 / 1.004, blueScale: 1 / 0.996)
                return OpticsRenderer.remap(CIImage(cgImage: grid), fringes, context: context)
            case "fisheye":
                return OpticsRenderer.remap(CIImage(cgImage: grid), LensWarp(fisheye: -1), context: context)
            default:
                return CIImage(cgImage: grid)
            }
        case "moire":
            // White/black stripes turned into magenta/green levels around mid-grey, then overlaid.
            let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0),
                "inputWidth": 2,
                "inputSharpness": 0.5,
            ])?.outputImage
            guard let stripes else { return photo }
            let layer = stripes.transformed(by: CGAffineTransform(rotationAngle: 0.3)).cropped(to: photo.extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.24, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: -0.24, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0.24, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.38, y: 0.62, z: 0.38, w: 0),
                ])
            let striped = layer.applyingFilter("CIOverlayBlendMode", parameters: [
                kCIInputBackgroundImageKey: photo.applyingFilter("CILinearToSRGBToneCurve"),
            ])
            return striped.applyingFilter("CISRGBToneCurveToLinear").cropped(to: photo.extent)
        case "noise":
            // Independent random levels per channel, ±17 % around mid-grey, overlaid on sRGB levels.
            guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return photo }
            let area = photo.extent
            let layer = random.cropped(to: area).settingAlphaOne(in: area).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.35, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.35, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.35, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.325, y: 0.325, z: 0.325, w: 0),
            ])
            let noisy = layer.applyingFilter("CIOverlayBlendMode", parameters: [
                kCIInputBackgroundImageKey: photo.applyingFilter("CILinearToSRGBToneCurve"),
            ])
            return noisy.applyingFilter("CISRGBToneCurveToLinear").cropped(to: area)
        case "haze":
            // On sRGB levels: 55 % of the photo + 45 % haze colour.
            let encoded = photo.applyingFilter("CILinearToSRGBToneCurve")
            let hazy = encoded.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0),
                "inputBiasVector": CIVector(x: 0.38, y: 0.40, z: 0.43, w: 0),
            ])
            return hazy.applyingFilter("CISRGBToneCurveToLinear").cropped(to: photo.extent)
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

    /// For making the generated pictures.
    private static let context = CIContext()

    /// Eyes at (0.35, 0.42) and (0.65, 0.42): red-eye pupils (radius 2.5 % of the width) in brown
    /// irises on skin, or glowing pupils (3.5 %) in yellow-green irises on dark fur.
    static func eyes(size: CGSize, pet: Bool) -> CIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            (pet ? UIColor(red: 0.3, green: 0.25, blue: 0.2, alpha: 1) : UIColor(red: 0.87, green: 0.68, blue: 0.58, alpha: 1)).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let w = size.width
            for x in [0.35, 0.65] as [CGFloat] {
                let centre = CGPoint(x: x * w, y: 0.42 * size.height)
                func disc(_ radius: CGFloat, _ color: UIColor) {
                    color.setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
                }
                if pet {
                    disc(0.06 * w, UIColor(red: 0.6, green: 0.65, blue: 0.2, alpha: 1))
                    disc(0.035 * w, UIColor(red: 0.75, green: 1, blue: 0.7, alpha: 1))
                } else {
                    UIColor(white: 0.95, alpha: 1).setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: centre.x - 0.09 * w, y: centre.y - 0.035 * size.height,
                                                         width: 0.18 * w, height: 0.07 * size.height))
                    disc(0.045 * w, UIColor(red: 0.45, green: 0.3, blue: 0.2, alpha: 1))
                    disc(0.025 * w, UIColor(red: 0.85, green: 0.12, blue: 0.1, alpha: 1))
                }
            }
        }
        guard let cg = picture.cgImage else { return CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size)) }
        return CIImage(cgImage: cg)
    }

    /// The "skewed" page's corners (x, y from the top-left, 0…1): top-left, top-right, bottom-right, bottom-left.
    static let skewedCorners: [(x: CGFloat, y: CGFloat)] = [(0.18, 0.12), (0.86, 0.20), (0.80, 0.88), (0.12, 0.80)]

    /// Where the lens is in the test photo: its dark body, with the holes (bright glass, lettering) closed.
    static func portraitSubject(_ photo: CIImage) -> CIImage {
        let e = photo.extent
        let dark = Filters.lookup(Filters.luma(Filters.encoded(photo)), table: Effects.table(count: 256) { $0 < 0.35 ? 1 : 0 })
        let closed = Filters.lookup(Filters.blurred(dark, radius: 10, extent: e), table: Effects.table(count: 256) { $0 > 0.25 ? 1 : 0 })
        return Filters.blurred(closed, radius: 1.5, extent: e)
    }

    /// The "portrait" picture's disparity (bigger = nearer): the lens 1, the grid 0.1 at the top to 0.3 at the bottom.
    static func portraitDepth(_ photo: CIImage) -> CIImage {
        let e = photo.extent
        let floor = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: e.midX, y: e.maxY),
            "inputPoint1": CIVector(x: e.midX, y: e.minY),
            "inputColor0": CIColor(red: 0.1, green: 0.1, blue: 0.1),
            "inputColor1": CIColor(red: 0.3, green: 0.3, blue: 0.3),
        ])?.outputImage?.cropped(to: e) ?? CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: e)
        let near = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: e)
        return Filters.blend(near, over: floor, mask: portraitSubject(photo))
    }

    /// The camera shake of "live-0" … "live-7" (pixels right and down).
    static let liveShake: [(x: CGFloat, y: CGFloat)] = [(0, 0), (1, -1), (2, 0), (-1, 1), (2, 2), (0, -2), (-2, 1), (1, 1)]

    /// Frame `n` of the generated Live Photo: the photo moved by `liveShake[n]` (edges repeated) with a
    /// dark disc (radius 4 % of the width) at x = 0.1 + 0.1 n, y = 0.1 from the top-left.
    static func liveFrame(_ photo: CIImage, _ n: Int) -> CIImage {
        let area = photo.extent
        let shake = liveShake[n]
        let moved = photo.clampedToExtent().transformed(by: CGAffineTransform(translationX: shake.x, y: -shake.y)).cropped(to: area)
        let centre = CGPoint(x: area.minX + (0.1 + 0.1 * CGFloat(n)) * area.width, y: area.minY + 0.9 * area.height)
        let disc = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(cgPoint: centre),
            "inputRadius0": 0.04 * area.width,
            "inputRadius1": 0.04 * area.width + 1,
            "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])?.outputImage
        return disc.map { $0.composited(over: moved).cropped(to: area) } ?? moved
    }

    /// Where the dark disc of "burst-1" … "burst-4" is (x, y from the top-left; radius a share of the width).
    static let burstDiscs: [(x: CGFloat, y: CGFloat)] = [(0.15, 0.12), (0.4, 0.12), (0.6, 0.12), (0.85, 0.12)]
    static let burstRadius: CGFloat = 0.05

    /// One frame of a burst: the photo with noise (±8 %, a different patch of random numbers per frame)
    /// and a dark disc at its own place.
    static func burst(_ photo: CIImage, frame: Int) -> CIImage {
        let area = photo.extent
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return photo }
        let moved = random.transformed(by: CGAffineTransform(translationX: CGFloat(frame * 117), y: CGFloat(frame * 53)))
        let layer = moved.cropped(to: area).settingAlphaOne(in: area).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.16, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.16, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.16, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.42, y: 0.42, z: 0.42, w: 0),
        ])
        let noisy = layer.applyingFilter("CIOverlayBlendMode", parameters: [
            kCIInputBackgroundImageKey: photo.applyingFilter("CILinearToSRGBToneCurve"),
        ]).applyingFilter("CISRGBToneCurveToLinear").cropped(to: area)
        let spot = burstDiscs[frame - 1]
        let centre = CGPoint(x: area.minX + spot.x * area.width, y: area.minY + (1 - spot.y) * area.height)
        let disc = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(cgPoint: centre),
            "inputRadius0": burstRadius * area.width,
            "inputRadius1": burstRadius * area.width + 1,
            "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])?.outputImage
        return disc.map { $0.composited(over: noisy).cropped(to: area) } ?? noisy
    }

    /// The pale disc in "bracket-ghost" (centre x, y from the top-left and radius, shares of the width and height).
    static let ghostDisc: (x: CGFloat, y: CGFloat, r: CGFloat) = (0.45, 0.55, 0.06)

    /// Where the "dust" picture's spots are (x, y from the top-left, 0…1).
    static let dustSpots: [(x: CGFloat, y: CGFloat)] = [(0.12, 0.10), (0.85, 0.12), (0.88, 0.55), (0.10, 0.70), (0.75, 0.90)]

    /// The photo with dark, soft dust spots and a wire from (0.03, 0.045) to (0.97, 0.075).
    static func dusty(_ photo: CIImage) -> CIImage {
        let size = photo.extent.integral.size
        guard let cg = context.createCGImage(photo, from: photo.extent) else { return photo }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            let space = CGColorSpaceCreateDeviceRGB()
            let dark = { (alpha: CGFloat) in UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: alpha).cgColor }
            let colors = [dark(0.6), dark(0.6), dark(0)] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) {
                for spot in dustSpots {
                    let centre = CGPoint(x: spot.x * size.width, y: spot.y * size.height)
                    ctx.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 7,
                                                     options: [])
                }
            }
            ctx.cgContext.setStrokeColor(UIColor(white: 0.2, alpha: 1).cgColor)
            ctx.cgContext.setLineWidth(2)
            ctx.cgContext.move(to: CGPoint(x: 0.03 * size.width, y: 0.045 * size.height))
            ctx.cgContext.addLine(to: CGPoint(x: 0.97 * size.width, y: 0.075 * size.height))
            ctx.cgContext.strokePath()
        }
        guard let out = picture.cgImage else { return photo }
        return CIImage(cgImage: out)
    }

    /// The grid, softened a little (1 px) like the edges in a real photo.
    static func softGrid(size: CGSize) -> CGImage? {
        guard let sharp = gridPicture(size: size) else { return nil }
        let image = CIImage(cgImage: sharp)
        let soft = image.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: image.extent)
        return context.createCGImage(soft, from: image.extent)
    }

    /// Light grey with dark 2 px lines every 40 px.
    static func gridPicture(size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.8, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.15, alpha: 1).setFill()
            var x: CGFloat = 20
            while x < size.width {
                ctx.fill(CGRect(x: x - 1, y: 0, width: 2, height: size.height))
                x += 40
            }
            var y: CGFloat = 20
            while y < size.height {
                ctx.fill(CGRect(x: 0, y: y - 1, width: size.width, height: 2))
                y += 40
            }
        }.cgImage
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
                                    "CIMorphologyMinimum", "CIDissolveTransition", "CIBlendWithMask", "CIBloom",
                                    "CIMedianFilter", "CIRandomGenerator", "CIMotionBlur", "CIZoomBlur", "CIPixellate", "CICrystallize", "CICMYKHalftone"]

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
