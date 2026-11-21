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
    }

    struct Step: Decodable {
        let command: String?
        let stroke: [[Double]]?
        let tap: [Double]?
    }

    struct File: Decodable {
        let cases: [Case]
    }

    /// Must match dev-tools/ci_results.py.
    static let metrics: Set = [
        "mean_luma", "p5_luma", "p25_luma", "p50_luma", "p75_luma", "p95_luma",
        "mean_sat", "mean_r", "mean_g", "mean_b", "diff", "peak",
        "edge", "local_contrast", "fringe", "corner_luma", "center_luma", "width", "height", "aspect", "tilt", "vertical_spread",
    ]
    static let directions: Set = ["up", "down", "changed", "same"]
    /// Generated starting pictures; must match RenderGallery.sourceImage in the app.
    static let sources: Set = ["warm", "negative", "chart", "haze", "noise", "moire", "grid", "lens", "lateral-ca", "fringe", "fisheye",
                               "dust", "red-eye", "pet-eye", "tilted", "building", "skewed",
                               "bracket-dark", "bracket-mid", "bracket-bright", "bracket-ghost", "pano-left", "pano-middle", "pano-right",
                               "hdrpano-left-dark", "hdrpano-left-mid", "hdrpano-left-bright",
                               "hdrpano-right-dark", "hdrpano-right-mid", "hdrpano-right-bright"]

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
            for photo in c.photos ?? [] { XCTAssertTrue(Self.sources.contains(photo), "\(c.id): unknown photo \(photo)") }
            if let tap = c.tap {
                XCTAssertTrue(tap.count == 2 && tap.allSatisfy { (0...1).contains($0) }, "\(c.id): tap is x, y in 0…1")
            }
            for step in c.steps ?? [] {
                let parts = [step.command != nil, step.stroke != nil, step.tap != nil].filter { $0 }.count
                XCTAssertEqual(parts, 1, "\(c.id): a step is one command, stroke or tap")
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
