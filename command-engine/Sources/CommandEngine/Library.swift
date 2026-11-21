import Foundation

// The library (Library panel), as Lightroom's catalog: every photo imported, kept by the app in a file in
// its own container, each with its own edit, so going back to a photo finds it as it was left. A photo's
// picture stays where it came from: a Photos asset (by its identifier) or a file the app copied in
// (Files, a camera or SD card). The library shows its photos in the order they were taken; a filter
// narrows what it shows, and next / previous photo move through what it shows.

/// Camera data read from a photo's EXIF (see PhotoMetadata).
public struct CameraInfo: Codable, Equatable {
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Double?
    /// Seconds (1/250 s is 0.004).
    public var exposureTime: Double?
    /// The f-number.
    public var aperture: Double?
    /// Millimetres.
    public var focalLength: Double?
    /// Exposure compensation in stops (brackets differ in it).
    public var exposureBias: Double?
    public var width: Int?
    public var height: Int?

    public init(make: String? = nil, model: String? = nil, lens: String? = nil, iso: Double? = nil, exposureTime: Double? = nil,
                aperture: Double? = nil, focalLength: Double? = nil, exposureBias: Double? = nil, width: Int? = nil, height: Int? = nil) {
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.exposureTime = exposureTime
        self.aperture = aperture
        self.focalLength = focalLength
        self.exposureBias = exposureBias
        self.width = width
        self.height = height
    }
}

/// One photo of the library.
public struct LibraryPhoto: Codable, Equatable, Identifiable {
    public var id: String
    /// Its picture: a Photos asset's local identifier, or a file in the app's library folder.
    public var asset: String?
    public var file: String?
    /// The name it was imported under ("IMG_0001.HEIC").
    public var name: String
    public var added: Date
    /// When it was taken (EXIF), if the file says.
    public var captured: Date?
    /// Stars, 0…5.
    public var rating = 0
    /// 1 = pick, −1 = rejected, 0 = neither.
    public var flag = 0
    /// A colour label's id ("red", …; see Library.labels), "" for none.
    public var label = ""
    public var keywords: [String] = []
    public var title = ""
    public var caption = ""
    public var copyright = ""
    public var camera = CameraInfo()
    public var latitude: Double?
    public var longitude: Double?
    /// The stack it is in (photos with the same id are one stack), nil for none.
    public var stack: String?
    /// Its own edit, kept when another photo is opened (nil: never edited).
    public var edit: EditState?

    public init(id: String, asset: String? = nil, file: String? = nil, name: String, added: Date, captured: Date? = nil) {
        self.id = id
        self.asset = asset
        self.file = file
        self.name = name
        self.added = added
        self.captured = captured
    }

    /// Every field may be missing (a library file from an older version still loads).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        asset = try c.decodeIfPresent(String.self, forKey: .asset)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date(timeIntervalSince1970: 0)
        captured = try c.decodeIfPresent(Date.self, forKey: .captured)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        flag = try c.decodeIfPresent(Int.self, forKey: .flag) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        copyright = try c.decodeIfPresent(String.self, forKey: .copyright) ?? ""
        camera = try c.decodeIfPresent(CameraInfo.self, forKey: .camera) ?? CameraInfo()
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        stack = try c.decodeIfPresent(String.self, forKey: .stack)
        edit = try c.decodeIfPresent(EditState.self, forKey: .edit)
    }

    /// When it was taken, or else imported: the library's order.
    public var date: Date { captured ?? added }
}

/// What the library shows (all photos when every part is at its default).
public struct LibraryFilter: Codable, Equatable {
    /// At least this many stars.
    public var minRating = 0
    /// "all", "picks", "rejected" or "unflagged".
    public var flag = "all"
    /// A colour label's id, "" for any.
    public var label = ""
    /// An album's name, "" for all photos.
    public var album = ""
    /// A keyword the photos have, "" for any.
    public var keyword = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minRating = try c.decodeIfPresent(Int.self, forKey: .minRating) ?? 0
        flag = try c.decodeIfPresent(String.self, forKey: .flag) ?? "all"
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword) ?? ""
    }

    public var isEmpty: Bool { self == LibraryFilter() }
}

