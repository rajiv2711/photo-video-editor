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

    func testNearMissesTryCreativeNamesLast() {
        XCTAssertEqual(parse("light up"), [.nudge("curveLights", 1)], "still the Lights curve")
        XCTAssertEqual(parse("embosss"), [.select("emboss")])
        XCTAssertEqual(parse("spherise 40"), [.set("spherize", 40)])
        XCTAssertEqual(parse("place center"), [.run("placeCenter")])
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
        XCTAssertEqual(CreativeFilters.zoomLength(60, longSide: 800), 12, accuracy: 1e-9)
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

    // MARK: - Stylize

    func testStylizeNames() {
        XCTAssertEqual(parse("oil paint"), [.select("oilPaint")])
        XCTAssertEqual(parse("oil painting 70"), [.set("oilPaint", 70)])
        XCTAssertEqual(parse("emboss"), [.select("emboss")])
        XCTAssertEqual(parse("find edges"), [.select("findEdges")])
        XCTAssertEqual(parse("wind 80 wind direction 180"), [.set("wind", 80), .set("effectAngle", 180)])
        run("find edges")
        XCTAssertEqual(value("findEdges"), 100, "Find Edges turns fully on")
        // Older names keep their meaning.
        XCTAssertEqual(parse("long edge 2000"), [.set("longEdge", 2000)])
        XCTAssertEqual(parse("fill edges"), [.set("fillEdges", 1)])
    }

    func testStylizeSizesFollowThePicture() {
        XCTAssertEqual(CreativeFilters.oilRadius(50, longSide: 800), 4, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.emboss(50, longSide: 4000).offset, 8, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.emboss(50, longSide: 100).offset, 1, "at least a pixel")
        XCTAssertEqual(CreativeFilters.emboss(50, longSide: 800).height, 4, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.embossLightAngle(0), 135, "from the top-left")
        XCTAssertEqual(CreativeFilters.wind(100, longSide: 1000).length, 80, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.edgeOffset(longSide: 400), 1)
    }

    // MARK: - Pixelate

    func testPixelateNames() {
        XCTAssertEqual(parse("mosaic 12"), [.set("mosaic", 12)])
        XCTAssertEqual(parse("pixelate"), [.select("mosaic")])
        XCTAssertEqual(parse("crystallize"), [.select("crystallize")])
        XCTAssertEqual(parse("halftone 40"), [.set("halftone", 40)])
        // Older names keep their meaning.
        XCTAssertEqual(parse("pixel size 2000"), [.set("longEdge", 2000)])
        XCTAssertEqual(parse("colour more"), [.ambiguous("colour", ["vibrance", "saturation"])])
    }

    func testPixelateSizesFollowThePicture() {
        XCTAssertEqual(CreativeFilters.mosaicCell(12, longSide: 1000), 9.6, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.crystalRadius(50, longSide: 800), 24, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.halftoneSpacing(30, longSide: 800), 9.6, accuracy: 1e-9)
    }

    // MARK: - Artistic

    func testArtisticNames() {
        XCTAssertEqual(parse("watercolour"), [.select("watercolor")])
        XCTAssertEqual(parse("water color 80"), [.set("watercolor", 80)])
        XCTAssertEqual(parse("sketch"), [.select("sketch")])
        XCTAssertEqual(parse("pencil sketch 50"), [.set("sketch", 50)])
        XCTAssertEqual(parse("cartoon"), [.select("cartoon")])
        XCTAssertEqual(parse("comic dots"), [.select("halftone")], "the longer name wins")
        XCTAssertEqual(parse("cutout"), [.select("cutout")])
        XCTAssertEqual(parse("cut out 70"), [.set("cutout", 70)])
    }

    func testToneBandsFollowThePicturesOwnBrightness() {
        // Most pixels light (a background), a third dark (the subject).
        var histogram = [Double](repeating: 0, count: 256)
        for i in 0..<50 { histogram[i] = 10 }
        for i in 190..<240 { histogram[i] = 20 }
        let table = CreativeFilters.toneBands(histogram: histogram, levels: 6)
        XCTAssertEqual(table.count, 256)
        XCTAssertLessThanOrEqual(Set(table).count, 6)
        XCTAssertEqual(zip(table, table.dropFirst()).allSatisfy { $0 <= $1 }, true, "darker stays darker")
        XCTAssertGreaterThanOrEqual(Set(table[0..<40]).count, 2, "the dark subject keeps more than one tone")
        XCTAssertGreaterThanOrEqual(Set(table[190..<240]).count, 2)
        XCTAssertEqual(table[10], 10.5 / 256, accuracy: 0.1, "each tone is its band's mean")
        XCTAssertEqual(CreativeFilters.toneBands(histogram: [], levels: 4)[255], 1, "no picture: unchanged")
    }

    func testArtisticSizes() {
        XCTAssertEqual(CreativeFilters.cutoutLevels(0), 8)
        XCTAssertEqual(CreativeFilters.cutoutLevels(50), 6)
        XCTAssertEqual(CreativeFilters.cutoutLevels(100), 3)
        XCTAssertEqual(CreativeFilters.paintRadius(50, longSide: 800, cutout: true), 4.8, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.sketchStroke(0, longSide: 1000), 2, accuracy: 1e-9)
        let table = CreativeFilters.sketchTable(50)
        XCTAssertEqual(table[255], 1, accuracy: 1e-9)
        XCTAssertLessThan(table[128], 128.0 / 255, "darker")
    }

    // MARK: - Lens flare

    func testLensFlareNames() {
        XCTAssertEqual(parse("lens flare"), [.select("lensFlare")])
        XCTAssertEqual(parse("lens flare 80"), [.set("lensFlare", 80)])
        XCTAssertEqual(parse("flare size 50"), [.set("effectSize", 50)])
        XCTAssertEqual(parse("place flare"), [.run("placeCenter")])
        XCTAssertTrue(CreativeFilters.centered.contains("lensFlare"), "naming it lets a tap place the light")
    }

    func testFlareGhostsRunThroughTheMiddle() {
        let middle = Vec2(400, 300)
        let axis = CreativeFilters.flareAxis(source: Vec2(100, 100), middle: middle, size: 100)
        XCTAssertEqual(axis.x, 300, accuracy: 1e-9)
        XCTAssertEqual(axis.y, 200, accuracy: 1e-9)
        let centred = CreativeFilters.flareAxis(source: middle, middle: middle, size: 100)
        XCTAssertGreaterThan(centred.length, 100, "a light in the middle still spreads its ghosts")
        XCTAssertTrue(CreativeFilters.flareGhosts.allSatisfy { $0.radius > 0 && $0.strength > 0 && $0.at > 0 })
        XCTAssertEqual(CreativeFilters.flareSize(size: 0.3, longSide: 800), 120, accuracy: 1e-9)
        XCTAssertEqual(CreativeFilters.flareStrength(50), 0.6, accuracy: 1e-9)
    }

    // MARK: - Lighting

    func testLightingNames() {
        XCTAssertEqual(parse("spotlight"), [.select("spotlight")])
        XCTAssertEqual(parse("spot light 80"), [.set("spotlight", 80)])
        XCTAssertEqual(parse("omni light center y 15"), [.select("omniLight"), .set("effectCenterY", 15)])
        XCTAssertEqual(parse("light size 40"), [.set("effectSize", 40)])
        // Older names keep their meaning.
        XCTAssertEqual(parse("spot 2"), [.set("spot", 2)])
        XCTAssertEqual(parse("lights more"), [.nudge("curveLights", 1)])
        XCTAssertEqual(parse("portrait lighting stage"), [.set("portraitLighting", 3)])
    }

    func testLightsBrightenTheirPoolAndDimTheRest() {
        let omni = CreativeFilters.lightPool(100, size: 0.3, longSide: 1000, spot: false)
        let down = Vec2(0, 1)
        XCTAssertEqual(CreativeFilters.lightGain(Vec2(0, 0), beam: down, pool: omni), 1.4, accuracy: 1e-9, "the middle of the pool")
        XCTAssertEqual(CreativeFilters.lightGain(Vec2(900, 0), beam: down, pool: omni), 0.3, accuracy: 1e-3, "far away: the ambient light")
        XCTAssertEqual(CreativeFilters.lightGain(Vec2(150, 0), beam: down, pool: omni),
                       CreativeFilters.lightGain(Vec2(0, -150), beam: down, pool: omni), accuracy: 1e-9, "round")
        let spot = CreativeFilters.lightPool(100, size: 0.3, longSide: 1000, spot: true)
        XCTAssertGreaterThan(CreativeFilters.lightGain(Vec2(0, 200), beam: down, pool: spot),
                             CreativeFilters.lightGain(Vec2(200, 0), beam: down, pool: spot), "an oval along the beam")
        XCTAssertGreaterThan(CreativeFilters.lightGain(Vec2(0, -150), beam: down, pool: spot),
                             CreativeFilters.lightGain(Vec2(0, 150), beam: down, pool: spot), "brighter towards the light")
        XCTAssertEqual(CreativeFilters.lightPool(0, size: 0.3, longSide: 1000, spot: true).ambient, 1, "off: no change")
    }

    // MARK: - Film effects

    func testFilmNames() {
        XCTAssertEqual(parse("light leak"), [.select("lightLeak")])
        XCTAssertEqual(parse("light leaks 80"), [.set("lightLeak", 80)])
        XCTAssertEqual(parse("dust and scratches"), [.select("dustAndScratches")])
        XCTAssertEqual(parse("dust and scratches 30"), [.set("dustAndScratches", 30)])
        XCTAssertEqual(parse("reset dust and scratches"), [.reset("dustAndScratches")])
        // Older names keep their meaning.
        XCTAssertEqual(parse("dust threshold 40"), [.set("visualizeThreshold", 40)])
        XCTAssertEqual(parse("light up"), [.nudge("curveLights", 1)])
    }

    func testDustAndScratchesAreTheSameEveryTime() {
        let a = CreativeFilters.dustAndScratches(100), b = CreativeFilters.dustAndScratches(100)
        XCTAssertEqual(a.specks, b.specks)
        XCTAssertEqual(a.scratches, b.scratches)
        XCTAssertEqual(a.specks.count, 60)
        XCTAssertEqual(a.hairs.count, 6)
        XCTAssertEqual(a.scratches.count, 5)
        XCTAssertTrue(a.specks.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) && $0.radius > 0 && $0.opacity <= 1 })
        XCTAssertTrue(a.specks.contains { $0.light } && a.specks.contains { !$0.light }, "dirt and holes")
        XCTAssertTrue(a.scratches.allSatisfy { $0.top < $0.bottom && $0.bottom <= 1 })
        let half = CreativeFilters.dustAndScratches(50)
        XCTAssertEqual(half.specks.count, 30, "half the amount, half the dust")
        XCTAssertEqual(half.specks.first?.x, a.specks.first?.x, "the same specks, not new ones")
        XCTAssertLessThan(half.specks[0].opacity, a.specks[0].opacity, "and fainter")
        XCTAssertTrue(CreativeFilters.dustAndScratches(0).specks.isEmpty)
    }

    func testLightLeaksComeFromTheEdges() {
        XCTAssertTrue(CreativeFilters.lightLeaks.allSatisfy { $0.x < 0.15 || $0.x > 0.85 })
        XCTAssertTrue(CreativeFilters.lightLeaks.allSatisfy { $0.color.r >= $0.color.b }, "warm")
        XCTAssertEqual(CreativeFilters.leakStrength(150), 1)
    }

    // MARK: - Frames

    func testFrameNames() {
        XCTAssertEqual(parse("frame white"), [.set("frame", 1)])
        XCTAssertEqual(parse("white frame"), [.set("frame", 1)])
        XCTAssertEqual(parse("polaroid frame"), [.set("frame", 3)])
        XCTAssertEqual(parse("frame off"), [.set("frame", 0)])
        XCTAssertEqual(parse("reset frame"), [.reset("frame")])
        XCTAssertEqual(parse("frame black frame width 10"), [.set("frame", 2), .set("frameWidth", 10)])
        // Older names keep their meaning.
        XCTAssertEqual(parse("border 5"), [.set("canvasBorder", 5)], "a border is still Canvas Size")
        XCTAssertEqual(parse("canvas color white"), [.set("canvasColor", 0)])
        XCTAssertEqual(parse("key frame 12"), [.set("keyFrame", 12)])
        XCTAssertEqual(parse("crop frame"), [.run("cropTool")])
        XCTAssertEqual(registry.control(id: "frame")?.options.map(\.id), CreativeFilters.frameStyles)
    }

    func testFrameLayouts() {
        XCTAssertNil(CreativeFilters.frameLayout("none", size: 4, width: 600, height: 800))
        let white = CreativeFilters.frameLayout("white", size: 4, width: 600, height: 800)!
        XCTAssertEqual([white.left, white.top, white.right, white.bottom], [32, 32, 32, 32])
        let polaroid = CreativeFilters.frameLayout("polaroid", size: 4, width: 600, height: 800)!
        XCTAssertEqual(polaroid.bottom, 3.5 * polaroid.top, accuracy: 1e-9, "a deep bottom to write on")
        XCTAssertGreaterThan(CreativeFilters.frameLayout("rounded", size: 4, width: 600, height: 800)!.corner, 0)
        XCTAssertGreaterThan(CreativeFilters.frameLayout("mat", size: 4, width: 600, height: 800)!.line, 0)

        let film = CreativeFilters.frameLayout("film", size: 4, width: 600, height: 800)!
        XCTAssertGreaterThan(film.left, film.top, "upright: the deep bands run down the long sides")
        XCTAssertFalse(film.holes.isEmpty)
        for hole in film.holes {
            XCTAssertTrue(hole.x >= 0 && hole.x + hole.width <= 600 && hole.y >= 0 && hole.y + hole.height <= 800)
            XCTAssertTrue(hole.x + hole.width <= film.left || hole.x >= 600 - film.right, "holes sit in the bands")
        }
        let wide = CreativeFilters.frameLayout("film", size: 4, width: 800, height: 600)!
        XCTAssertGreaterThan(wide.top, wide.left, "landscape: along the top and bottom")
    }
}
