import Foundation

// Export (Export panel), as Lightroom's Export dialog: the file format and quality, the size (long edge
// or percent, never enlarging), output sharpening for the screen or paper, which metadata goes along, and
// how the file is named. The settings are controls of the "export" group: how the user works, not part of
// a photo's edit, so they stay from photo to photo (see Workflow.isSetting).

/// Export maths and names, shared by the iPad and the Linux tests.
public enum ExportSettings {
    /// File formats, as the options of Export Format (controls.json), and their ImageIO types. The app
    /// offers only those ImageIO can write on the iPad (AVIF and DNG depend on the iPadOS version).
    public static let formats = ["jpeg", "png", "heic", "tiff", "avif", "dng"]
    public static let types = ["jpeg": "public.jpeg", "png": "public.png", "heic": "public.heic", "tiff": "public.tiff", "avif": "public.avif",
                               "dng": "com.adobe.raw-image"]
    public static let extensions = ["jpeg": "jpg", "png": "png", "heic": "heic", "tiff": "tif", "avif": "avif", "dng": "dng"]

    /// Output sharpening media and amounts, as the options of Output Sharpening and its amount.
    public static let media = ["off", "screen", "matte", "glossy"]
    public static let amounts = ["low", "standard", "high"]

    /// Which metadata goes along: everything, the copyright only, or none.
    public static let metadata = ["all", "copyright", "none"]

    /// File naming schemes, as the options of File Naming.
    public static let namings = ["original", "edited", "date", "custom"]

    /// The option id a choice control's value picks ("jpeg" for 0), or the first.
    public static func option(_ list: [String], _ value: Double) -> String {
        let i = Int(value)
        return list.indices.contains(i) ? list[i] : list[0]
    }

    /// The scale an export is made at: to fit `longEdge` pixels on the long side (0: as edited) and at
    /// `percent` % (100: as edited), whichever is smaller; never larger than the edited photo.
    public static func scale(width: Double, height: Double, longEdge: Double, percent: Double) -> Double {
        var s = 1.0
        let side = Swift.max(width, height)
        if longEdge > 0, side > 0 { s = Swift.min(s, longEdge / side) }
        if percent > 0, percent < 100 { s = Swift.min(s, percent / 100) }
        return s
    }

    /// Output sharpening for a medium and amount on a picture of `longSide` pixels: an unsharp mask's
    /// radius (pixels) and amount, as Lightroom's: a fine, light one for screens; for paper wider (the
    /// ink spreads), strongest on matte, which softens most; nil when off.
    public static func sharpening(medium: String, amount: String, longSide: Double) -> (radius: Double, amount: Double)? {
        let strength: Double
        switch amount {
        case "low": strength = 0.6
        case "high": strength = 1.5
        default: strength = 1
        }
        // Prints of more pixels are bigger or finer: the radius follows the size (a 3000 px print is 1).
        let paper = Swift.min(2, Swift.max(0.7, longSide / 3000))
        switch medium {
        case "screen": return (0.6, 0.5 * strength)
        case "glossy": return (1.0 * paper, 0.6 * strength)
        case "matte": return (1.5 * paper, 0.8 * strength)
        default: return nil
        }
    }

    /// The exported file's name: the original's (without its extension), with "-edit" after it, the date
    /// and a sequence number ("2026-11-21-007"), or the custom words and a sequence number ("Trip-007").
    public static func fileName(original: String, naming: String, custom: String, date: Date, sequence: Int, ext: String) -> String {
        var base = (original as NSString).deletingPathExtension
        if base.isEmpty { base = "Photo" }
        let number = String(format: "%03d", sequence)
        let name: String
        switch naming {
        case "edited":
            name = base + "-edit"
        case "date":
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            let p = calendar.dateComponents([.year, .month, .day], from: date)
            name = String(format: "%04d-%02d-%02d-", p.year ?? 0, p.month ?? 0, p.day ?? 0) + number
        case "custom":
            let words = custom.trimmingCharacters(in: .whitespaces)
            name = (words.isEmpty ? "Photo" : words) + "-" + number
        default:
            name = base
        }
        // No characters file systems refuse.
        let safe = name.map { "/\\:?*\"<>|".contains($0) ? "-" : $0 }
        return String(safe) + "." + ext
    }