/// A named group of photos (by id, in the order they were added).
public struct Album: Codable, Equatable {
    public var name: String
    public var photos: [String]

    public init(name: String, photos: [String] = []) {
        self.name = name
        self.photos = photos
    }
}

/// Something the library did, for the feedback line (and the app: a photo to show).
public enum LibraryEvent: Equatable {
    /// Nothing has been imported yet.
    case empty
    /// A photo was opened: its id, its place among the photos shown (from 1) and how many are shown.
    case opened(id: String, index: Int, count: Int)
    /// "photo 3" alone, for the photo being edited: its place and how many are shown.
    case at(index: Int, count: Int)
    /// "photo 40" when fewer are shown.
    case noPhoto(Int)
    /// Next at the last photo shown (true), previous at the first (false).
    case end(next: Bool)
    /// The library panel was asked for: how many photos it shows and holds.
    case browsed(shown: Int, total: Int)
    /// Rating, flag or colour label asked for while no library photo is being edited.
    case notInLibrary
    /// The photo being edited got this many stars (0…5).
    case rated(Int)
    /// …this flag (1 pick, −1 rejected, 0 none).
    case flagged(Int)
    /// …this colour label ("" none).
    case labelled(String)
    /// The filter changed: how many photos it shows of how many.
    case filtered(shown: Int, total: Int)
}

