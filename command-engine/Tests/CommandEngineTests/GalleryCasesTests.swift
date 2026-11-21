import XCTest
@testable import CommandEngine

/// Checks test-data/gallery/gallery.json, the render cases the cloud build draws on the iPad
/// simulator: every command must reach real controls (no unknown or ambiguous words), and every
/// control in controls.json needs at least one case (curve points: one per section), so each new
/// operation gets a picture test.
final class GalleryCasesTests: XCTestCase {
    struct Expectation: Decodable {
        let metric: String
        let dir: String
        let vs: String?
        let region: [Double]?
        /// metric "field": a value the app wrote in the manifest (a library or export detail) and what it must be.
        let field: String?
        let value: String?
    }

    struct Case: Decodable {
        let id: String
        let command: String
        let control: String?
        let expect: [Expectation]
        let source: String?
        let tap: [Double]?
        let strokes: [[[Double]]]?
        let steps: [Step]?
        let photos: [String]?
        let live: [String]?
        let view: String?
        let library: [String]?
    }

    struct Step: Decodable {
        let command: String?
        let stroke: [[Double]]?
        let tap: [Double]?
        let open: String?
    }

    struct File: Decodable {
        let cases: [Case]
    }

    /// Must match dev-tools/ci_results.py.
    static let metrics: Set = [
        "mean_luma", "p5_luma", "p25_luma", "p50_luma", "p75_luma", "p95_luma",
        "mean_sat", "mean_r", "mean_g", "mean_b", "diff", "peak",
        "edge", "local_contrast", "fringe", "corner_luma", "center_luma", "width", "height", "aspect", "tilt", "vertical_spread", "flat",
        "field",
    ]
    static let directions: Set = ["up", "down", "changed", "same", "is"]
    /// What a case may save instead of the edited photo; must match RenderGallery in the app.
    static let views: Set = ["batch", "overlay", "export"]
    /// Generated starting pictures; must match RenderGallery.sourceImage in the app.
    static let sources: Set = ["warm", "negative", "chart", "haze", "noise", "moire", "grid", "lens", "lateral-ca", "fringe", "fisheye",
                               "dust", "red-eye", "pet-eye", "tilted", "building", "skewed",
                               "bracket-dark", "bracket-mid", "bracket-bright", "bracket-ghost", "pano-left", "pano-middle", "pano-right",
                               "hdrpano-left-dark", "hdrpano-left-mid", "hdrpano-left-bright",
                               "hdrpano-right-dark", "hdrpano-right-mid", "hdrpano-right-bright", "focus-top", "focus-bottom",
                               "burst-1", "burst-2", "burst-3", "burst-4",
                               "live-0", "live-1", "live-2", "live-3", "live-4", "live-5", "live-6", "live-7", "portrait", "raw"]

