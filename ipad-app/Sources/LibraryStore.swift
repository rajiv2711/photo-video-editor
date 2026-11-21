import CommandEngine
import CoreImage
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// What a picture imported into the library is: its bytes, the name it had, and the Photos asset it
/// came from (kept as a reference instead of a copy when the app may read the photo library).
struct LibraryImport {
    let data: Data
    let name: String
    let asset: String?
}

/// Where the library keeps its things, in the app's own container: `library.json` (the catalog, see
/// Library in CommandEngine), `files/` (pictures copied in from Files, a camera or an SD card, and
/// photos from Photos when the app may not read the library) and `thumbs/` (a small picture of each
/// photo for the browser).
final class LibraryStore {
    let folder: URL
    private var thumbnails: [String: UIImage] = [:]

    /// The library of the app (Documents/Library).
    static var standardFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Library", isDirectory: true)
    }

    init(folder: URL = LibraryStore.standardFolder) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)
    }

    var filesFolder: URL { folder.appendingPathComponent("files", isDirectory: true) }
    var thumbsFolder: URL { folder.appendingPathComponent("thumbs", isDirectory: true) }
    var catalogFile: URL { folder.appendingPathComponent("library.json") }

    func read() -> Library {
        guard let data = try? Data(contentsOf: catalogFile) else { return Library() }
        return (try? JSONDecoder().decode(Library.self, from: data)) ?? Library()
    }

    func write(_ library: Library) {
        guard let data = try? JSONEncoder().encode(library) else { return }
        try? data.write(to: catalogFile, options: .atomic)
    }

    // MARK: - Decoding

    /// A picture decoded for editing: upright, with its properties (EXIF, …).
    struct Decoded {
        let image: CIImage
        let properties: [String: Any]
        /// The file's type ("public.jpeg", "public.heic", …).
        let type: String?
    }

    /// The file's type, its properties, and whether it is a camera raw.
    static func describe(_ data: Data) -> (type: String?, properties: [String: Any], isRaw: Bool) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, [:], false) }
        let type = CGImageSourceGetType(source) as String?
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let isRaw = type.flatMap { UTType($0) }.map { $0.conforms(to: .rawImage) } ?? false
        return (type, properties, isRaw)
    }

    /// The picture in a file's bytes, upright.
    static func decode(_ data: Data) -> Decoded? {
        let info = describe(data)
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        return Decoded(image: image, properties: info.properties, type: info.type)
    }

    // MARK: - Adding photos

    /// Adds a picture: its file copied in (unless it stays a Photos asset), its metadata read and a
    /// thumbnail made. Nil when the bytes are no picture.
    func add(_ item: LibraryImport) -> LibraryPhoto? {
        let info = Self.describe(item.data)
        guard info.type != nil, let thumb = Self.thumbnail(of: item.data) else { return nil }
        let id = UUID().uuidString
        var photo = LibraryPhoto(id: id, asset: item.asset, name: item.name, added: Date())
        if item.asset == nil {
            var ext = (item.name as NSString).pathExtension
            if ext.isEmpty { ext = info.type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg" }
            let file = id + "." + ext.lowercased()
            do {
                try item.data.write(to: filesFolder.appendingPathComponent(file), options: .atomic)
            } catch {
                return nil
            }
            photo.file = file
        }
        PhotoMetadata.read(info.properties, into: &photo)
        if let jpeg = UIImage(cgImage: thumb).jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: thumbsFolder.appendingPathComponent(id + ".jpg"), options: .atomic)
        }
        thumbnails[id] = UIImage(cgImage: thumb)
        return photo
    }

    /// A picture about 240 px on its long side, upright.
    static func thumbnail(of data: Data, side: Int = 240) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The browser's small picture of a photo.
    func thumbnail(_ id: String) -> UIImage? {
        if let made = thumbnails[id] { return made }
        let image = UIImage(contentsOfFile: thumbsFolder.appendingPathComponent(id + ".jpg").path)
        thumbnails[id] = image
        return image
    }

    // MARK: - Reading photos back

    /// A photo's bytes: its file, or its Photos asset (nil when it can't be read: deleted, or the app may
    /// no longer read the library).
    func data(for photo: LibraryPhoto) async -> Data? {
        if let file = photo.file {
            return try? Data(contentsOf: filesFolder.appendingPathComponent(file))
        }
        guard let id = photo.asset else { return nil }
        return await Self.assetData(id)
    }

    /// A file's bytes right away (nil for Photos assets, which load in the background).
    func fileData(for photo: LibraryPhoto) -> Data? {
        photo.file.flatMap { try? Data(contentsOf: filesFolder.appendingPathComponent($0)) }
    }

    /// The bytes of a Photos asset (as edited in Photos; from iCloud when needed).
    static func assetData(_ id: String) async -> Data? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The file name a Photos asset was taken under ("IMG_0001.HEIC").
    static func assetName(_ id: String) -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    /// Whether photos picked in Photos can stay there (the app may read the whole library); asks once.
    static func mayReferenceAssets() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return status == .authorized
    }
}
