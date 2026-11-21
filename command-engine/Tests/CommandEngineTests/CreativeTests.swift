import XCTest
@testable import CommandEngine

/// The Creative panel: names, naming a filter turns it on, the shared placement, and the maths
/// behind the filters (masks, overlays, frames) on small made-up pictures.
final class CreativeTests: XCTestCase {
    private var registry: ControlRegistry!
    private var parser: CommandParser!
    private var interpreter: CommandInterpreter!
    private var state: EditState!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        parser = CommandParser(registry: registry)
        interpreter = CommandInterpreter(registry: registry)
        state = EditState()
    }

    private func parse(_ text: String) -> [Command] {
        parser.parse(text)
    }

    @discardableResult
    private func run(_ text: String) -> [CommandOutcome] {
        interpreter.interpret(text, state: &state)
    }

    private func value(_ id: String) -> Double {
        state.value(of: registry.control(id: id)!)
    }

    // MARK: - Naming a filter turns it on

    func testNamingAFilterAloneTurnsItOnAndNumbersSetIt() {
        XCTAssertEqual(parse("zoom blur"), [.select("zoomBlur")])
        XCTAssertEqual(run("zoom blur"), [.changed(controlID: "zoomBlur", from: 0, to: 40)])
        XCTAssertEqual(run("zoom blur"), [.unchanged(controlID: "zoomBlur", value: 40)], "already on: naming only selects")
        XCTAssertEqual(run("zoom blur 70"), [.changed(controlID: "zoomBlur", from: 40, to: 70)])
        XCTAssertEqual(run("reset zoom blur"), [.changed(controlID: "zoomBlur", from: 70, to: 0)])
        XCTAssertEqual(run("more"), [.changed(controlID: "zoomBlur", from: 0, to: 5)])
    }

    func testOnlyCreativeSlidersTurnOnByName() {
        for control in registry.controls where control.on != nil {
            XCTAssertEqual(control.group, "creative", control.id)
            XCTAssertEqual(control.kind, .slider, control.id)
            XCTAssertNotEqual(control.on, control.defaultValue, control.id)
            XCTAssertEqual(control.clamp(control.on!), control.on, control.id)
        }
        run("vignette")
        XCTAssertEqual(value("vignette"), 0, "older sliders still only select")
    }

    // MARK: - Blur

    func testBlurNames() {
        XCTAssertEqual(parse("gaussian blur 20"), [.set("gaussianBlur", 20)])
        XCTAssertEqual(parse("blur 20"), [.set("gaussianBlur", 20)])
        XCTAssertEqual(parse("blur more"), [.nudge("gaussianBlur", 1)])
        XCTAssertEqual(parse("reset blur"), [.reset("gaussianBlur")])
        XCTAssertEqual(parse("motion blur 50"), [.set("motionBlur", 50)])
        XCTAssertEqual(parse("motion blur angle 45"), [.set("effectAngle", 45)])
        XCTAssertEqual(parse("radial blur"), [.select("zoomBlur")])
        XCTAssertEqual(parse("spin blur 30"), [.set("spinBlur", 30)])
        XCTAssertEqual(parse("effect center x 30 center y 70"), [.set("effectCenterX", 30), .set("effectCenterY", 70)])
        XCTAssertEqual(parse("place center"), [.run("placeCenter")])
        // Older names keep their meaning.
        XCTAssertEqual(parse("blur brush"), [.run("blurBrush")])
        XCTAssertEqual(parse("background blur more"), [.nudge("portraitAperture", 1)])
        XCTAssertEqual(parse("live photo motion blur"), [.set("livePhotoEffect", 3)])
        XCTAssertEqual(parse("radial gradient center"), [.run("radialGradient", value: 0)])
    }

    func testBlurSizesFollowThePicture() {
        XCTAssertEqual(CreativeFilters.gaussianRadius(50, longSide: 1000), 20, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.gaussianRadius(50, longSide: 4000), 4 * CreativeFilters.gaussianRadius(50, longSide: 1000), accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.motionLength(0, longSide: 1000), 0)
        XCTAssertEqual(CreativeFilters.spinAngle(100), 24 * .pi / 180, accuracy: 1e-9)
    }

    func testTheCenterComesFromTheSlidersOrATap() {
        let values: [String: Double] = ["effectCenterX": 25, "effectCenterY": 80]
        XCTAssertEqual(CreativeFilters.center { values[$0] }, MaskPoint(0.25, 0.8))
        XCTAssertEqual(CreativeFilters.center { _ in nil }, MaskPoint(0.5, 0.5))
        XCTAssertTrue(CreativeFilters.centerValues(MaskPoint(0.333, 1.2)) == (33, 100))
        XCTAssertNotNil(registry.control(id: CreativeFilters.centerPicker))
        for id in CreativeFilters.centered {
            XCTAssertEqual(registry.control(id: id)?.group, "creative", id)
        }
    }
}
