import XCTest
@testable import CommandEngine

/// Auto (one tap): from a brightness histogram to `set` commands for the light sliders.
final class AutoToneTests: XCTestCase {
    /// A histogram with every pixel spread evenly between two levels (0…1).
    private func histogram(from lo: Double, to hi: Double) -> [Double] {
        (0..<256).map { i in
            let x = (Double(i) + 0.5) / 256
            return x >= lo && x <= hi ? 1 : 0
        }
    }

    private func values(_ commands: [Command]) -> [String: Double] {
        var out: [String: Double] = [:]
        for c in commands where c.op == .set { out[c.control!] = c.value }
        return out
    }

    func testSetsEveryLightControlItOwns() {
        let commands = AutoTone.commands(lumaHistogram: histogram(from: 0, to: 1))
        XCTAssertEqual(commands.map(\.control!), AutoTone.controlIDs)
        XCTAssertTrue(commands.allSatisfy { $0.op == .set })
        let registry = try! ControlRegistry.bundled()
        for id in AutoTone.controlIDs { XCTAssertNotNil(registry.control(id: id), id) }
    }

    func testWellSpreadPhotoBarelyChanges() {
        let v = values(AutoTone.commands(lumaHistogram: histogram(from: 0, to: 1)))
        XCTAssertEqual(v["exposure"], 0)
        XCTAssertEqual(v["whites"], 0)
        XCTAssertEqual(v["blacks"], 0)
        XCTAssertEqual(v["contrast"], 0)
    }

    func testDarkPhotoGetsBrighter() {
        let v = values(AutoTone.commands(lumaHistogram: histogram(from: 0.05, to: 0.3)))
        XCTAssertGreaterThan(v["exposure"]!, 0.3)
        XCTAssertGreaterThan(v["shadows"]!, 0)
    }

    func testWashedOutPhotoGetsDarkerAndDeeperBlacks() {
        let v = values(AutoTone.commands(lumaHistogram: histogram(from: 0.55, to: 0.9)))
        XCTAssertLessThan(v["exposure"]!, 0)
        XCTAssertLessThan(v["blacks"]!, 0)
        XCTAssertGreaterThan(v["contrast"]!, 0)
    }

    func testEmptyHistogramDoesNothing() {
        XCTAssertEqual(AutoTone.commands(lumaHistogram: []), [])
        XCTAssertEqual(AutoTone.commands(lumaHistogram: [0, 0, 0]), [])
    }

    func testAutoRunsThroughTheInterpreter() throws {
        var interpreter = CommandInterpreter(registry: try ControlRegistry.bundled())
        interpreter.actionHandler = { id in
            id == "auto" ? AutoTone.commands(lumaHistogram: self.histogram(from: 0.05, to: 0.3)) : []
        }
        var state = EditState()
        let outcomes = interpreter.interpret("auto", state: &state)
        XCTAssertEqual(outcomes.first, .ran(controlID: "auto"))
        XCTAssertTrue(outcomes.contains { if case .changed(controlID: "exposure", _, _) = $0 { return true } else { return false } })
    }
}
