import XCTest
@testable import CommandEngine

/// The Color panel: names that reach its controls, and the colour math the iPad renderer uses.
final class ColorTests: XCTestCase {
    private var registry: ControlRegistry!
    private var parser: CommandParser!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        parser = CommandParser(registry: registry)
    }

    private func parse(_ text: String) -> [Command] {
        parser.parse(text)
    }

    /// Option ids of a choice control, in controls.json order.
    private func options(_ id: String) -> [String] {
        registry.control(id: id)?.options.map(\.id) ?? []
    }

    private func assertClose(_ a: Double, _ b: Double, _ accuracy: Double = 1e-6, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - White balance

    func testWhiteBalancePresetsMatchControlsJSON() {
        XCTAssertEqual(options("whiteBalance"), WhiteBalance.presetIDs)
    }

    func testWhiteBalancePresetNames() {
        XCTAssertEqual(parse("white balance tungsten"), [.set("whiteBalance", 5)])
        XCTAssertEqual(parse("wb cloudy"), [.set("whiteBalance", 3)])
        XCTAssertEqual(parse("white balance auto"), [.set("whiteBalance", 1)], "the preset, not the Auto action")
        XCTAssertEqual(parse("white balance as shot"), [.set("whiteBalance", 0)])
        XCTAssertEqual(parse("white balance sunny"), [.set("whiteBalance", 2)])
        XCTAssertEqual(parse("whites 20 white balance shade"), [.set("whites", 20), .set("whiteBalance", 4)])
    }

    func testAsShotAndDaylightLeaveTheColoursAlone() {
        for preset in ["asShot", "auto", "daylight"] {
            let offset = WhiteBalance.offset(preset: preset)
            let g = WhiteBalance.gains(temperature: offset.temperature, tint: offset.tint)
            assertClose(g.r, 1, 1e-9, preset)
            assertClose(g.g, 1, 1e-9, preset)
            assertClose(g.b, 1, 1e-9, preset)
        }
    }

    func testPresetsCorrectForTheirLight() {
        func gains(_ preset: String) -> RGB {
            let o = WhiteBalance.offset(preset: preset)
            return WhiteBalance.gains(temperature: o.temperature, tint: o.tint)
        }
        // Tungsten light is orange, so the correction is blue.
        XCTAssertGreaterThan(gains("tungsten").b, 1.3)
        XCTAssertLessThan(gains("tungsten").r, 0.9)
        // Cloudy and shade light is bluish, so the correction is warm; shade more so.
        XCTAssertGreaterThan(gains("cloudy").r, gains("cloudy").b)
        XCTAssertGreaterThan(gains("shade").r / gains("shade").b, gains("cloudy").r / gains("cloudy").b)
        // Fluorescent light is green: the correction takes green out.
        let fluorescent = WhiteBalance.offset(preset: "fluorescent")
        XCTAssertLessThan(gains("fluorescent").g, WhiteBalance.gains(temperature: fluorescent.temperature, tint: 0).g)
    }

    func testGainsKeepBrightness() {
        for (t, tint) in [(-100.0, 0.0), (100, 0), (40, -60), (-169, 21)] {
            assertClose(WhiteBalance.gains(temperature: t, tint: tint).luma, 1, 1e-9)
        }
    }

    func testWarmerTemperatureRaisesRedAgainstBlue() {
        let warm = WhiteBalance.gains(temperature: 50, tint: 0)
        let cool = WhiteBalance.gains(temperature: -50, tint: 0)
        XCTAssertGreaterThan(warm.r, warm.b)
        XCTAssertLessThan(cool.r, cool.b)
        XCTAssertLessThan(WhiteBalance.gains(temperature: 0, tint: 50).g, 1, "positive tint is magenta")
    }

    func testNeutralizeUndoesACast() {
        for (t, tint) in [(-80.0, 0.0), (40, 20), (-150, -30), (0, 0)] {
            // A grey card photographed under a cast that these settings would correct.
            let cast = RGB(0.4, 0.4, 0.4) / WhiteBalance.gains(temperature: t, tint: tint)
            let found = WhiteBalance.neutralize(cast)
            assertClose(found.temperature, t, 0.01, "temperature for \(t), \(tint)")
            assertClose(found.tint, tint, 0.01, "tint for \(t), \(tint)")
        }
        let grey = WhiteBalance.neutralize(RGB(0.5, 0.5, 0.5))
        assertClose(grey.temperature, 0, 0.01)
        assertClose(grey.tint, 0, 0.01)
    }
}
