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
        for id in ["texture"] {
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
}
