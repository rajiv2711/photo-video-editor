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

    // MARK: - Tilt-shift, iris and field blur

    func testTiltShiftNames() {
        XCTAssertEqual(parse("tilt shift"), [.select("tiltShift")])
        XCTAssertEqual(parse("tilt-shift 60"), [.set("tiltShift", 60)])
        XCTAssertEqual(parse("miniature effect 70"), [.set("tiltShift", 70)])
        XCTAssertEqual(parse("iris blur"), [.select("irisBlur")])
        XCTAssertEqual(parse("field blur 40"), [.set("fieldBlur", 40)])
        XCTAssertEqual(parse("tilt shift effect size 60"), [.select("tiltShift"), .set("effectSize", 60)])
        XCTAssertEqual(parse("tilt shift angle 30"), [.set("effectAngle", 30)])
        run("tilt shift")
        XCTAssertEqual(value("tiltShift"), 50)
    }

    /// The mask at a cell of a 100 × 100 grid.
    private func mask(_ kind: CreativeFilters.FocusBlur, _ x: Int, _ y: Int, size: Double = 0.3, angle: Double = 0,
                      center: MaskPoint = MaskPoint(0.5, 0.5)) -> Float {
        CreativeFilters.focusMask(kind, width: 100, height: 100, center: center, size: size, angle: angle)[y * 100 + x]
    }

    func testTiltShiftIsSharpAlongALevelBandThroughTheCenter() {
        XCTAssertEqual(mask(.tiltShift, 5, 50), 0, "sharp along the band, even at the side")
        XCTAssertEqual(mask(.tiltShift, 50, 54), 0, "sharp within 0.2 × size × 100 = 6 cells")
        XCTAssertEqual(mask(.tiltShift, 50, 2), 1, "fully blurred far above")
        XCTAssertEqual(mask(.tiltShift, 50, 97), 1, "and far below")
        XCTAssertGreaterThan(mask(.tiltShift, 50, 65), 0)
        XCTAssertLessThan(mask(.tiltShift, 50, 65), 1, "a soft change in between")
        XCTAssertEqual(mask(.tiltShift, 50, 2, angle: 90), 0, "turned upright: sharp up and down the middle")
        XCTAssertEqual(mask(.tiltShift, 2, 50, angle: 90), 1)
        XCTAssertEqual(mask(.tiltShift, 50, 22, center: MaskPoint(0.5, 0.2)), 0, "the band follows the centre")
    }

    func testIrisIsSharpInACircleAndFieldBelowALine() {
        XCTAssertEqual(mask(.iris, 50, 50), 0)
        XCTAssertEqual(mask(.iris, 60, 50), 0, "sharp within 0.5 × size × 100 = 15 cells")
        XCTAssertEqual(mask(.iris, 2, 2), 1, "the corners are fully blurred")
        XCTAssertEqual(mask(.iris, 50, 21), mask(.iris, 78, 50), accuracy: 1e-6, "round")
        XCTAssertEqual(mask(.field, 50, 90), 0, "sharp below the line")
        XCTAssertEqual(mask(.field, 50, 51), 0)
        XCTAssertGreaterThan(mask(.field, 50, 30), mask(.field, 50, 45), "more blurred higher up")
        XCTAssertEqual(mask(.field, 50, 10), 1, "fully blurred size × 100 = 30 cells above")
        XCTAssertEqual(mask(.field, 50, 10, angle: 180), 0, "turned over: blurred below instead")
    }

    func testFocusBlurRadiusFollowsThePicture() {
        XCTAssertEqual(CreativeFilters.focusBlurRadius(50, longSide: 800), 12, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.focusBlurRadius(-10, longSide: 800), 0)
    }

    // MARK: - Distort

    func testDistortNames() {
        XCTAssertEqual(parse("twirl 90"), [.set("twirl", 90)])
        XCTAssertEqual(parse("twirl -180"), [.set("twirl", -180)])
        XCTAssertEqual(parse("wave"), [.select("wave")])
        XCTAssertEqual(parse("ripple 60"), [.set("ripple", 60)])
        XCTAssertEqual(parse("pinch -40"), [.set("pinch", -40)])
        XCTAssertEqual(parse("spherize"), [.select("spherize")])
        XCTAssertEqual(parse("polar coordinates"), [.set("polarCoordinates", 1)])
        XCTAssertEqual(parse("tiny planet off"), [.set("polarCoordinates", 0)])
        XCTAssertEqual(parse("twirl radius 60"), [.set("effectSize", 60)])
        XCTAssertEqual(parse("wavelength more"), [.nudge("effectSize", 1)])
        run("twirl")
        XCTAssertEqual(value("twirl"), 90, "a quarter turn")
        // Older names keep their meaning.
        XCTAssertEqual(parse("distortion 30"), [.set("distortion", 30)])
        XCTAssertEqual(parse("liquify twirl"), [.run("liquify", value: 1)])
        XCTAssertEqual(parse("liquify mode pinch"), [.set("liquifyMode", 2)])
    }

    func testPinchPullsTheMiddleInAndLeavesTheOutsideAlone() {
        let k = CreativeFilters.pinchPower(50)
        XCTAssertEqual(k, 0.4, accuracy: 1e-9)
        let inside = CreativeFilters.pinchSource(Vec2(30, 0), radius: 100, power: k)
        XCTAssertGreaterThan(inside.x, 30, "reads farther out: the picture is pulled in")
        XCTAssertEqual(inside.y, 0, accuracy: 1e-9, "along the same line")
        XCTAssertLessThan(CreativeFilters.pinchSource(Vec2(30, 0), radius: 100, power: -k).x, 30, "negative swells")
        let outside = CreativeFilters.pinchSource(Vec2(0, 150), radius: 100, power: k)
        XCTAssertEqual(outside.y, 150, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.pinchSource(Vec2(99.999, 0), radius: 100, power: k).x, 100, accuracy: 0.01, "no step at the rim")
    }

    func testSpherizeSwellsTheMiddleAndSqueezesTheRim() {
        let middle = CreativeFilters.spherizeSource(Vec2(10, 0), radius: 100, amount: 1)
        XCTAssertLessThan(middle.x, 10, "reads nearer the centre: magnified")
        XCTAssertGreaterThan(CreativeFilters.spherizeSource(Vec2(10, 0), radius: 100, amount: -1).x, 10, "negative shrinks the middle")
        XCTAssertEqual(CreativeFilters.spherizeSource(Vec2(0, 50), radius: 100, amount: 0).y, 50, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.spherizeSource(Vec2(0, 120), radius: 100, amount: 1).y, 120, "outside: unmoved")
        XCTAssertEqual(CreativeFilters.spherizeSource(Vec2(0, 99.99), radius: 100, amount: 1).y, 100, accuracy: 1, "no step at the rim")
    }

    func testPolarCoordinatesPutTheBottomEdgeInTheMiddle() {
        let w = 300.0, h = 400.0
        XCTAssertEqual(CreativeFilters.polarSource(Vec2(0, 0.001), width: w, height: h).y, h, accuracy: 0.01, "the middle reads the bottom edge")
        let corner = CreativeFilters.polarSource(Vec2(150, 200), width: w, height: h)
        XCTAssertEqual(corner.y, 0, accuracy: 1e-9, "the corners read the top edge")
        XCTAssertEqual(CreativeFilters.polarSource(Vec2(0, 100), width: w, height: h).x, 150, accuracy: 1e-9, "straight down: the middle column")
        XCTAssertEqual(CreativeFilters.polarSource(Vec2(-100, 0), width: w, height: h).x, 225, accuracy: 1e-9, "a quarter turn on: three quarters across")
    }

    func testWaveAndRippleSizesFollowThePicture() {
        let wave = CreativeFilters.wave(100, size: 0.3, longSide: 1000)
        XCTAssertEqual(wave.amplitude, 30, accuracy: 1e-9)
        XCTAssertEqual(wave.wavelength, 150, accuracy: 1e-9)
        let ripple = CreativeFilters.ripple(40, size: 0.3, longSide: 1000)
        XCTAssertEqual(ripple.amplitude, 6, accuracy: 1e-9)
        XCTAssertEqual(ripple.wavelength, 75, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.distortRadius(size: 0.3, longSide: 800), 240, accuracy: 1e-9)
    }
}
