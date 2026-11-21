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
}
