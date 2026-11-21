import CommandEngine
import CoreImage
import SwiftUI
import UIKit

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
    }

    /// One step: a command, a stroke or a tap.
    struct Step: Codable {
        let command: String?
        let stroke: [[Double]]?
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
            made.waitsForRetouch = true
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
            for stroke in item.strokes ?? [] {
                model.draw(stroke.filter { $0.count == 2 }.map { MaskPoint($0[0], $0[1]) })
            }
            for step in item.steps ?? [] {
                if let command = step.command { model.run(command) }
                if let stroke = step.stroke { model.draw(stroke.filter { $0.count == 2 }.map { MaskPoint($0[0], $0[1]) }) }
                if let tap = step.tap, tap.count == 2 { model.tap(atX: tap[0], y: tap[1]) }
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
    static func sourceImage(_ source: String?, photo: CIImage) -> CIImage {
        switch source {
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
                                    "CIMedianFilter", "CIRandomGenerator"]

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