/// The photos imported, the albums, the filter, and the photo being edited.
public struct Library: Codable, Equatable {
    public var photos: [LibraryPhoto] = []
    public var albums: [Album] = []
    public var filter = LibraryFilter()
    /// The photo being edited (nil: none of the library's, e.g. the bundled test photo).
    public var current: String?
    /// Stacks show all their photos (true) or only the top one.
    public var stacksExpanded = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photos = try c.decodeIfPresent([LibraryPhoto].self, forKey: .photos) ?? []
        albums = try c.decodeIfPresent([Album].self, forKey: .albums) ?? []
        filter = try c.decodeIfPresent(LibraryFilter.self, forKey: .filter) ?? LibraryFilter()
        current = try c.decodeIfPresent(String.self, forKey: .current)
        stacksExpanded = try c.decodeIfPresent(Bool.self, forKey: .stacksExpanded) ?? false
    }

    /// The library's actions (run by the workspace, in order with the other commands).
    public static let actions: Set<String> = ["openPhoto", "nextPhoto", "previousPhoto", "browseLibrary",
                                              "rate", "pick", "reject", "unflag", "colorLabel",
                                              "showRating", "showPicks", "showRejects", "showUnflagged", "showLabel", "showAllPhotos"]

    /// Colour labels, as the options of Label (controls.json; Show Label adds "any").
    public static let labels = ["red", "yellow", "green", "blue", "purple"]

    /// The flag filters ("show picks", …).
    public static let flagFilters = ["all", "picks", "rejected", "unflagged"]

    /// Whether a photo passes the filter.
    public func matches(_ photo: LibraryPhoto) -> Bool {
        guard photo.rating >= filter.minRating else { return false }
        switch filter.flag {
        case "picks": if photo.flag != 1 { return false }
        case "rejected": if photo.flag != -1 { return false }
        case "unflagged": if photo.flag != 0 { return false }
        default: break
        }
        if !filter.label.isEmpty, photo.label != filter.label { return false }
        if !filter.album.isEmpty {
            guard let album = albums.first(where: { Presets.normalized($0.name) == Presets.normalized(filter.album) }),
                  album.photos.contains(photo.id) else { return false }
        }
        if !filter.keyword.isEmpty, !photo.keywords.contains(where: { Presets.normalized($0) == Presets.normalized(filter.keyword) }) {
            return false
        }
        return true
    }

    public func photo(_ id: String?) -> LibraryPhoto? {
        guard let id else { return nil }
        return photos.first { $0.id == id }
    }

    /// Every photo, in the order they were taken (or imported, for those that don't say).
    public var ordered: [LibraryPhoto] {
        photos.enumerated().sorted { a, b in
            a.element.date != b.element.date ? a.element.date < b.element.date : a.offset < b.offset
        }.map(\.element)
    }

    /// The photos the library shows (those the filter lets through), in order.
    public var shown: [LibraryPhoto] {
        ordered.filter(matches)
    }

    /// The photo being edited's place among those shown (from 1), or nil when it isn't shown.
    public var currentIndex: Int? {
        shown.firstIndex { $0.id == current }.map { $0 + 1 }
    }

    /// Adds a photo (imported).
    public mutating func add(_ photo: LibraryPhoto) {
        photos.append(photo)
    }

    /// Keeps an edit with its photo.
    public mutating func store(_ edit: EditState, for id: String) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].edit = edit
    }

    /// The photo `step` places after the one being edited among those shown (−1: the one before); when
    /// the photo being edited isn't shown, the first shown (or the last, going back).
    public func neighbour(_ step: Int) -> String? {
        let list = shown
        guard !list.isEmpty else { return nil }
        guard let i = list.firstIndex(where: { $0.id == current }) else { return (step > 0 ? list.first : list.last)?.id }
        let j = i + step
        return list.indices.contains(j) ? list[j].id : nil
    }

    /// Runs one library action: what it did, and the photo to open, if it asks for one.
    public mutating func run(_ command: Command) -> (events: [LibraryEvent], open: String?) {
        guard let id = command.control else { return ([], nil) }
        let list = shown
        switch id {
        case "openPhoto":
            guard !photos.isEmpty else { return ([.empty], nil) }
            // "photo 3": the third shown; "photo" alone says which one this is.
            guard let n = command.value.map({ Int($0) }) else {
                return ([.at(index: currentIndex ?? 0, count: list.count)], nil)
            }
            guard list.indices.contains(n - 1) else { return ([.noPhoto(n)], nil) }
            return ([.opened(id: list[n - 1].id, index: n, count: list.count)], list[n - 1].id)
        case "nextPhoto", "previousPhoto":
            guard !photos.isEmpty else { return ([.empty], nil) }
            let forward = id == "nextPhoto"
            guard let target = neighbour(forward ? 1 : -1) else { return ([.end(next: forward)], nil) }
            let index = (list.firstIndex { $0.id == target } ?? 0) + 1
            return ([.opened(id: target, index: index, count: list.count)], target)
        case "browseLibrary":
            return ([.browsed(shown: list.count, total: photos.count)], nil)
        case "rate", "pick", "reject", "unflag", "colorLabel":
            guard let i = photos.firstIndex(where: { $0.id == current }) else { return ([.notInLibrary], nil) }
            switch id {
            case "rate":
                // "rate 4"; "rate" alone says the rating.
                if let v = command.value { photos[i].rating = Swift.min(5, Swift.max(0, Int(v.rounded()))) }
                return ([.rated(photos[i].rating)], nil)
            case "colorLabel":
                // An option of Label: a colour, or none (the last).
                let n = command.value.map { Int($0) } ?? 0
                photos[i].label = Self.labels.indices.contains(n) ? Self.labels[n] : ""
                return ([.labelled(photos[i].label)], nil)
            default:
                photos[i].flag = id == "pick" ? 1 : id == "reject" ? -1 : 0
                return ([.flagged(photos[i].flag)], nil)
            }
        case "showRating":
            filter.minRating = Swift.min(5, Swift.max(0, Int((command.value ?? 0).rounded())))
        case "showPicks":
            filter.flag = "picks"
        case "showRejects":
            filter.flag = "rejected"
        case "showUnflagged":
            filter.flag = "unflagged"
        case "showLabel":
            // A colour, or any (the last option).
            let n = command.value.map { Int($0) } ?? Self.labels.count
            filter.label = Self.labels.indices.contains(n) ? Self.labels[n] : ""
        case "showAllPhotos":
            filter = LibraryFilter()
        default:
            return ([], nil)
        }
        // A filter changed.
        return ([.filtered(shown: shown.count, total: photos.count)], nil)
    }
}

