import CommandEngine
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Turns the edited photo into a file (ImageIO), with the metadata PhotoMetadata gives (camera data,
/// title, caption, keywords, copyright, place), and reads an exported file back (the render gallery
/// checks what was written).
enum Exporter {
    /// The picture as a file of `type` ("public.jpeg", …) with `properties` (ImageIO's keys) written in.
    static func encode(_ image: CIImage, context: CIContext, type: String = UTType.jpeg.identifier, quality: Double = 0.92,
                       properties: [String: Any]) -> Data? {
        guard let cg = context.createCGImage(image, from: image.extent.integral) else { return nil }
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
        ]
    }
}
