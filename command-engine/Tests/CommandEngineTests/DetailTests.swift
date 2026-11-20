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
        for id in ["sharpening", "sharpeningRadius", "sharpeningDetail", "sharpeningMasking", "noiseReduction",
                   "chromaNoiseReduction", "moire", "highPass", "highPassRadius"] {
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

    // MARK: - Noise reduction

    func testNoiseReductionNames() {
        XCTAssertEqual(parse("noise reduction 40"), [.set("noiseReduction", 40)])
        XCTAssertEqual(parse("denoise up"), [.nudge("noiseReduction", 1)])
        XCTAssertEqual(parse("chroma noise 50"), [.set("chromaNoiseReduction", 50)])
        XCTAssertEqual(parse("noise reduction color more"), [.nudge("chromaNoiseReduction", 1)])
        XCTAssertEqual(parse("noise more"), [.ambiguous("noise", ["noiseReduction", "chromaNoiseReduction"])])
        XCTAssertEqual(parse("colour less"), [.ambiguous("colour", ["vibrance", "saturation"])], "colour still means two controls")
        XCTAssertEqual(parse("grain 20"), [.set("grain", 20)], "grain is not noise reduction")
    }

    func testNoiseSmoothingKeepsEdgesAndGrowsWithAmount() {
        let light = Detail.noiseSmoothing(amount: 0.3), strong = Detail.noiseSmoothing(amount: 1)
        XCTAssertEqual(light.last, 0)
        XCTAssertEqual(strong.last, 0)
        XCTAssertEqual(strong.first, 1)
        XCTAssertGreaterThan(strong[10], light[10])
        XCTAssertEqual(Detail.noiseSmoothing(amount: 0).max(), 0)
        XCTAssertGreaterThan(Detail.noiseRadius(amount: 1, color: true), Detail.noiseRadius(amount: 1, color: false))
    }

    // MARK: - Moiré

    func testMoireNames() {
        XCTAssertEqual(parse("moire 60"), [.set("moire", 60)])
        XCTAssertEqual(parse("moiré removal more"), [.nudge("moire", 1)])
        XCTAssertEqual(parse("remove moire max"), [.max("moire")])
    }

    func testMoireTargetsBusyColour() {
        let mask = Detail.moireMask(amount: 1)
        XCTAssertEqual(mask.first, 0, "plain colour stays")
        XCTAssertEqual(mask.last, 1)
        XCTAssertEqual(Detail.moireMask(amount: 0).max(), 0)
        XCTAssertGreaterThan(Detail.moireRadius(amount: 1), Detail.moireRadius(amount: 0))
    }

    // MARK: - High pass

    func testHighPassNames() {
        XCTAssertEqual(parse("high pass 50"), [.set("highPass", 50)])
        XCTAssertEqual(parse("highpass more"), [.nudge("highPass", 1)])
        XCTAssertEqual(parse("high pass radius 6"), [.set("highPassRadius", 6)])
        XCTAssertEqual(parse("highlights 10"), [.set("highlights", 10)])
    }

    func testHighPassOverlaySharpensWithoutClipping() {
        XCTAssertEqual(Detail.highPass(0.4, detail: 0, amount: 1), 0.4, accuracy: 1e-12, "flat areas stay")
        XCTAssertGreaterThan(Detail.highPass(0.4, detail: 0.05, amount: 0.5), 0.4)
        XCTAssertLessThan(Detail.highPass(0.4, detail: -0.05, amount: 0.5), 0.4)
        XCTAssertEqual(Detail.highPass(1, detail: 0.2, amount: 1), 1, "white can't go above white")
        XCTAssertEqual(Detail.highPass(0, detail: -0.2, amount: 1), 0, "black can't go below black")
    }
}