    /// The metadata an export carries, from all of it (`PhotoMetadata.properties`): everything, only the
    /// copyright (and its resolution and orientation), or nothing but those.
    public static func filtered(_ properties: [String: Any], keep: String) -> [String: Any] {
        switch keep {
        case "copyright":
            var out: [String: Any] = [:]
            for key in ["Orientation", "DPIWidth", "DPIHeight"] { out[key] = properties[key] }
            if let copyright = (properties["{IPTC}"] as? [String: Any])?["CopyrightNotice"] {
                out["{IPTC}"] = ["CopyrightNotice": copyright]
                out["{TIFF}"] = ["Copyright": copyright, "Orientation": 1]
            }
            return out
        case "none":
            var out: [String: Any] = [:]
            for key in ["Orientation", "DPIWidth", "DPIHeight"] { out[key] = properties[key] }
            return out
        default:
            return properties
        }
    }

    /// The built-in export presets: Web (JPEG 80, 2048 px, screen sharpening, copyright only, no
    /// location), Instagram (JPEG 90, 1080 px), Print (TIFF, full size, glossy paper sharpening, all
    /// metadata), Full Size JPEG (95) and Lossless PNG.
    public static func builtInPresets() -> [Preset] {
        func i(_ list: [String], _ id: String) -> Double { Double(list.firstIndex(of: id) ?? 0) }
        func preset(_ name: String, _ values: [String: Double]) -> Preset {
            Preset(name: name, pack: "Export", groups: ["export"], values: values)
        }
        return [
            preset("Web", ["exportFormat": i(formats, "jpeg"), "exportQuality": 80, "exportLongEdge": 2048,
                           "outputSharpening": i(media, "screen"), "exportMetadata": i(metadata, "copyright"), "removeLocation": 1]),
            preset("Instagram", ["exportFormat": i(formats, "jpeg"), "exportQuality": 90, "exportLongEdge": 1080,
                                 "outputSharpening": i(media, "screen"), "exportMetadata": i(metadata, "copyright"), "removeLocation": 1]),
            preset("Print", ["exportFormat": i(formats, "tiff"), "outputSharpening": i(media, "glossy")]),
            preset("Full Size JPEG", ["exportFormat": i(formats, "jpeg"), "exportQuality": 95]),
            preset("Lossless PNG", ["exportFormat": i(formats, "png")]),
        ]
    }
}

/// A rectangle in points (1/72 inch), from the top-left of the paper.
public struct PrintRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Print (Export panel): where the photo goes on the paper. A print size (4 × 6 in, …, A4, or the whole
/// page), turned to match the photo, inside the printer's printable area less the margins (made smaller
/// when it doesn't fit), in the middle; the photo fits inside it whole, or fills it (cut to its shape).
public enum PrintLayout {
    /// The Print Size options (controls.json) and their sizes in inches (short side, long side); "page":
    /// as large as the page allows.
    public static let sizes = ["page", "4x6", "5x7", "8x10", "a5", "a4"]
    static let inches: [String: (Double, Double)] = ["4x6": (4, 6), "5x7": (5, 7), "8x10": (8, 10), "a5": (5.83, 8.27), "a4": (8.27, 11.69)]

    /// The photo's place on the paper (`frame`, points from the paper's top-left) and the part of the photo
    /// shown there (`crop`, shares of its width and height from its top-left: all of it unless filling).
    public static func place(printable: PrintRect, marginMM: Double, size: String, fill: Bool, photoAspect: Double) -> (frame: PrintRect, crop: PrintRect) {
        let margin = Swift.max(0, marginMM) * 72 / 25.4
        let area = PrintRect(x: printable.x + margin, y: printable.y + margin,
                             width: Swift.max(1, printable.width - 2 * margin), height: Swift.max(1, printable.height - 2 * margin))
        var box = area
        if let (short, long) = inches[size] {
            // Turned as the photo is (a landscape photo prints on a landscape box), shrunk to fit.
            var w = (photoAspect >= 1 ? long : short) * 72, h = (photoAspect >= 1 ? short : long) * 72
            let k = Swift.min(1, area.width / w, area.height / h)
            w *= k
            h *= k
            box = PrintRect(x: area.x + (area.width - w) / 2, y: area.y + (area.height - h) / 2, width: w, height: h)
        }
        let all = PrintRect(x: 0, y: 0, width: 1, height: 1)
        let boxAspect = box.width / box.height
        if fill {
            // The photo's middle, cut to the box's shape.
            if photoAspect > boxAspect {
                let share = boxAspect / photoAspect
                return (box, PrintRect(x: (1 - share) / 2, y: 0, width: share, height: 1))
            }
            let share = photoAspect / boxAspect
            return (box, PrintRect(x: 0, y: (1 - share) / 2, width: 1, height: share))
        }
        // The whole photo, as large as the box allows.
        var w = box.width, h = box.width / photoAspect
        if h > box.height {
            h = box.height
            w = h * photoAspect
        }
        return (PrintRect(x: box.x + (box.width - w) / 2, y: box.y + (box.height - h) / 2, width: w, height: h), all)
    }
}
