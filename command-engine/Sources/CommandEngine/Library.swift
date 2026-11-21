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
    /// An album was made (New Album; Add To Album with a new name).
    case albumMade(String)
    /// The photo being edited went into an album (or was in it already).
    case addedToAlbum(String)
    case removedFromAlbum(String)
    /// Remove From Album: the photo isn't in that album.
    case notInAlbum(String)
    case albumDeleted(String)
    /// New Album with a name an album has.
    case albumExists(String)
    /// No album has that name ("" when none was said).
    case noAlbum(String)
    /// Several albums fit the words: their names.
    case albumChoices(word: String, names: [String])
    /// "album" alone: the albums' names.
    case albums([String])
    /// Keywords given to the photo being edited (those it didn't have yet).
    case keywordsAdded([String])
    case keywordRemoved(String)
    /// Remove Keyword: the photo hasn't that keyword.
    case noKeyword(String)
    /// "keywords" alone: the photo's keywords.
    case keywords([String])
    /// Title, Caption or Copyright ("title", "caption", "copyright") set (or said, when no words came).
    case described(field: String, value: String)
    /// Photo Info: the camera data of the photo being edited (the app says it).
    case info
    /// Photos selected in the browser (Select Photo, Clear Selection): how many now.
    case selected(Int)
    /// Stack These made a stack of this many photos.
    case stacked(Int)
    /// Stack These with fewer than two photos to stack.
    case nothingToStack
    /// Auto Stack: how many stacks it made, of how many photos, with what gap (seconds).
    case autoStacked(stacks: Int, photos: Int, gap: Double)
    /// Unstack: the stack of the photo being edited is undone (its photos), or it was in none (0).
    case unstacked(Int)
    /// Stacks show all their photos (true) or only the top one.
    case stacksExpanded(Bool)
    /// The map: how many of the photos shown say where they were taken.
    case mapShown(located: Int, shown: Int)
    /// Export Name: the words exported files are named after (File Naming "custom").
    case exportNamed(String)
}

