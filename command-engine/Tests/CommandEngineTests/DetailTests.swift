import XCTest
@testable import CommandEngine

/// The Detail panel: names that reach its controls, and the numbers the iPad renderer uses.
final class DetailTests: XCTestCase {
    private var registry: ControlRegistry!
    private var parser: CommandParser!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        parser = CommandParser(registry: registry)
    }

    private func parse(_ text: String) -> [Command] {
        parser.parse(text)
    }

    func testDetailControlsAreInTheDetailPanel() {
        for id in ["sharpening", "sharpeningRadius", "sharpeningDetail", "sharpeningMasking"] {
            XCTAssertEqual(registry.control(id: id)?.group, "detail", id)
        }
    }

    func testSizesFollowThePhoto() {
        XCTAssertEqual(Detail.pixels(1, longSide: 2048), 1)
        XCTAssertEqual(Detail.pixels(1, longSide: 6144), 3)
        XCTAssertEqual(Detail.pixels(1, longSide: 800), 1, "small pictures keep the preview's pixel sizes")
    }

    // MARK: - Sharpening

    func testSharpeningNames() {
        XCTAssertEqual(parse("sharpen"), [.select("sharpening")])
        XCTAssertEqual(parse("sharpening 60"), [.set("sharpening", 60)])
        XCTAssertEqual(parse("sharpness max"), [.max("sharpening")])
        XCTAssertEqual(parse("sharpening radius 1.5"), [.set("sharpeningRadius", 1.5)])
        XCTAssertEqual(parse("sharpening detail up"), [.nudge("sharpeningDetail", 1)])
        XCTAssertEqual(parse("sharpening masking 70"), [.set("sharpeningMasking", 70)])
        XCTAssertEqual(parse("shadows 20"), [.set("shadows", 20)], "shadows stays the Light slider")
    }

    func testDetailTurnsUpTheFinePass() {
        XCTAssertEqual(Detail.sharpening(amount: 1, detail: 0).fine, 0)
        XCTAssertGreaterThan(Detail.sharpening(amount: 1, detail: 1).fine, Detail.sharpening(amount: 1, detail: 0.25).fine)
        XCTAssertEqual(Detail.sharpening(amount: 0, detail: 1).main, 0)
    }

    func testMaskingSparesFlatAreas() {
        XCTAssertEqual(Detail.sharpeningMask(masking: 0).min(), 1, "0 sharpens everywhere")
        let masked = Detail.sharpeningMask(masking: 1)
        XCTAssertEqual(masked.first, 0, "flat areas")
        XCTAssertEqual(masked.last, 1, "strong edges")
    }
}
