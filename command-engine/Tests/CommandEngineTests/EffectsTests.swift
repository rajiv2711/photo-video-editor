import XCTest
@testable import CommandEngine

/// The Effects panel: names that reach its controls, and the tables the iPad renderer uses.
final class EffectsTests: XCTestCase {
    private var registry: ControlRegistry!
    private var parser: CommandParser!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        parser = CommandParser(registry: registry)
    }

    private func parse(_ text: String) -> [Command] {
        parser.parse(text)
    }

    func testEffectsControlsAreInTheEffectsPanel() {
        for id in ["texture", "clarity", "dehaze"] {
            XCTAssertEqual(registry.control(id: id)?.group, "effects", id)
        }
    }

    // MARK: - Texture

    func testTextureNames() {
        XCTAssertEqual(parse("texture more"), [.nudge("texture", 1)])
        XCTAssertEqual(parse("texture -40"), [.set("texture", -40)])
        XCTAssertEqual(parse("textures up"), [.nudge("texture", 1)])
        XCTAssertEqual(parse("reset texture"), [.reset("texture")])
    }

    func testSmoothstepRampsBetweenItsEnds() {
        XCTAssertEqual(Effects.smoothstep(0.2, 0.4, 0.1), 0)
        XCTAssertEqual(Effects.smoothstep(0.2, 0.4, 0.3), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Effects.smoothstep(0.2, 0.4, 0.9), 1)
        XCTAssertEqual(Effects.table(count: 3) { $0 * $0 }, [0, 0.25, 1])
    }

    func testTextureSmoothsFineDetailButNotStrongEdges() {
        let table = Effects.textureSmoothing(amount: 1)
        XCTAssertEqual(table.count, 64)
        XCTAssertEqual(table[0], 0.85, accuracy: 1e-12, "flat areas: mostly the blurred copy")
        XCTAssertEqual(table[63], 0, "strong edges: untouched")
        XCTAssertEqual(Effects.textureSmoothing(amount: 0).max(), 0)
        for i in 1..<table.count { XCTAssertLessThanOrEqual(table[i], table[i - 1]) }
    }

    // MARK: - Clarity

    func testClarityNames() {
        XCTAssertEqual(parse("clarity up"), [.nudge("clarity", 1)])
        XCTAssertEqual(parse("clarity -30"), [.set("clarity", -30)])
        XCTAssertEqual(parse("local contrast more"), [.nudge("clarity", 1)])
        XCTAssertEqual(parse("contrast more"), [.nudge("contrast", 1)], "plain contrast stays the Light slider")
    }

    func testClarityWorksOnMidtonesOnly() {
        let table = Effects.midtones()
        XCTAssertEqual(table.first, 0)
        XCTAssertEqual(table.last, 0)
        XCTAssertEqual(table[32], 1, accuracy: 1e-12)
        XCTAssertLessThan(table[3], 0.2)
        XCTAssertLessThan(table[61], 0.2)
    }

    // MARK: - Dehaze

    func testDehazeNames() {
        XCTAssertEqual(parse("dehaze 50"), [.set("dehaze", 50)])
        XCTAssertEqual(parse("de haze more"), [.nudge("dehaze", 1)])
        XCTAssertEqual(parse("remove haze -20"), [.set("dehaze", -20)])
    }

    func testAirlightIsTheBrightLevelOfEachChannel() {
        var red = [Double](repeating: 0, count: 256), green = red, blue = red
        red[100] = 0.9; red[230] = 0.1     // 10 % of red at level 230
        green[100] = 1                     // all green at 100 → floor 0.5
        blue[200] = 0.996; blue[255] = 0.004
        let a = Effects.airlight(red: red, green: green, blue: blue)
        XCTAssertEqual(a.r, 230.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(a.g, 0.5)
        XCTAssertEqual(a.b, 200.0 / 255, accuracy: 1e-9)
    }

    func testDehazeUndoesHaze() {
        // A dark-channel-free colour seen through 50 % haze: I = J·t + A·(1 − t).
        let scene = RGB(0.0, 0.3, 0.6), air = RGB(0.85, 0.88, 0.9), t = 0.5
        let hazy = scene * t + air * (1 - t)
        let dark = min(hazy.r / air.r, hazy.g / air.g, hazy.b / air.b)  // = 1 − t
        let clear = Effects.dehaze(hazy, darkChannel: dark, airlight: air, strength: 1)
        XCTAssertEqual(clear.r, scene.r, accuracy: 1e-9)
        XCTAssertEqual(clear.g, scene.g, accuracy: 1e-9)
        XCTAssertEqual(clear.b, scene.b, accuracy: 1e-9)
        // The table the renderer uses gives the same 1/t.
        let ratio = Effects.dehazeRatio(strength: 1)
        XCTAssertEqual(ratio[Int((dark * 255).rounded())] / Effects.dehazeFloor, 1 / t, accuracy: 0.01)
        XCTAssertEqual(ratio[0], Effects.dehazeFloor, "no haze: t = 1")
        XCTAssertEqual(ratio[255], 1, "thick haze: t stops at the floor")
    }

    func testNegativeDehazeAddsHaze() {
        let pixel = RGB(0.1, 0.2, 0.3), air = RGB(0.9, 0.9, 0.9)
        let hazy = Effects.dehaze(pixel, darkChannel: 0, airlight: air, strength: -1)
        XCTAssertGreaterThan(hazy.min, pixel.max, "lighter")
        XCTAssertLessThan(hazy.max - hazy.min, pixel.max - pixel.min, "flatter")
    }
}
