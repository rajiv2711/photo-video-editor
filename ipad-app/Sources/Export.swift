import CommandEngine
import CoreImage
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Export panel's settings, read from its controls (see ExportSettings in CommandEngine).
struct ExportOptions {
    /// "jpeg", "png", "heic", "tiff", "avif" or "dng".
    var format = "jpeg"
    /// 0…1 (JPEG, HEIC, AVIF).
    var quality = 0.9
    var longEdge = 0.0
    var percent = 100.0
    /// "off", "screen", "matte", "glossy"; and "low", "standard", "high".
    var sharpening = "off"
    var sharpenAmount = "standard"
    /// "all", "copyright", "none".
    var metadata = "all"
    var removeLocation = false
    /// "original", "edited", "date", "custom".
    var naming = "original"
    /// "srgb", "displayP3", "adobeRGB", "proPhoto": the profile the file is in (embedded).
    var colorSpace = "srgb"
    /// 8 or 16 bits per channel (as far as the format allows).
    var bits = 8
}

/// A photo exported: the file's bytes, its type, its name, and what was changed to make it ("AVIF can't
/// be written here: JPEG instead"), if anything.
struct ExportedFile {
    let data: Data
    let type: String
    let name: String
    let note: String?
}

/// Turns the edited photo into a file (ImageIO), with the metadata PhotoMetadata gives (camera data,
/// title, caption, keywords, copyright, place), and reads an exported file back (the render gallery
/// checks what was written).
enum Exporter {
    /// The file types ImageIO can write on this iPad.
    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// Whether an export format ("avif", …) can be written here.
    static func isWritable(_ format: String) -> Bool {
        ExportSettings.types[format].map { writableTypes.contains($0) } ?? false
    }

    /// The export formats this iPad can write, in the Export Format control's order.
    static var writableFormats: [String] { ExportSettings.formats.filter(isWritable) }

    /// The picture as exported: made smaller to the export size (Lanczos, as the preview), then sharpened
    /// for its medium (on sRGB levels, as Lightroom's output sharpening).
    static func prepare(_ edited: CIImage, options: ExportOptions) -> CIImage {
        var out = edited
        let e = edited.extent
        let scale = ExportSettings.scale(width: Double(e.width), height: Double(e.height), longEdge: options.longEdge, percent: options.percent)
        if scale < 0.999 {
            out = edited.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            let r = out.extent
            out = out.cropped(to: CGRect(x: r.minX.rounded(.up), y: r.minY.rounded(.up),
                                         width: (r.width).rounded(.down), height: (r.height).rounded(.down)))
        }
        let side = Double(max(out.extent.width, out.extent.height))
        if let sharp = ExportSettings.sharpening(medium: options.sharpening, amount: options.sharpenAmount, longSide: side) {
            out = Filters.linear(Filters.unsharp(Filters.encoded(out), radius: sharp.radius, intensity: sharp.amount, extent: out.extent))
        }
        return out
    }

    /// The colour space an output colour space id stands for (sRGB when unknown).
    static func colorSpace(_ id: String) -> CGColorSpace {
        let name: CFString
        switch id {
        case "displayP3": name = CGColorSpace.displayP3
        case "adobeRGB": name = CGColorSpace.adobeRGB1998
        case "proPhoto": name = CGColorSpace.rommrgb
        default: name = CGColorSpace.sRGB
        }
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// The picture as a file of `type` ("public.jpeg", …) with `properties` (ImageIO's keys) written in, its
    /// colours in `space` (its ICC profile embedded) at `bits` per channel: 16 (PNG, TIFF), 10 (HEIC) or 8.
    static func encode(_ image: CIImage, context: CIContext, type: String = UTType.jpeg.identifier, quality: Double = 0.92,
                       properties: [String: Any], space: CGColorSpace? = nil, bits: Int = 8) -> Data? {
        let space = space ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if bits == 10, type == UTType.heic.identifier {
            // 10-bit HEIF, its metadata from the picture's properties.
            let options: [CIImageRepresentationOption: Any] = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
            return try? context.heif10Representation(of: image.settingProperties(properties), colorSpace: space, options: options)
        }
        guard let cg = context.createCGImage(image, from: image.extent.integral, format: bits > 8 ? .RGBA16 : .RGBA8, colorSpace: space) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(destination, cg, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// What an exported file holds, as text (the render gallery's manifest fields): its type, size, bits
    /// per channel, colour profile, resolution, and the metadata written (camera, date, place, title,
    /// caption, keywords, copyright).
    static func readBack(_ data: Data) -> [String: String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return ["export.type": "unreadable"] }
        let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let exif = p["{Exif}"] as? [String: Any] ?? [:]
        let tiff = p["{TIFF}"] as? [String: Any] ?? [:]
        let iptc = p["{IPTC}"] as? [String: Any] ?? [:]
        func text(_ any: Any?) -> String {
            switch any {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            case let list as [String]: return list.joined(separator: ", ")
            default: return ""
            }
        }
        return [
            "export.type": (CGImageSourceGetType(source) as String?) ?? "",
            "export.bytes": String(data.count),
            "export.width": text(p["PixelWidth"]),
            "export.height": text(p["PixelHeight"]),
            "export.depth": text(p["Depth"]),
            "export.profile": text(p["ProfileName"]),
            "export.dpi": text(p["DPIWidth"]),
            "export.orientation": text(p["Orientation"]),
            "export.make": text(tiff["Make"]),
            "export.date": text(exif["DateTimeOriginal"]),
            "export.gps": p["{GPS}"] == nil ? "no" : "yes",
            "export.title": text(iptc["ObjectName"]),
            "export.caption": text(iptc["Caption/Abstract"]),
            "export.keywords": text(iptc["Keywords"]),
            "export.copyright": text(iptc["CopyrightNotice"]),
            "export.writable": writableFormats.joined(separator: ","),
        ]
    }
}

/// An exported photo as a document, for Save To Files (the Files app's save dialog).
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.image] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The system share sheet (AirDrop, Messages, Mail, other apps…) for an exported file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
