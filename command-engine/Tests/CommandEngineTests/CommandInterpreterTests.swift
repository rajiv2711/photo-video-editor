import XCTest
@testable import CommandEngine

final class CommandInterpreterTests: XCTestCase {
    private var registry: ControlRegistry!
    private var interpreter: CommandInterpreter!
    private var state: EditState!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        interpreter = CommandInterpreter(registry: registry)
        state = EditState()
    }

    private func run(_ text: String) -> [CommandInterpreter.Outcome] {
        interpreter.interpret(text, state: &state)
    }

    private func value(_ id: String) -> Double {
        state.value(of: registry.control(id: id)!)
    }

    func testBundledRegistryStartsWithTheLightPanel() {
        XCTAssertEqual(registry.controls.prefix(2).map(\.id), ["exposure", "contrast"])
        XCTAssertEqual(registry.groups.first, "light")
    }

    func testRepeatedMoreStacksSteps() {
        XCTAssertEqual(run("contrast more, more, more"), [.changed(controlID: "contrast", from: 0, to: 15)])
    }

    func testBareMoreRepeatsOnLastControl() {
        _ = run("contrast more")
        XCTAssertEqual(run("more"), [.changed(controlID: "contrast", from: 5, to: 10)])
    }

    func testTouchFocusIsUsedForBareMore() {
        interpreter.focus(controlID: "saturation")
        XCTAssertEqual(run("less less"), [.changed(controlID: "saturation", from: 0, to: -10)])
    }

    func testMoreWithoutAnyControlAsksForOne() {
        XCTAssertEqual(run("more more"), [.needsControl])
    }

    func testAbsoluteAndRelativeNumbers() {
        XCTAssertEqual(run("contrast 20"), [.changed(controlID: "contrast", from: 0, to: 20)])
        XCTAssertEqual(run("contrast up by 15"), [.changed(controlID: "contrast", from: 20, to: 35)])
        XCTAssertEqual(run("contrast down 5"), [.changed(controlID: "contrast", from: 35, to: 30)])
        XCTAssertEqual(run("contrast minus 40"), [.changed(controlID: "contrast", from: 30, to: -40)])
    }

    func testDecimalsAndFloatingPointDriftForExposure() {
        XCTAssertEqual(run("exposure more more more"), [.changed(controlID: "exposure", from: 0, to: 0.3)])
        XCTAssertEqual(run("exposure 0.5"), [.changed(controlID: "exposure", from: 0.3, to: 0.5)])
    }

    func testSeveralControlsInOneSentence() {
        XCTAssertEqual(run("saturation less exposure more"), [
            .changed(controlID: "saturation", from: 0, to: -5),
            .changed(controlID: "exposure", from: 0, to: 0.1),
        ])
    }

    func testClampsAtTheRangeAndReportsNoChange() {
        XCTAssertEqual(run("contrast max"), [.changed(controlID: "contrast", from: 0, to: 100)])
        XCTAssertEqual(run("contrast more"), [.unchanged(controlID: "contrast", value: 100)])
    }

    func testResetOneAndAll() {
        _ = run("contrast 50 saturation 20")
        XCTAssertEqual(run("contrast reset"), [.changed(controlID: "contrast", from: 50, to: 0)])
        XCTAssertEqual(run("reset all"), [.changed(controlID: "saturation", from: 20, to: 0)])
    }

    func testTyposPrefixesAndSynonyms() {
        XCTAssertEqual(run("contrst more"), [.changed(controlID: "contrast", from: 0, to: 5)])
        XCTAssertEqual(run("satur up"), [.changed(controlID: "saturation", from: 0, to: 5)])
        XCTAssertEqual(run("vividness down"), [.changed(controlID: "saturation", from: 5, to: 0)])
        // "colour" fits Vibrance and Saturation alike: the user picks.
        XCTAssertEqual(run("colour down"), [.ambiguous(word: "colour", candidateIDs: ["vibrance", "saturation"])])
        XCTAssertEqual(run("colours up"), [.ambiguous(word: "colours", candidateIDs: ["vibrance", "saturation"])])
    }

    func testFillerWordsAreIgnored() {
        XCTAssertEqual(run("make the contrast a little bit more please"), [.changed(controlID: "contrast", from: 0, to: 5)])
        XCTAssertEqual(run("set contrast to 25"), [.changed(controlID: "contrast", from: 5, to: 25)])
    }

    func testUnknownNameBlocksActionsInsteadOfHittingTheWrongSlider() {
        _ = run("contrast more")
        XCTAssertEqual(run("wobble more"), [.unknown(word: "wobble")])
        XCTAssertEqual(value("contrast"), 5)
    }

    func testAmbiguousNameOffersChoices() {
        let registry = ControlRegistry(controls: [
            Control(id: "shadows", label: "Shadows", min: -100, max: 100, defaultValue: 0, step: 5),
            Control(id: "shading", label: "Shading", min: -100, max: 100, defaultValue: 0, step: 5),
        ])
        var interpreter = CommandInterpreter(registry: registry)
        var state = EditState()
        XCTAssertEqual(
            interpreter.interpret("shad more", state: &state),
            [.ambiguous(word: "shad", candidateIDs: ["shadows", "shading"])]
        )
    }

    func testTwoWordNames() {
        let registry = ControlRegistry(controls: [
            Control(id: "whiteBalance", label: "White Balance", synonyms: ["temperature"], min: -100, max: 100, defaultValue: 0, step: 5),
        ])
        var interpreter = CommandInterpreter(registry: registry)
        var state = EditState()
        XCTAssertEqual(
            interpreter.interpret("white balance more", state: &state),
            [.changed(controlID: "whiteBalance", from: 0, to: 5)]
        )
    }
}