/// Reading a photo's metadata (the properties ImageIO gives, as a dictionary) into the library's fields.
public enum PhotoMetadata {
    /// EXIF dates: "2026:11:21 10:00:05" (local time, as cameras write it; read as UTC so it never shifts).
    public static func date(_ text: String?) -> Date? {
        guard let text, text.count >= 19 else { return nil }
        let digits = text.prefix(19).split(whereSeparator: { ": -T".contains($0) }).compactMap { Int($0) }
        guard digits.count == 6, digits[0] > 1900 else { return nil }
        var parts = DateComponents()
        parts.year = digits[0]
        parts.month = digits[1]
        parts.day = digits[2]
        parts.hour = digits[3]
        parts.minute = digits[4]
        parts.second = digits[5]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar.date(from: parts)
    }

    /// A date as EXIF writes it ("2026:11:21 10:00:05", the inverse of `date`).
    public static func exifText(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        return "\(p.year ?? 0):\(two(p.month)):\(two(p.day)) \(two(p.hour)):\(two(p.minute)):\(two(p.second))"
    }

    /// A number in a properties dictionary (NSNumber, Double, Int or text).
    static func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let f as Float: return Double(f)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// The fields a photo's properties fill in (`properties`: ImageIO's, with "{Exif}", "{TIFF}", "{GPS}",
    /// "{IPTC}" dictionaries): when it was taken, the camera, where, and the words it carries.
    public static func read(_ properties: [String: Any], into photo: inout LibraryPhoto) {
        let exif = properties["{Exif}"] as? [String: Any] ?? [:]
        let tiff = properties["{TIFF}"] as? [String: Any] ?? [:]
        let gps = properties["{GPS}"] as? [String: Any] ?? [:]
        let iptc = properties["{IPTC}"] as? [String: Any] ?? [:]
        photo.captured = date(exif["DateTimeOriginal"] as? String) ?? date(exif["DateTimeDigitized"] as? String)
            ?? date(tiff["DateTime"] as? String) ?? photo.captured
        var camera = CameraInfo()
        camera.make = (tiff["Make"] as? String)?.trimmingCharacters(in: .whitespaces)
        camera.model = (tiff["Model"] as? String)?.trimmingCharacters(in: .whitespaces)
        camera.lens = exif["LensModel"] as? String
        camera.iso = (exif["ISOSpeedRatings"] as? [Any])?.first.flatMap(number) ?? number(exif["ISOSpeedRatings"])
        camera.exposureTime = number(exif["ExposureTime"])
        camera.aperture = number(exif["FNumber"])
        camera.focalLength = number(exif["FocalLength"])
        camera.exposureBias = number(exif["ExposureBiasValue"])
        camera.width = number(properties["PixelWidth"]).map { Int($0) }
        camera.height = number(properties["PixelHeight"]).map { Int($0) }
        photo.camera = camera
        if let lat = number(gps["Latitude"]), let lon = number(gps["Longitude"]) {
            photo.latitude = (gps["LatitudeRef"] as? String)?.uppercased() == "S" ? -abs(lat) : abs(lat)
            photo.longitude = (gps["LongitudeRef"] as? String)?.uppercased() == "W" ? -abs(lon) : abs(lon)
        }
        if let words = iptc["Keywords"] as? [String] { photo.keywords = words }
        if let title = iptc["ObjectName"] as? String { photo.title = title }
        if let caption = (iptc["Caption/Abstract"] as? String) ?? (tiff["ImageDescription"] as? String) { photo.caption = caption }
        if let copyright = (iptc["CopyrightNotice"] as? String) ?? (tiff["Copyright"] as? String) { photo.copyright = copyright }
    }
}