    private var registry: ControlRegistry!
    private var cases: [Case] = []

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        // command-engine/Tests/CommandEngineTests/ → repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("test-data/gallery/gallery.json"))
        cases = try JSONDecoder().decode(File.self, from: data).cases
    }

    func testThereIsABaseCaseWithNoEdits() {
        XCTAssertEqual(cases.first?.id, "base")
        XCTAssertEqual(cases.first?.command, "")
    }

    func testIdsAreUniqueAndExpectationsAreWellFormed() {
        let ids = cases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate case ids")
        for c in cases {
            XCTAssertFalse(c.id.contains("/") || c.id.contains(" "), "\(c.id): use letters, digits and dashes")
            if c.id != "base" { XCTAssertFalse(c.expect.isEmpty, "\(c.id) has no expectation") }
            if let source = c.source { XCTAssertTrue(Self.sources.contains(source), "\(c.id): unknown source \(source)") }
            for photo in (c.photos ?? []) + (c.live ?? []) + (c.library ?? []) { XCTAssertTrue(Self.sources.contains(photo), "\(c.id): unknown photo \(photo)") }
            if let live = c.live { XCTAssertGreaterThanOrEqual(live.count, 2, "\(c.id): a Live Photo is its photo and frames") }
            if let view = c.view { XCTAssertTrue(Self.views.contains(view), "\(c.id): unknown view \(view)") }
            if c.view == "batch" { XCTAssertFalse((c.photos ?? []).isEmpty, "\(c.id): a batch needs photos picked") }
            if let tap = c.tap {
                XCTAssertTrue(tap.count == 2 && tap.allSatisfy { (0...1).contains($0) }, "\(c.id): tap is x, y in 0…1")
            }
            for step in c.steps ?? [] {
                let parts = [step.command != nil, step.stroke != nil, step.tap != nil, step.open != nil].filter { $0 }.count
                XCTAssertEqual(parts, 1, "\(c.id): a step is one command, stroke, tap or photo opened")
                if let open = step.open { XCTAssertTrue(Self.sources.contains(open), "\(c.id): unknown photo \(open)") }
                if let tap = step.tap { XCTAssertTrue(tap.count == 2 && tap.allSatisfy { (0...1).contains($0) }, c.id) }
            }
            for stroke in (c.strokes ?? []) + (c.steps ?? []).compactMap(\.stroke) {
                XCTAssertFalse(stroke.isEmpty, "\(c.id): empty stroke")
                XCTAssertTrue(stroke.allSatisfy { $0.count == 2 && $0.allSatisfy { (0...1).contains($0) } },
                              "\(c.id): stroke points are x, y in 0…1")
            }
            for e in c.expect {
                XCTAssertTrue(Self.metrics.contains(e.metric), "\(c.id): unknown metric \(e.metric)")
                XCTAssertTrue(Self.directions.contains(e.dir), "\(c.id): unknown direction \(e.dir)")
                // A field is compared as it is ("is"); pictures are measured (up, down, changed, same).
                XCTAssertEqual(e.metric == "field", e.dir == "is", "\(c.id): metric field goes with dir is")
                if e.metric == "field" { XCTAssertTrue(e.field != nil && e.value != nil, "\(c.id): a field check needs field and value") }
                if let vs = e.vs { XCTAssertTrue(ids.contains(vs), "\(c.id): vs \(vs) is not a case") }
                if let r = e.region {
                    XCTAssertTrue(r.count == 4 && r.allSatisfy { (0...1).contains($0) } && r[0] < r[2] && r[1] < r[3],
                                  "\(c.id): region is x0, y0, x1, y1 in 0…1 with x0 < x1, y0 < y1")
                }
            }
        }
    }

    func testEveryCommandReachesItsControl() {
        let parser = CommandParser(registry: registry)
        for c in cases where !c.command.isEmpty {
            var commands: [Command] = []
            for text in [c.command] + (c.steps ?? []).compactMap(\.command) {
                let parsed = parser.parse(text)
                XCTAssertFalse(parsed.isEmpty, "\(c.id): nothing parsed in “\(text)”")
                for command in parsed {
                    XCTAssertNotEqual(command.op, .unknown, "\(c.id): unknown word in “\(text)”")
                    XCTAssertNotEqual(command.op, .ambiguous, "\(c.id): ambiguous word in “\(text)”")
                }
                commands += parsed
            }
            if let control = c.control {
                XCTAssertNotNil(registry.control(id: control), "\(c.id): no control \(control)")
                XCTAssertTrue(commands.contains { $0.control == control }, "\(c.id): “\(c.command)” doesn't reach \(control)")
            }
        }
    }

    func testEveryControlHasACase() {
        let covered = Set(cases.compactMap(\.control))
        for control in registry.controls where control.kind != .curvePoint {
            XCTAssertTrue(covered.contains(control.id), "no gallery case for \(control.id)")
        }
        // Curve points share one render step: one case per curve section is enough.
        let curveSections = Set(registry.controls.filter { $0.kind == .curvePoint }.compactMap(\.section))
        for section in curveSections {
            XCTAssertTrue(registry.controls.contains { $0.section == section && covered.contains($0.id) },
                          "no gallery case for \(section)")
        }
    }
}
