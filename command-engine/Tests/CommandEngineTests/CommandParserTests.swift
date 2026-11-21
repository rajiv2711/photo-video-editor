import XCTest
@testable import CommandEngine

final class CommandParserTests: XCTestCase {
    private var parser: CommandParser!

    override func setUpWithError() throws {
        parser = CommandParser(registry: try ControlRegistry.bundled())
    }

    func testRepeatsMergeIntoOneNudge() {
        XCTAssertEqual(parser.parse("contrast more, more, more"), [.nudge("contrast", 3)])
        XCTAssertEqual(parser.parse("contrast more more less"), [.nudge("contrast", 1)])
    }

    func testActionsWithoutANameTargetTheFocusedControl() {
        XCTAssertEqual(parser.parse("more more"), [.nudge(nil, 2)])
        XCTAssertEqual(parser.parse("up by 10"), [.add(nil, 10)])
    }

    func testNamingAControlAloneSelectsIt() {
        XCTAssertEqual(parser.parse("Contrast"), [.select("contrast")])
    }

    func testSetAfterNudgeKeepsOrder() {
        XCTAssertEqual(parser.parse("contrast more 20"), [.add("contrast", 20)])
        XCTAssertEqual(parser.parse("contrast 20 more"), [.set("contrast", 20), .nudge("contrast", 1)])
    }

    func testVerbFirstActsOnTheFirstName() {
        XCTAssertEqual(parser.parse("reset contrast"), [.reset("contrast")])
        XCTAssertEqual(parser.parse("more contrast"), [.nudge("contrast", 1)])
        XCTAssertEqual(parser.parse("raise exposure by 0.5"), [.add("exposure", 0.5)])
        XCTAssertEqual(parser.parse("more contrast saturation less"), [.nudge("contrast", 1), .nudge("saturation", -1)])
        XCTAssertEqual(parser.parse("add a wobble"), [.unknown("wobble")])
    }

    /// Every label and synonym in controls.json must reach its own control when said alone (a name whose
    /// first word the parser reads as something else, like "make" or "set", can never be used).
    func testEveryNameReachesItsControl() throws {
        let registry = try ControlRegistry.bundled()
        var unreachable: [String] = []
        for control in registry.controls {
            for name in control.names where !parser.parse(name).contains(where: { $0.control == control.id }) {
                unreachable.append("“\(name)” (\(control.id))")
            }
        }
        XCTAssertEqual(unreachable, [])
    }

    /// Every option name, said after its control's label, picks that option ("text font headline",
    /// "collage one above the other"), except where a control of that very name does the same.
    func testEveryOptionReachesItsControl() throws {
        let registry = try ControlRegistry.bundled()
        let sameEffect: Set = ["zoom fit", "zoom fit to screen", "upright guides", "watermark text", "watermark words"]
        var unreachable: [String] = []
        for control in registry.controls {
            for (index, option) in control.options.enumerated() {
                for name in option.names {
                    let said = control.label.lowercased() + " " + name
                    let picked = parser.parse(said).contains { $0.control == control.id && $0.value == Double(index) }
                    if !picked && !sameEffect.contains(said) { unreachable.append("“\(said)”") }
                }
            }
        }
        XCTAssertEqual(unreachable, [])
    }

    func testUnknownWordStopsLaterActions() {
        XCTAssertEqual(parser.parse("wobble more"), [.unknown("wobble")])
    }

    func testJSONShapeIsCompactAndOmitsEmptyFields() {
        XCTAssertEqual(Command.nudge("contrast", 3).json, #"{"control":"contrast","op":"nudge","steps":3}"#)
        XCTAssertEqual(Command.nudge(nil, 1).json, #"{"op":"nudge","steps":1}"#)
        XCTAssertEqual(Command.resetAll.json, #"{"op":"reset_all"}"#)
    }

    func testJSONRoundTrip() throws {
        let commands: [Command] = [.set("exposure", 0.5), .ambiguous("shad", ["shadows", "shading"]), .unknown("blur")]
        let data = try JSONEncoder().encode(commands)
        XCTAssertEqual(try JSONDecoder().decode([Command].self, from: data), commands)
    }

    func testApplierMergesSameControlAndRejectsInventedControls() throws {
        let applier = CommandApplier(registry: try ControlRegistry.bundled())
        var state = EditState()
        var focus: String?
        XCTAssertEqual(
            applier.apply([.set("contrast", 20), .nudge("contrast", 1), .nudge("wobble", 1)], state: &state, focus: &focus),
            [.changed(controlID: "contrast", from: 0, to: 25), .unknown(word: "wobble")]
        )
        XCTAssertEqual(focus, "contrast")
    }
}