/// The part of the world a map shows: its middle and how far it reaches (degrees).
public struct MapRegion: Equatable {
    public var latitude: Double
    public var longitude: Double
    public var latitudeSpan: Double
    public var longitudeSpan: Double
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
    /// Photos taken at most this many seconds apart are a burst (Auto Stack, Stack These).
    public var stackGap = 2.0
    /// Photos selected in the browser, in the order they were selected.
    public var selected: [String] = []
    /// Export Name's words, and how many photos were exported (the next file's sequence number is one more).
    public var exportName = ""
    public var exportCount = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photos = try c.decodeIfPresent([LibraryPhoto].self, forKey: .photos) ?? []
        albums = try c.decodeIfPresent([Album].self, forKey: .albums) ?? []
        filter = try c.decodeIfPresent(LibraryFilter.self, forKey: .filter) ?? LibraryFilter()
        current = try c.decodeIfPresent(String.self, forKey: .current)
        stacksExpanded = try c.decodeIfPresent(Bool.self, forKey: .stacksExpanded) ?? false
        stackGap = try c.decodeIfPresent(Double.self, forKey: .stackGap) ?? 2
        selected = try c.decodeIfPresent([String].self, forKey: .selected) ?? []
        exportName = try c.decodeIfPresent(String.self, forKey: .exportName) ?? ""
        exportCount = try c.decodeIfPresent(Int.self, forKey: .exportCount) ?? 0
    }

    /// The library's actions (run by the workspace, in order with the other commands).
    public static let actions: Set<String> = ["openPhoto", "nextPhoto", "previousPhoto", "browseLibrary",
                                              "rate", "pick", "reject", "unflag", "colorLabel",
                                              "showRating", "showPicks", "showRejects", "showUnflagged", "showLabel", "showAllPhotos",
                                              "newAlbum", "addToAlbum", "removeFromAlbum", "album", "deleteAlbum",
                                              "addKeyword", "removeKeyword", "showKeyword", "photoTitle", "photoCaption", "photoCopyright", "photoInfo",
                                              "selectPhoto", "clearSelection", "stackThese", "autoStack", "unstack", "expandStacks", "collapseStacks",
                                              "showMap", "exportName"]

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

    /// The photos the library shows (those the filter lets through), in order; a collapsed stack shows
    /// one photo: the one being edited when it is in it, else its first (its top).
    public var shown: [LibraryPhoto] {
        let passing = ordered.filter(matches)
        guard !stacksExpanded else { return passing }
        var top: [String: String] = [:]
        for photo in passing {
            if let stack = photo.stack, top[stack] == nil || photo.id == current { top[stack] = photo.id }
        }
        return passing.filter { photo in photo.stack.map { top[$0] == photo.id } ?? true }
    }

    /// The photos shown that say where they were taken (GPS), for the map.
    public var located: [LibraryPhoto] {
        shown.filter { $0.latitude != nil && $0.longitude != nil }
    }

    /// The region that holds every photo on the map, with a margin (at least about 1 km across); nil
    /// when none says where it was taken.
    public var mapRegion: MapRegion? {
        let points = located.compactMap { p in p.latitude.flatMap { lat in p.longitude.map { (lat, $0) } } }
        guard let first = points.first else { return nil }
        var lat = (first.0, first.0), lon = (first.1, first.1)
        for (a, b) in points {
            lat = (Swift.min(lat.0, a), Swift.max(lat.1, a))
            lon = (Swift.min(lon.0, b), Swift.max(lon.1, b))
        }
        return MapRegion(latitude: (lat.0 + lat.1) / 2, longitude: (lon.0 + lon.1) / 2,
                         latitudeSpan: Swift.min(170, Swift.max(0.01, (lat.1 - lat.0) * 1.4)),
                         longitudeSpan: Swift.min(360, Swift.max(0.01, (lon.1 - lon.0) * 1.4)))
    }

    /// How many photos are in the photo's stack (1: in none).
    public func stackCount(of id: String) -> Int {
        guard let stack = photo(id)?.stack else { return 1 }
        return photos.filter { $0.stack == stack }.count
    }

    /// The stacks, as their photos' ids in order.
    public var stacks: [[String]] {
        var out: [String: [String]] = [:]
        var order: [String] = []
        for photo in ordered {
            guard let stack = photo.stack else { continue }
            if out[stack] == nil { order.append(stack) }
            out[stack, default: []].append(photo.id)
        }
        return order.compactMap { out[$0] }
    }

    /// The burst a photo belongs to: it and the photos taken at most `gap` seconds before or after the one
    /// next to them (dated photos only), in order.
    public func burst(around id: String, gap: Double) -> [String] {
        let dated = ordered.filter { $0.captured != nil }
        guard let i = dated.firstIndex(where: { $0.id == id }) else { return [id] }
        var lo = i, hi = i
        while lo > 0, dated[lo].date.timeIntervalSince(dated[lo - 1].date) <= gap { lo -= 1 }
        while hi < dated.count - 1, dated[hi + 1].date.timeIntervalSince(dated[hi].date) <= gap { hi += 1 }
        return dated[lo...hi].map(\.id)
    }

    /// Makes one stack of these photos (out of any stack they were in).
    mutating func stack(_ ids: [String]) {
        guard let first = ids.first else { return }
        for i in photos.indices where ids.contains(photos[i].id) { photos[i].stack = "stack:" + first }
        tidyStacks()
    }

    /// A stack left with one photo is no stack.
    mutating func tidyStacks() {
        for group in stacks where group.count < 2 {
            for i in photos.indices where photos[i].id == group.first { photos[i].stack = nil }
        }
    }

    /// Auto Stack: every run of photos taken at most `gap` seconds apart becomes a stack (bursts,
    /// brackets); stacks made before are undone. Returns the stacks made.
    mutating func autoStack(gap: Double) -> [[String]] {
        for i in photos.indices { photos[i].stack = nil }
        var groups: [[String]] = []
        var run: [LibraryPhoto] = []
        for photo in ordered where photo.captured != nil {
            if let last = run.last, photo.date.timeIntervalSince(last.date) <= gap {
                run.append(photo)
            } else {
                if run.count >= 2 { groups.append(run.map(\.id)) }
                run = [photo]
            }
        }
        if run.count >= 2 { groups.append(run.map(\.id)) }
        for group in groups { stack(group) }
        return groups
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
        case "newAlbum", "addToAlbum", "removeFromAlbum", "album", "deleteAlbum":
            return (album(id, words: (command.text ?? "").trimmingCharacters(in: .whitespaces)), nil)
        case "selectPhoto":
            // "select photo 3": the third shown; alone: the photo being edited. Again: deselected.
            var target = current
            if let v = command.value {
                let n = Int(v)
                guard list.indices.contains(n - 1) else { return ([.noPhoto(n)], nil) }
                target = list[n - 1].id
            }
            guard let target, photo(target) != nil else { return ([.notInLibrary], nil) }
            if let i = selected.firstIndex(of: target) { selected.remove(at: i) } else { selected.append(target) }
            return ([.selected(selected.count)], nil)
        case "clearSelection":
            selected = []
            return ([.selected(0)], nil)
        case "stackThese":
            // The photos selected, or else the burst of the photo being edited.
            let ids = !selected.isEmpty ? selected : current.map { burst(around: $0, gap: stackGap) } ?? []
            guard ids.count >= 2 else { return ([.nothingToStack], nil) }
            stack(ids)
            selected = []
            return ([.stacked(ids.count)], nil)
        case "autoStack":
            // "auto stack 5": photos up to 5 seconds apart.
            if let v = command.value, v > 0 { stackGap = v }
            let made = autoStack(gap: stackGap)
            return ([.autoStacked(stacks: made.count, photos: made.reduce(0) { $0 + $1.count }, gap: stackGap)], nil)
        case "unstack":
            guard let id = current, let stack = photo(id)?.stack else { return ([.unstacked(0)], nil) }
            let count = photos.filter { $0.stack == stack }.count
            for i in photos.indices where photos[i].stack == stack { photos[i].stack = nil }
            return ([.unstacked(count)], nil)
        case "expandStacks", "collapseStacks":
            stacksExpanded = id == "expandStacks"
            return ([.stacksExpanded(stacksExpanded)], nil)
        case "showMap":
            return ([.mapShown(located: located.count, shown: list.count)], nil)
        case "exportName":
            if let words = command.text?.trimmingCharacters(in: .whitespaces), !words.isEmpty { exportName = words }
            return ([.exportNamed(exportName)], nil)
        case "showKeyword":
            // No words: any keyword again.
            filter.keyword = (command.text ?? "").trimmingCharacters(in: .whitespaces)
        case "addKeyword", "removeKeyword", "photoTitle", "photoCaption", "photoCopyright", "photoInfo":
            guard let i = photos.firstIndex(where: { $0.id == current }) else { return ([.notInLibrary], nil) }
            return (describe(id, photo: i, words: (command.text ?? "").trimmingCharacters(in: .whitespaces)), nil)
        default:
            return ([], nil)
        }
        // A filter changed.
        return ([.filtered(shown: shown.count, total: photos.count)], nil)
    }
}

