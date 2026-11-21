import XCTest
@testable import CommandEngine

/// Library and Export: the library's photos (import order, capture order, opening, next / previous,
/// each photo's own edit), ratings, flags, labels, albums, keywords, metadata, stacks, the map, the
/// camera, and the export settings.
final class LibraryTests: XCTestCase {
    private var registry: ControlRegistry!
    private var parser: CommandParser!
    private var interpreter: CommandInterpreter!
    private var state: EditState!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        parser = CommandParser(registry: registry)
        interpreter = CommandInterpreter(registry: registry)
        state = EditState()
    }

    private func parse(_ text: String) -> [Command] {
        parser.parse(text)
    }

    @discardableResult
    private func run(_ text: String) -> [CommandOutcome] {
        interpreter.interpret(text, state: &state)
    }

    private func value(_ id: String) -> Double {
        state.value(of: registry.control(id: id)!)
    }

    private func events(_ outcomes: [CommandOutcome]) -> [LibraryEvent] {
        outcomes.compactMap { if case .workflow(.library(let e)) = $0 { return e } else { return nil } }
    }

    /// A photo taken `seconds` after 2026-11-21 10:00 (UTC).
    private func photo(_ id: String, at seconds: Double? = nil, added: Double = 0) -> LibraryPhoto {
        let base = PhotoMetadata.date("2026:11:21 10:00:00")!
        return LibraryPhoto(id: id, file: id + ".jpg", name: id.uppercased() + ".JPG", added: base.addingTimeInterval(added),
                            captured: seconds.map { base.addingTimeInterval($0) })
    }

    /// A library of photos a, b, c (taken in that order, imported c, a, b) with none open.
    private func makeLibrary() {
        interpreter.workspace.library.add(photo("c", at: 30, added: 1))
        interpreter.workspace.library.add(photo("a", at: 10, added: 2))
        interpreter.workspace.library.add(photo("b", at: 20, added: 3))
    }

    // MARK: - Import and browsing (#162)

    func testLibraryNamesReachTheirControls() {
        XCTAssertEqual(parse("import photos"), [.run("importPhotos")])
        XCTAssertEqual(parse("import files"), [.run("importFiles")])
        XCTAssertEqual(parse("import from sd card"), [.run("importCamera")])
        XCTAssertEqual(parse("photo 3"), [.run("openPhoto", value: 3)])
        XCTAssertEqual(parse("next photo"), [.run("nextPhoto")])
        XCTAssertEqual(parse("previous photo"), [.run("previousPhoto")])
        // "Previous" stays the last photo's edit (Presets panel); so do its longer names.
        XCTAssertEqual(parse("previous"), [.run("previousSettings")])
        XCTAssertEqual(parse("previous photo settings"), [.run("previousSettings")])
        XCTAssertEqual(parse("last photo settings"), [.run("previousSettings")])
        // Names that hold "photo" keep their meaning.
        XCTAssertEqual(parse("rotate photo 90").map(\.control), ["rotation"])
        XCTAssertEqual(parse("photo filter"), [.select("photoFilter")])
    }

    func testPhotosShowInTheOrderTheyWereTaken() {
        var library = Library()
        library.add(photo("late", at: 50))
        library.add(photo("undated", added: 20))
        library.add(photo("early", at: 5))
        XCTAssertEqual(library.ordered.map(\.id), ["early", "undated", "late"])
    }

    func testMetadataDatesRoundTrip() {
        let date = PhotoMetadata.date("2026:11:21 10:00:05")
        XCTAssertNotNil(date)
        XCTAssertEqual(PhotoMetadata.exifText(date!), "2026:11:21 10:00:05")
        XCTAssertNil(PhotoMetadata.date("0000:00:00 00:00:00"))
        XCTAssertNil(PhotoMetadata.date(nil))
        XCTAssertEqual(PhotoMetadata.date("2026-11-21T10:00:05"), date)
    }

    func testOpeningPhotosKeepsEachOnesEdit() {
        makeLibrary()
        XCTAssertEqual(events(run("photo 1")), [.opened(id: "a", index: 1, count: 3)])
        run("exposure 1")
        XCTAssertEqual(events(run("next photo")), [.opened(id: "b", index: 2, count: 3)])
        XCTAssertEqual(value("exposure"), 0, "a photo opened for the first time starts a fresh edit")
        run("contrast 20")
        run("previous photo")
        XCTAssertEqual(interpreter.workspace.library.current, "a")
        XCTAssertEqual(value("exposure"), 1, "going back finds the photo as it was left")
        XCTAssertEqual(value("contrast"), 0)
        run("next")
        XCTAssertEqual(value("contrast"), 20)
        // The last photo's edit is Previous, as when any photo is opened.
        XCTAssertEqual(interpreter.workspace.previous?.values["exposure"], 1)
    }

    func testEachPhotoHasAHistoryOfItsOwn() {
        makeLibrary()
        run("photo 1")
        run("exposure 1")
        run("next photo")
        XCTAssertFalse(interpreter.workspace.history.canUndo)
        run("undo")
        XCTAssertEqual(value("exposure"), 0)
    }

    func testViewSettingsStayWhenAnotherPhotoOpens() {
        makeLibrary()
        run("photo 1")
        run("histogram include masks")
        run("next photo")
        XCTAssertEqual(value("histogram"), 1)
        XCTAssertEqual(value("includeMasks"), 1)
    }

    func testNextAndPreviousStopAtTheEnds() {
        makeLibrary()
        XCTAssertEqual(events(run("previous photo")), [.opened(id: "c", index: 3, count: 3)], "none open: going back starts at the last")
        XCTAssertEqual(events(run("next photo")), [.end(next: true)])
        run("photo 1")
        XCTAssertEqual(events(run("previous photo")), [.end(next: false)])
        XCTAssertEqual(events(run("photo 9")), [.noPhoto(9)])
        XCTAssertEqual(events(run("photo")), [.at(index: 1, count: 3)])
        XCTAssertEqual(events(run("library")), [.browsed(shown: 3, total: 3)])
    }

    func testAnEmptyLibrarySaysSo() {
        XCTAssertEqual(events(run("next photo")), [.empty])
        XCTAssertEqual(events(run("photo 2")), [.empty])
    }

    func testCommandsAfterOpeningActOnTheNewPhoto() {
        makeLibrary()
        run("photo 1")
        run("next photo exposure 0.5")
        XCTAssertEqual(interpreter.workspace.library.current, "b")
        XCTAssertEqual(value("exposure"), 0.5)
        XCTAssertNil(interpreter.workspace.library.photo("a")?.edit?.values["exposure"])
    }

    func testLibraryRoundTripsThroughJSON() throws {
        makeLibrary()
        run("photo 2")
        run("exposure 1 next")
        let data = try JSONEncoder().encode(interpreter.workspace.library)
        let back = try JSONDecoder().decode(Library.self, from: data)
        XCTAssertEqual(back, interpreter.workspace.library)
        // A file from an older version (fewer fields) still loads.
        let old = #"{"photos": [{"id": "x", "name": "X.JPG"}]}"#
        let lib = try JSONDecoder().decode(Library.self, from: Data(old.utf8))
        XCTAssertEqual(lib.photos.first?.rating, 0)
        XCTAssertEqual(lib.filter, LibraryFilter())
    }

    func testMetadataFillsTheLibrarysFields() {
        var p = LibraryPhoto(id: "x", name: "X.JPG", added: Date())
        PhotoMetadata.read([
            "PixelWidth": 4000, "PixelHeight": 3000,
            "{Exif}": ["DateTimeOriginal": "2026:11:21 10:00:05", "ISOSpeedRatings": [400], "ExposureTime": 0.004, "FNumber": 2.8,
                       "FocalLength": 35.0, "LensModel": "XF35mmF2 R WR", "ExposureBiasValue": -1.0] as [String: Any],
            "{TIFF}": ["Make": "FUJIFILM", "Model": "X-T5 "] as [String: Any],
            "{GPS}": ["Latitude": 51.5, "LatitudeRef": "N", "Longitude": 0.12, "LongitudeRef": "W"] as [String: Any],
            "{IPTC}": ["Keywords": ["beach", "sea"], "ObjectName": "Sunset", "CopyrightNotice": "© R"] as [String: Any],
        ], into: &p)
        XCTAssertEqual(p.captured, PhotoMetadata.date("2026:11:21 10:00:05"))
        XCTAssertEqual(p.camera.model, "X-T5")
        XCTAssertEqual(p.camera.iso, 400)
        XCTAssertEqual(p.camera.exposureTime, 0.004)
        XCTAssertEqual(p.camera.aperture, 2.8)
        XCTAssertEqual(p.camera.exposureBias, -1)
        XCTAssertEqual(p.camera.width, 4000)
        XCTAssertEqual(p.latitude, 51.5)
        XCTAssertEqual(p.longitude, -0.12)
        XCTAssertEqual(p.keywords, ["beach", "sea"])
        XCTAssertEqual(p.title, "Sunset")
        XCTAssertEqual(p.copyright, "© R")
    }

    // MARK: - Raw support (#163)

    func testRawPresetsAreRelativeToTheCamerasWhiteBalance() {
        // A JPEG is taken as shot in daylight: Daylight changes nothing.
        XCTAssertEqual(WhiteBalance.offset(preset: "daylight").temperature, 0, accuracy: 1e-9)
        // A raw shot with the camera set to 6500 K: Daylight (5500 K) is about 28 mired cooler.
        let daylight = WhiteBalance.offset(preset: "daylight", asShot: 6500)
        XCTAssertEqual(daylight.temperature, 1e6 / 6500 - 1e6 / 5500, accuracy: 1e-9)
        XCTAssertLessThan(daylight.temperature, -20)
        let gains = WhiteBalance.gains(temperature: daylight.temperature, tint: 0)
        XCTAssertGreaterThan(gains.b, gains.r, "cooler")
        // Shot under tungsten-set white balance (3000 K): Daylight warms it up.
        XCTAssertGreaterThan(WhiteBalance.offset(preset: "daylight", asShot: 3000).temperature, 100)
        // As Shot is as the camera set it, whatever that was.
        XCTAssertEqual(WhiteBalance.offset(preset: "asShot", asShot: 3000).temperature, 0)
    }

    // MARK: - Rate, flag, label (#164)

    func testRatingNamesReachTheirControls() {
        XCTAssertEqual(parse("rate 4"), [.run("rate", value: 4)])
        XCTAssertEqual(parse("flag pick"), [.run("pick")])
        XCTAssertEqual(parse("reject"), [.run("reject")])
        XCTAssertEqual(parse("flag off"), [.run("unflag")])
        XCTAssertEqual(parse("label red"), [.run("colorLabel", value: 0)])
        XCTAssertEqual(parse("show picks"), [.run("showPicks")])
        XCTAssertEqual(parse("show rating 3"), [.run("showRating", value: 3)])
        XCTAssertEqual(parse("show label blue"), [.run("showLabel", value: 3)])
        XCTAssertEqual(parse("show all"), [.run("showAllPhotos")])
        // "show" before other names still switches them on.
        XCTAssertEqual(parse("show clipping"), [.set("clippingWarning", 1)])
    }

    func testLabelsMatchTheirControls() {
        let label = registry.control(id: "colorLabel")!
        XCTAssertEqual(label.options.map(\.id), Library.labels + ["none"])
        XCTAssertEqual(registry.control(id: "showLabel")!.options.map(\.id), Library.labels + ["any"])
    }

    func testRatingsFlagsAndLabelsStayWithTheirPhoto() {
        makeLibrary()
        XCTAssertEqual(events(run("rate 4")), [.notInLibrary], "no library photo open")
        run("photo 1")
        XCTAssertEqual(events(run("rate 4")), [.rated(4)])
        XCTAssertEqual(events(run("rate 9")), [.rated(5)], "at most 5 stars")
        XCTAssertEqual(events(run("flag pick label red")), [.flagged(1), .labelled("red")])
        run("next photo reject label none")
        let lib = interpreter.workspace.library
        XCTAssertEqual(lib.photo("a")?.rating, 5)
        XCTAssertEqual(lib.photo("a")?.flag, 1)
        XCTAssertEqual(lib.photo("a")?.label, "red")
        XCTAssertEqual(lib.photo("b")?.flag, -1)
        XCTAssertEqual(lib.photo("b")?.label, "")
        // Rating is no edit: nothing to undo.
        XCTAssertFalse(interpreter.workspace.history.canUndo)
    }

    func testFiltersNarrowWhatIsShown() {
        makeLibrary()
        run("photo 1 rate 3 pick label green")   // a
        run("next rate 5 reject")               // b
        run("next rate 1")                      // c
        XCTAssertEqual(events(run("show rating 3")), [.filtered(shown: 2, total: 3)])
        XCTAssertEqual(interpreter.workspace.library.shown.map(\.id), ["a", "b"])
        XCTAssertEqual(events(run("show picks")), [.filtered(shown: 1, total: 3)])
        run("show all photos")
        run("show rejected")
        XCTAssertEqual(interpreter.workspace.library.shown.map(\.id), ["b"])
        run("show unflagged")
        XCTAssertEqual(interpreter.workspace.library.shown.map(\.id), ["c"])
        run("clear filters show label green")
        XCTAssertEqual(interpreter.workspace.library.shown.map(\.id), ["a"])
        run("show label off")
        XCTAssertEqual(interpreter.workspace.library.filter, LibraryFilter())
    }

    func testNextMovesThroughWhatIsShown() {
        makeLibrary()
        run("photo 1 pick")                     // a
        run("next photo")                       // b
        run("next photo pick")                  // c
        run("show picks")
        run("photo 1")
        XCTAssertEqual(interpreter.workspace.library.current, "a")
        run("next photo")
        XCTAssertEqual(interpreter.workspace.library.current, "c", "b isn't shown: skipped")
    }

    // MARK: - Albums (#165)

    func testAlbumNamesReachTheirControls() {
        XCTAssertEqual(parse("new album trips"), [.run("newAlbum", text: "trips")])
        XCTAssertEqual(parse("add to album trips"), [.run("addToAlbum", text: "trips")])
        XCTAssertEqual(parse("remove from album trips"), [.run("removeFromAlbum", text: "trips")])
        XCTAssertEqual(parse("album trips"), [.run("album", text: "trips")])
        XCTAssertEqual(parse("delete album trips"), [.run("deleteAlbum", text: "trips")])
        XCTAssertEqual(parse("remove album trips"), [.run("deleteAlbum", text: "trips")])
    }

    func testAlbumsGroupPhotos() {
        makeLibrary()
        run("photo 1")
        XCTAssertEqual(events(run("new album trips")), [.albumMade("trips"), .addedToAlbum("trips")])
        XCTAssertEqual(events(run("new album Trips")), [.albumExists("Trips")])
        run("next photo")
        XCTAssertEqual(events(run("add to album trip")), [.addedToAlbum("trips")], "a near-miss finds the album")
        XCTAssertEqual(events(run("add to album family")), [.albumMade("family"), .addedToAlbum("family")])
        XCTAssertEqual(interpreter.workspace.library.albums(of: "b"), ["trips", "family"])
        XCTAssertEqual(events(run("album trips")), [.filtered(shown: 2, total: 3)])
        XCTAssertEqual(interpreter.workspace.library.shown.map(\.id), ["a", "b"])
        XCTAssertEqual(events(run("remove from album")), [.removedFromAlbum("trips")], "no name: the album shown")
        XCTAssertEqual(interpreter.workspace.library.shown.map(\.id), ["a"])
        XCTAssertEqual(events(run("remove from album trips")), [.notInAlbum("trips")])
        XCTAssertEqual(events(run("albums")), [.albums(["trips", "family"])])
        XCTAssertEqual(events(run("delete album trips")), [.albumDeleted("trips")])
        XCTAssertEqual(interpreter.workspace.library.filter.album, "", "the album shown is gone: all photos again")
        XCTAssertEqual(interpreter.workspace.library.photos.count, 3, "its photos stay")
        XCTAssertEqual(events(run("album holidays")), [.noAlbum("holidays")])
    }

    func testWordsAfterAnAlbumsNameAreCommandsAgain() {
        makeLibrary()
        run("photo 1 new album trips")
        run("album trips exposure 0.5")
        XCTAssertEqual(interpreter.workspace.library.filter.album, "trips")
        XCTAssertEqual(value("exposure"), 0.5)
    }

    // MARK: - Keywords & metadata (#166)

    func testKeywordNamesReachTheirControls() {
        XCTAssertEqual(parse("keyword beach"), [.run("addKeyword", text: "beach")])
        XCTAssertEqual(parse("remove keyword beach"), [.run("removeKeyword", text: "beach")])
        XCTAssertEqual(parse("show keyword beach"), [.run("showKeyword", text: "beach")])
        XCTAssertEqual(parse("title Sunset at the beach"), [.run("photoTitle", text: "Sunset at the beach")])
        XCTAssertEqual(parse("copyright © R 2026"), [.run("photoCopyright", text: "© R 2026")])
        XCTAssertEqual(parse("photo info"), [.run("photoInfo")])
        XCTAssertEqual(parse("strip location"), [.set("removeLocation", 1)])
        // A text layer's names keep their words.
        XCTAssertEqual(parse("add title Sale"), [.run("newTextLayer", text: "Sale")])
        XCTAssertEqual(parse("add caption Hello"), [.run("newTextLayer", text: "Hello")])
    }

    func testKeywordsAndCaptionsStayWithTheirPhoto() {
        makeLibrary()
        run("photo 1")
        XCTAssertEqual(events(run("keyword beach, sunset and sea")), [.keywordsAdded(["beach", "sunset", "sea"])])
        XCTAssertEqual(events(run("keyword Beach")), [.keywordsAdded([])], "already has it")
        XCTAssertEqual(events(run("remove keyword sea")), [.keywordRemoved("sea")])
        XCTAssertEqual(events(run("remove keyword sea")), [.noKeyword("sea")])
        XCTAssertEqual(events(run("keywords")), [.keywords(["beach", "sunset"])])
        run("title Sunset")
        run("caption On the way home")
        XCTAssertEqual(events(run("copyright © R")), [.described(field: "copyright", value: "© R")])
        XCTAssertEqual(events(run("title")), [.described(field: "title", value: "Sunset")], "no words: says it")
        let a = interpreter.workspace.library.photo("a")!
        XCTAssertEqual(a.keywords, ["beach", "sunset"])
        XCTAssertEqual(a.title, "Sunset")
        XCTAssertEqual(a.caption, "On the way home")
        run("caption none")
        XCTAssertEqual(interpreter.workspace.library.photo("a")?.caption, "")
        run("next photo")
        XCTAssertEqual(events(run("show keyword beach")), [.filtered(shown: 1, total: 3)])
        XCTAssertEqual(interpreter.workspace.library.shown.map(\.id), ["a"])
        run("show keyword")
        XCTAssertEqual(interpreter.workspace.library.shown.count, 3, "no words: any keyword")
        XCTAssertEqual(events(run("photo info")), [.info])
    }

    func testExportedMetadata() {
        var photo = LibraryPhoto(id: "x", name: "X.JPG", added: Date())
        photo.title = "Sunset"
        photo.caption = "Home"
        photo.copyright = "© R"
        photo.keywords = ["beach"]
        let original: [String: Any] = [
            "Orientation": 6,
            "{Exif}": ["DateTimeOriginal": "2026:11:21 10:00:05", "PixelXDimension": 4000, "FNumber": 2.8] as [String: Any],
            "{TIFF}": ["Make": "FUJIFILM", "Orientation": 6] as [String: Any],
            "{GPS}": ["Latitude": 51.5] as [String: Any],
            "{MakerApple}": ["1": 2] as [String: Any],
        ]
        let out = PhotoMetadata.properties(for: photo, original: original, removeLocation: false, ppi: 300)
        XCTAssertEqual(out["Orientation"] as? Int, 1, "the pixels are upright")
        XCTAssertEqual((out["{TIFF}"] as? [String: Any])?["Orientation"] as? Int, 1)
        XCTAssertEqual((out["{TIFF}"] as? [String: Any])?["Make"] as? String, "FUJIFILM")
        XCTAssertEqual((out["{TIFF}"] as? [String: Any])?["Copyright"] as? String, "© R")
        XCTAssertEqual((out["{Exif}"] as? [String: Any])?["DateTimeOriginal"] as? String, "2026:11:21 10:00:05")
        XCTAssertNil((out["{Exif}"] as? [String: Any])?["PixelXDimension"])
        let iptc = out["{IPTC}"] as? [String: Any]
        XCTAssertEqual(iptc?["Keywords"] as? [String], ["beach"])
        XCTAssertEqual(iptc?["ObjectName"] as? String, "Sunset")
        XCTAssertEqual(iptc?["Caption/Abstract"] as? String, "Home")
        XCTAssertNotNil(out["{GPS}"])
        XCTAssertNil(out["{MakerApple}"])
        XCTAssertEqual(out["DPIWidth"] as? Double, 300)
        let stripped = PhotoMetadata.properties(for: photo, original: original, removeLocation: true, ppi: 72)
        XCTAssertNil(stripped["{GPS}"])
    }

    func testCameraSummary() {
        let camera = CameraInfo(make: "FUJIFILM", model: "X-T5", lens: "XF35mmF2 R WR", iso: 400, exposureTime: 0.004, aperture: 2.8,
                                focalLength: 35, exposureBias: 1)
        XCTAssertEqual(PhotoMetadata.summary(camera), "FUJIFILM X-T5 · XF35mmF2 R WR · ISO 400 · 1/250 s · f/2.8 · 35 mm · +1 EV")
        XCTAssertEqual(PhotoMetadata.shutter(2), "2 s")
        XCTAssertEqual(PhotoMetadata.shutter(1.0 / 60), "1/60 s")
    }

    func testLibraryAndExportSettingsAreNotTheEdit() {
        run("remove location")
        run("reset all")
        XCTAssertEqual(value("removeLocation"), 1)
        XCTAssertFalse(interpreter.workspace.history.canUndo)
    }

    // MARK: - Stacks (#170)

    /// Photos taken at 0, 1, 2, 60, 61 and 300 seconds: two bursts and one on its own.
    private func makeBursts() {
        for (i, t) in [0.0, 1, 2, 60, 61, 300].enumerated() { interpreter.workspace.library.add(photo("p\(i)", at: t)) }
    }

    func testStackNamesReachTheirControls() {
        XCTAssertEqual(parse("stack these"), [.run("stackThese")])
        XCTAssertEqual(parse("auto stack 5"), [.run("autoStack", value: 5)])
        XCTAssertEqual(parse("unstack"), [.run("unstack")])
        XCTAssertEqual(parse("expand stacks"), [.run("expandStacks")])
        XCTAssertEqual(parse("collapse stacks"), [.run("collapseStacks")])
        XCTAssertEqual(parse("select photo 2"), [.run("selectPhoto", value: 2)])
        // The merge's stack keeps its names.
        XCTAssertEqual(parse("stack"), [.run("stackAverage")])
        XCTAssertEqual(parse("stack mean"), [.run("stackAverage", value: 1)])
    }

    func testAutoStackGroupsBurstsByCaptureTime() {
        makeBursts()
        XCTAssertEqual(events(run("auto stack")), [.autoStacked(stacks: 2, photos: 5, gap: 2)])
        let lib = interpreter.workspace.library
        XCTAssertEqual(lib.stacks, [["p0", "p1", "p2"], ["p3", "p4"]])
        XCTAssertEqual(lib.shown.map(\.id), ["p0", "p3", "p5"], "collapsed: each stack shows its top")
        XCTAssertEqual(lib.stackCount(of: "p1"), 3)
        run("expand stacks")
        XCTAssertEqual(interpreter.workspace.library.shown.count, 6)
        run("collapse stacks")
        // A wider gap: one stack of five.
        XCTAssertEqual(events(run("auto stack 60")), [.autoStacked(stacks: 1, photos: 5, gap: 60)])
    }

    func testStackTheseTakesTheSelectionOrTheBurst() {
        makeBursts()
        run("photo 4")                          // p3
        XCTAssertEqual(events(run("stack these")), [.stacked(2)], "nothing selected: the burst p3, p4")
        XCTAssertEqual(interpreter.workspace.library.stacks, [["p3", "p4"]])
        XCTAssertEqual(interpreter.workspace.library.shown.map(\.id), ["p0", "p1", "p2", "p3", "p5"])
        run("expand stacks")
        XCTAssertEqual(events(run("select photo 1 select photo 6")), [.selected(1), .selected(2)])
        XCTAssertEqual(events(run("stack these")), [.stacked(2)])
        XCTAssertEqual(interpreter.workspace.library.stacks, [["p0", "p5"], ["p3", "p4"]])
        XCTAssertTrue(interpreter.workspace.library.selected.isEmpty)
        run("photo 6")                          // p5, alone in time
        XCTAssertEqual(events(run("unstack")), [.unstacked(2)])
        XCTAssertEqual(events(run("stack these")), [.nothingToStack])
        XCTAssertEqual(events(run("select photo 3 select photo 3")), [.selected(1), .selected(0)], "again: deselected")
        run("select photo 2 clear selection")
        XCTAssertTrue(interpreter.workspace.library.selected.isEmpty)
    }

    func testCollapsedStackShowsThePhotoBeingEdited() {
        makeBursts()
        run("auto stack expand stacks photo 2 collapse stacks")   // p1, inside the first stack
        XCTAssertEqual(interpreter.workspace.library.shown.map(\.id), ["p1", "p3", "p5"])
        run("next photo")
        XCTAssertEqual(interpreter.workspace.library.current, "p3")
    }

    // MARK: - Map (#171)

    func testMapShowsThePhotosThatSayWhere() {
        XCTAssertEqual(parse("show map"), [.run("showMap")])
        XCTAssertEqual(parse("gradient map"), [.select("gradientMap")])
        makeLibrary()
        XCTAssertNil(interpreter.workspace.library.mapRegion)
        interpreter.workspace.library.photos[0].latitude = 51.5      // c
        interpreter.workspace.library.photos[0].longitude = -0.1
        interpreter.workspace.library.photos[1].latitude = 51.7      // a
        interpreter.workspace.library.photos[1].longitude = -0.3
        XCTAssertEqual(events(run("map")), [.mapShown(located: 2, shown: 3)])
        let region = interpreter.workspace.library.mapRegion!
        XCTAssertEqual(region.latitude, 51.6, accuracy: 1e-9)
        XCTAssertEqual(region.longitude, -0.2, accuracy: 1e-9)
        XCTAssertEqual(region.latitudeSpan, 0.28, accuracy: 1e-9)
        // One photo: a small region around it.
        interpreter.workspace.library.photos[1].latitude = nil
        XCTAssertEqual(interpreter.workspace.library.mapRegion?.latitudeSpan, 0.01)
        // The filter decides which photos are on the map.
        run("photo 1 pick show picks")
        XCTAssertEqual(interpreter.workspace.library.located.count, 0)
    }

    // MARK: - Tethered capture (#172)

    func testTetheredNamesReachTheirControls() {
        XCTAssertEqual(parse("tethered capture"), [.set("tetheredCapture", 1)])
        XCTAssertEqual(parse("tether off"), [.set("tetheredCapture", 0)])
        XCTAssertEqual(parse("tethered shot"), [.run("tetheredShot")])
        // A camera setting is no step of the edit and stays when another photo opens.
        makeLibrary()
        run("photo 1 tethered capture next photo")
        XCTAssertEqual(value("tetheredCapture"), 1)
        XCTAssertFalse(interpreter.workspace.history.canUndo)
    }
}
