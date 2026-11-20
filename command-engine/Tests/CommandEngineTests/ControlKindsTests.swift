import XCTest
@testable import CommandEngine

/// Control kinds beyond sliders (toggles, choices, actions, curve points), multi-word names and the
/// controls.json schema. Uses small made-up registries so it doesn't depend on the bundled list.
final class ControlKindsTests: XCTestCase {
    private let registry = ControlRegistry(controls: [
        Control(id: "highlights", label: "Highlights", group: "light", min: -100, max: 100, defaultValue: 0, step: 5),
        Control(id: "curveHighlights", label: "Curve Highlights", synonyms: ["tone curve highlights"], group: "light",
                section: "Tone curve", min: -100, max: 100, defaultValue: 0, step: 5),
        Control(id: "curveRgb50", label: "Curve 50", group: "light", section: "Point curve", kind: .curvePoint,
                min: 0, max: 100, defaultValue: 50, step: 5, channel: "rgb", x: 50),
        Control(id: "curveRed50", label: "Red Curve 50", group: "light", section: "Point curve", kind: .curvePoint,
                min: 0, max: 100, defaultValue: 50, step: 5, channel: "red", x: 50),
        Control(id: "hdr", label: "HDR", group: "light", kind: .toggle, min: 0, max: 1, defaultValue: 0, step: 1),
        Control(id: "auto", label: "Auto", synonyms: ["auto tone"], group: "light", kind: .action, min: 0, max: 0, defaultValue: 0, step: 0),
        Control(id: "whiteBalance", label: "White Balance", group: "color", kind: .choice, min: 0, max: 3, defaultValue: 0, step: 1,
                options: [Control.Option(id: "asShot", label: "As Shot"), Control.Option(id: "auto", label: "Auto"),
                          Control.Option(id: "daylight", label: "Daylight", synonyms: ["sunny"]),
                          Control.Option(id: "cloudy", label: "Cloudy")]),
    ])

    private func parse(_ text: String) -> [Command] {
        CommandParser(registry: registry).parse(text)
    }

    func testLongestMultiWordNameWins() {
        XCTAssertEqual(parse("highlights 20"), [.set("highlights", 20)])
        XCTAssertEqual(parse("curve highlights 20"), [.set("curveHighlights", 20)])
        XCTAssertEqual(parse("tone curve highlights up"), [.nudge("curveHighlights", 1)])
    }

    func testCurvePointNamesContainNumbers() {
        XCTAssertEqual(parse("curve 50 60"), [.set("curveRgb50", 60)])
        XCTAssertEqual(parse("curve 50 to 70"), [.set("curveRgb50", 70)])
        XCTAssertEqual(parse("red curve 50 up"), [.nudge("curveRed50", 1)])
        XCTAssertEqual(parse("red curve 50% 40"), [.set("curveRed50", 40)])
    }

    func testTogglesTakeOnOffAndTheBareNameTurnsOn() {
        XCTAssertEqual(parse("hdr on"), [.set("hdr", 1)])
        XCTAssertEqual(parse("hdr off"), [.set("hdr", 0)])
        XCTAssertEqual(parse("turn hdr off"), [.set("hdr", 0)])
        XCTAssertEqual(parse("HDR"), [.set("hdr", 1)])
        XCTAssertEqual(parse("highlights on"), [.select("highlights")], "on/off mean nothing to a slider")
    }

    func testChoicesTakeAnOptionName() {
        XCTAssertEqual(parse("white balance cloudy"), [.set("whiteBalance", 3)])
        XCTAssertEqual(parse("white balance as shot"), [.set("whiteBalance", 0)])
        XCTAssertEqual(parse("white balance sunny"), [.set("whiteBalance", 2)])
        XCTAssertEqual(parse("white balance cloudi"), [.set("whiteBalance", 3)], "near-miss option")
        XCTAssertEqual(parse("white balance auto"), [.set("whiteBalance", 1)], "the option, not the Auto action")
        XCTAssertEqual(parse("white balance"), [.select("whiteBalance")])
    }