extension Library {
    /// The albums the photo is in, by name.
    public func albums(of id: String?) -> [String] {
        albums.filter { album in id.map { album.photos.contains($0) } ?? false }.map(\.name)
    }

    /// The album `words` name (exactly, or a near-miss as control names allow), or what to say instead.
    func findAlbum(_ words: String) -> (index: Int?, problem: LibraryEvent?) {
        let names = albums.map(\.name)
        switch Presets.find(words, names: names) {
        case .found(let i): return (i, nil)
        case .ambiguous(let found): return (nil, .albumChoices(word: words, names: found.map { names[$0] }))
        case .none: return (nil, .noAlbum(words))
        }
    }

    /// Albums: New Album (with the photo being edited in it), Add To Album (made when no album has the
    /// name), Remove From Album (the one shown when no name is said), Album (shows one; alone: their
    /// names), Delete Album (its photos stay in the library).
    mutating func album(_ id: String, words: String) -> [LibraryEvent] {
        let photo = current.flatMap { c in photos.contains { $0.id == c } ? c : nil }
        switch id {
        case "newAlbum":
            let name = words.isEmpty ? "Album \(albums.count + 1)" : words
            if albums.contains(where: { Presets.normalized($0.name) == Presets.normalized(name) }) { return [.albumExists(name)] }
            albums.append(Album(name: name, photos: photo.map { [$0] } ?? []))
            return [.albumMade(name)] + (photo == nil ? [] : [.addedToAlbum(name)])
        case "addToAlbum":
            guard let photo else { return [.notInLibrary] }
            // No name: the album shown. A name no album has: a new album.
            let name = words.isEmpty ? (filter.album.isEmpty ? "Album \(albums.count + 1)" : filter.album) : words
            var events: [LibraryEvent] = []
            let found = findAlbum(name)
            let i: Int
            if let index = found.index {
                i = index
            } else if case .albumChoices? = found.problem {
                return [found.problem ?? .noAlbum(name)]
            } else {
                albums.append(Album(name: name))
                events.append(.albumMade(name))
                i = albums.count - 1
            }
            if !albums[i].photos.contains(photo) { albums[i].photos.append(photo) }
            return events + [.addedToAlbum(albums[i].name)]
        case "removeFromAlbum":
            guard let photo else { return [.notInLibrary] }
            let found = findAlbum(words.isEmpty ? filter.album : words)
            guard let i = found.index else { return [found.problem ?? .noAlbum(words)] }
            guard albums[i].photos.contains(photo) else { return [.notInAlbum(albums[i].name)] }
            albums[i].photos.removeAll { $0 == photo }
            return [.removedFromAlbum(albums[i].name)]
        case "album":
            guard !words.isEmpty else { return [.albums(albums.map(\.name))] }
            let found = findAlbum(words)
            guard let i = found.index else { return [found.problem ?? .noAlbum(words)] }
            filter.album = albums[i].name
            return [.filtered(shown: shown.count, total: photos.count)]
        case "deleteAlbum":
            let found = findAlbum(words.isEmpty ? filter.album : words)
            guard let i = found.index else { return [found.problem ?? .noAlbum(words)] }
            let name = albums.remove(at: i).name
            if Presets.normalized(filter.album) == Presets.normalized(name) { filter.album = "" }
            return [.albumDeleted(name)]
        default:
            return []
        }
    }
}

extension Library {
    /// Keywords said in one go: "beach, sunset and sea" → beach, sunset, sea.
    public static func keywords(in words: String) -> [String] {
        words.replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: ";", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Keywords, title, caption, copyright and info of photo `i`. Title, Caption and Copyright take the
    /// words said ("none" or "clear" clears them; no words: says what it is).
    mutating func describe(_ id: String, photo i: Int, words: String) -> [LibraryEvent] {
        switch id {
        case "addKeyword":
            guard !words.isEmpty else { return [.keywords(photos[i].keywords)] }
            var added: [String] = []
            for word in Self.keywords(in: words)
            where !(photos[i].keywords + added).contains(where: { Presets.normalized($0) == Presets.normalized(word) }) {
                added.append(word)
            }
            photos[i].keywords += added
            return [.keywordsAdded(added)]
        case "removeKeyword":
            guard let k = photos[i].keywords.firstIndex(where: { Presets.normalized($0) == Presets.normalized(words) }) else {
                return [.noKeyword(words)]
            }
            return [.keywordRemoved(photos[i].keywords.remove(at: k))]
        case "photoInfo":
            return [.info]
        default:
            let field = id == "photoTitle" ? "title" : id == "photoCaption" ? "caption" : "copyright"
            if !words.isEmpty {
                let value = ["none", "clear", "off", "nothing"].contains(words.lowercased()) ? "" : words
                switch field {
                case "title": photos[i].title = value
                case "caption": photos[i].caption = value
                default: photos[i].copyright = value
                }
            }
            let now = field == "title" ? photos[i].title : field == "caption" ? photos[i].caption : photos[i].copyright
            return [.described(field: field, value: now)]
        }
    }
}

/// Reading a photo's metadata (the properties ImageIO gives, as a dictionary) into the library's fields,
/// and the metadata a saved or exported photo carries.
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