    func testActionsRunWhenNamed() {
        XCTAssertEqual(parse("auto"), [.run("auto")])
        XCTAssertEqual(parse("auto tone"), [.run("auto")])
        XCTAssertEqual(parse("auto highlights 20"), [.run("auto"), .set("highlights", 20)])
        XCTAssertEqual(Command.run("auto").json, #"{"control":"auto","op":"run"}"#)
    }

    func testApplierRunsActionsThroughTheHandlerInOrder() {
        var applier = CommandApplier(registry: registry)
        var state = EditState()
        var focus: String?
        XCTAssertEqual(applier.apply([.run("auto")], state: &state, focus: &focus), [.ran(controlID: "auto")])

        applier.actionHandler = { id in id == "auto" ? [.set("highlights", -40), .set("hdr", 0)] : [] }
        XCTAssertEqual(
            applier.apply([.set("highlights", 10), .run("auto"), .nudge("highlights", 1)], state: &state, focus: &focus),
            [.changed(controlID: "highlights", from: 0, to: 10), .ran(controlID: "auto"),
             .changed(controlID: "highlights", from: 10, to: -40), .changed(controlID: "highlights", from: -40, to: -35)]
        )
    }

    func testToggleClampsToOnAndOff() {
        var interpreter = CommandInterpreter(registry: registry)
        var state = EditState()
        XCTAssertEqual(interpreter.interpret("hdr on", state: &state), [.changed(controlID: "hdr", from: 0, to: 1)])
        XCTAssertEqual(interpreter.interpret("more", state: &state), [.unchanged(controlID: "hdr", value: 1)])
        XCTAssertEqual(interpreter.interpret("hdr off", state: &state), [.changed(controlID: "hdr", from: 1, to: 0)])
    }

    func testOldControlsJSONStillLoadsAndKindsFillDefaults() throws {
        let json = """
        {"controls": [
          {"id": "contrast", "label": "Contrast", "synonyms": ["punch"], "min": -100, "max": 100, "default": 0, "step": 5},
          {"id": "hdr", "label": "HDR", "group": "light", "kind": "toggle"},
          {"id": "auto", "label": "Auto", "group": "light", "kind": "action"},
          {"id": "wb", "label": "White Balance", "group": "color", "kind": "choice",
           "options": [{"id": "asShot", "label": "As Shot"}, {"id": "cloudy", "label": "Cloudy"}]}
        ]}
        """
        let registry = try ControlRegistry.decode(Data(json.utf8))
        let contrast = registry.control(id: "contrast")!
        XCTAssertEqual(contrast.kind, .slider)
        XCTAssertEqual(contrast.group, "other")
        let hdr = registry.control(id: "hdr")!
        XCTAssertEqual([hdr.min, hdr.max, hdr.defaultValue, hdr.step], [0, 1, 0, 1])
        XCTAssertEqual(registry.control(id: "auto")!.step, 0)
        XCTAssertEqual(registry.control(id: "wb")!.max, 1)
        XCTAssertEqual(registry.groups, ["other", "light", "color"])
    }

    func testBundledControlsAreWellFormed() throws {
        let registry = try ControlRegistry.bundled()
        XCTAssertEqual(Set(registry.controls.map(\.id)).count, registry.controls.count, "duplicate ids")
        var seen: [String: String] = [:]
        for control in registry.controls {
            XCTAssertNotEqual(control.group, "other", "\(control.id) needs a group")
            XCTAssertLessThanOrEqual(control.min, control.defaultValue, control.id)
            XCTAssertLessThanOrEqual(control.defaultValue, control.max, control.id)
            if control.kind == .curvePoint {
                XCTAssertNotNil(control.channel, control.id)
                XCTAssertNotNil(control.x, control.id)
            }
            // Each name points to exactly one control.
            for name in control.names {
                XCTAssertNil(seen[name], "“\(name)” is used by \(seen[name] ?? "") and \(control.id)")
                seen[name] = control.id
            }
        }
    }
}