    /// The metadata an exported photo carries: the original's camera data and date (EXIF, TIFF), its
    /// place (GPS) unless `removeLocation`, and the library's title, caption, keywords and copyright
    /// (IPTC, also the TIFF description and copyright); upright (orientation 1, as the pixels are), with
    /// the resolution in pixels per inch. `original`: ImageIO's properties of the file opened.
    public static func properties(for photo: LibraryPhoto?, original: [String: Any], removeLocation: Bool, ppi: Double) -> [String: Any] {
        var out: [String: Any] = ["Orientation": 1, "DPIWidth": ppi, "DPIHeight": ppi]
        var exif = original["{Exif}"] as? [String: Any] ?? [:]
        // The new picture's own size is written by ImageIO.
        exif["PixelXDimension"] = nil
        exif["PixelYDimension"] = nil
        exif["SubjectArea"] = nil
        if !exif.isEmpty { out["{Exif}"] = exif }
        if let aux = original["{ExifAux}"] { out["{ExifAux}"] = aux }
        var tiff = original["{TIFF}"] as? [String: Any] ?? [:]
        tiff["Orientation"] = 1
        tiff["XResolution"] = ppi
        tiff["YResolution"] = ppi
        tiff["ResolutionUnit"] = 2
        tiff["Software"] = "Editor"
        var iptc = original["{IPTC}"] as? [String: Any] ?? [:]
        if let photo {
            func put(_ value: String, iptc key: String, tiff tiffKey: String? = nil) {
                iptc[key] = value.isEmpty ? nil : value
                if let tiffKey { tiff[tiffKey] = value.isEmpty ? nil : value }
            }
            put(photo.title, iptc: "ObjectName")
            put(photo.caption, iptc: "Caption/Abstract", tiff: "ImageDescription")
            put(photo.copyright, iptc: "CopyrightNotice", tiff: "Copyright")
            iptc["Keywords"] = photo.keywords.isEmpty ? nil : photo.keywords
        }
        out["{TIFF}"] = tiff
        if !iptc.isEmpty { out["{IPTC}"] = iptc }
        if !removeLocation, let gps = original["{GPS}"] { out["{GPS}"] = gps }
        return out
    }

    /// The camera data in one line: "FUJIFILM X-T5 · XF35mmF2 R WR · ISO 400 · 1/250 s · f/2.8 · 35 mm · +1 EV".
    public static func summary(_ camera: CameraInfo) -> String {
        var parts: [String] = []
        let body = [camera.make, camera.model].compactMap { $0 }.joined(separator: " ")
        if !body.isEmpty { parts.append(body) }
        if let lens = camera.lens { parts.append(lens) }
        if let iso = camera.iso { parts.append("ISO \(Int(iso))") }
        if let t = camera.exposureTime { parts.append(shutter(t)) }
        if let f = camera.aperture { parts.append("f/" + Workflow.number(f)) }
        if let mm = camera.focalLength { parts.append(Workflow.number(mm) + " mm") }
        if let ev = camera.exposureBias, ev != 0 { parts.append((ev > 0 ? "+" : "") + Workflow.number(ev) + " EV") }
        return parts.joined(separator: " · ")
    }

    /// An exposure time as cameras show it: 0.004 → "1/250 s", 2 → "2 s".
    public static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds >= 1 { return Workflow.number((seconds * 10).rounded() / 10) + " s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }
}
