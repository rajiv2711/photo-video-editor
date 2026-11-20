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
        for id in ["texture", "clarity", "dehaze", "vignette", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "vignetteHighlights",
                   "grain", "grainSize", "grainRoughness", "glow", "halation",
                   "posterize", "posterizeLevels", "threshold", "thresholdLevel", "solarize"] {
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

    // MARK: - Vignette

    func testVignetteNames() {
        XCTAssertEqual(parse("vignette -60"), [.set("vignette", -60)])
        XCTAssertEqual(parse("add a vignette"), [.nudge("vignette", 1)])
        XCTAssertEqual(parse("vignette midpoint 30"), [.set("vignetteMidpoint", 30)])
        XCTAssertEqual(parse("vignette roundness up"), [.nudge("vignetteRoundness", 1)])
        XCTAssertEqual(parse("vignette feather 80"), [.set("vignetteFeather", 80)])
        XCTAssertEqual(parse("vignette highlights 40"), [.set("vignetteHighlights", 40)])
        XCTAssertEqual(parse("highlights 40"), [.set("highlights", 40)], "plain highlights stays the Light slider")
    }

    private func strength(_ u: Double, _ v: Double, aspect: Double = 1.5, midpoint: Double = 0.5,
                          roundness: Double = 0, feather: Double = 0.5) -> Double {
        Vignette.strength(u: u, v: v, aspect: aspect, midpoint: midpoint, roundness: roundness, feather: feather)
    }

    func testVignetteLeavesTheCentreAndDarkensTheCorners() {
        XCTAssertEqual(strength(0, 0), 0)
        XCTAssertEqual(strength(1, 1), 1)
        XCTAssertEqual(strength(-1, 1), strength(1, -1), "symmetric")
        XCTAssertLessThan(strength(0.5, 0), strength(0.9, 0))
    }

    func testMidpointMovesTheVignetteInwards() {
        XCTAssertGreaterThan(strength(0.6, 0.3, midpoint: 0), strength(0.6, 0.3, midpoint: 0.5))
        XCTAssertLessThan(strength(0.9, 0.9, midpoint: 1), strength(0.9, 0.9, midpoint: 0.5))
    }

    func testFeatherZeroIsAHardEdge() {
        let values = stride(from: 0.0, through: 1.4, by: 0.01).map { strength($0, 0, feather: 0) }
        XCTAssertEqual(values.filter { $0 > 0.01 && $0 < 0.99 }.count, 1, "one step, a cell wide")
    }

    func testRoundnessShapes() {
        // A circle: same strength at the same distance in pixels, across or along a 3:2 frame.
        let across = strength(0.5, 0, aspect: 1.5, midpoint: 0.2, roundness: 1)
        let along = strength(0, 0.75, aspect: 1.5, midpoint: 0.2, roundness: 1)
        XCTAssertEqual(across, along, accuracy: 1e-9)
        // Rectangular: even along each edge; an ellipse grows towards the corners.
        XCTAssertEqual(strength(0.8, 0, roundness: -1), strength(0.8, 0.5, roundness: -1), accuracy: 0.05)
        XCTAssertGreaterThan(strength(0.8, 0.5, roundness: 0) - strength(0.8, 0, roundness: 0), 0.3)
    }

    func testVignetteGrid() {
        XCTAssertEqual(Vignette.gridSize(width: 3000, height: 2000).width, 256)
        XCTAssertEqual(Vignette.gridSize(width: 3000, height: 2000).height, 171)
        let mask = Vignette.mask(width: 4, height: 2, midpoint: 0.5, roundness: 0, feather: 0.5)
        XCTAssertEqual(mask.count, 8)
        XCTAssertEqual(mask[0], mask[3])
        XCTAssertGreaterThan(mask[0], mask[1])
    }

    func testVignetteHighlightsSpareBrightAreas() {
        let table = Effects.vignetteHighlights(amount: 1)
        XCTAssertEqual(table.first, 0)
        XCTAssertEqual(table.last, 1)
    }

    // MARK: - Grain

    func testGrainNames() {
        XCTAssertEqual(parse("grain 30"), [.set("grain", 30)])
        XCTAssertEqual(parse("film grain more"), [.nudge("grain", 1)])
        XCTAssertEqual(parse("grain size 60"), [.set("grainSize", 60)])
        XCTAssertEqual(parse("grain roughness 80"), [.set("grainRoughness", 80)])
    }

    func testGrainScalesWithThePhoto() {
        XCTAssertEqual(Effects.grainCell(size: 0, longSide: 2048), 1)
        XCTAssertEqual(Effects.grainCell(size: 1, longSide: 2048), 4)
        XCTAssertEqual(Effects.grainCell(size: 1, longSide: 4096), 8, "the saved photo matches the preview")
        XCTAssertEqual(Effects.grainCell(size: 0, longSide: 800), 1, "never under a pixel")
        XCTAssertEqual(Effects.grainContrast(amount: 0), 0)
        XCTAssertEqual(Effects.grainContrast(amount: 2), Effects.grainContrast(amount: 1))
    }

    // MARK: - Glow

    func testGlowNames() {
        XCTAssertEqual(parse("glow 40"), [.set("glow", 40)])
        XCTAssertEqual(parse("bloom more"), [.nudge("glow", 1)])
        XCTAssertEqual(parse("halation 60"), [.set("halation", 60)])
    }

    func testHalationComesFromTheBrightEndAndIsRed() {
        let table = Effects.halationSource()
        XCTAssertEqual(table[32], 0, "midtones send no light")
        XCTAssertEqual(table.last, 1)
        XCTAssertGreaterThan(Effects.halationTint.r, 2 * Effects.halationTint.g)
        XCTAssertGreaterThan(Effects.halationTint.g, Effects.halationTint.b)
    }

    // MARK: - Posterize, threshold, solarize

    func testPosterizeNames() {
        XCTAssertEqual(parse("posterize"), [.set("posterize", 1)])
        XCTAssertEqual(parse("posterise off"), [.set("posterize", 0)])
        XCTAssertEqual(parse("posterize levels 6"), [.set("posterizeLevels", 6)])
    }

    func testPosterizeHasThatManyLevels() {
        for levels in [2, 4, 7] {
            let table = Effects.posterize(levels: levels)
            XCTAssertEqual(Set(table).count, levels, "\(levels)")
            XCTAssertEqual(table.first, 0)
            XCTAssertEqual(table.last, 1)
        }
        XCTAssertEqual(Effects.posterize(levels: 2)[400], 0)
        XCTAssertEqual(Effects.posterize(levels: 2)[600], 1)
    }

    func testThresholdNames() {
        XCTAssertEqual(parse("threshold on"), [.set("threshold", 1)])
        XCTAssertEqual(parse("threshold level 90"), [.set("thresholdLevel", 90)])
        XCTAssertEqual(parse("threshold cutoff up"), [.nudge("thresholdLevel", 1)])
    }

    func testThresholdCutsAtItsLevel() {
        let table = Effects.threshold(level: 128)
        XCTAssertEqual(Set(table), [0, 1])
        XCTAssertEqual(table[Int(127.0 / 255 * 1023)], 0)
        XCTAssertEqual(table[Int(129.0 / 255 * 1023)], 1)
    }

    func testSolarizeNames() {
        XCTAssertEqual(parse("solarize 50"), [.set("solarize", 50)])
        XCTAssertEqual(parse("solarise more"), [.nudge("solarize", 1)])
    }

    func testSolarizeFoldsTheBrightLevels() {
        let classic = Effects.solarize(amount: 0.5)
        XCTAssertEqual(classic[200], 200.0 / 1023, accuracy: 1e-12, "darks untouched")
        XCTAssertEqual(classic[1023], 0, "white turns black")
        XCTAssertEqual(classic[767], 1 - 767.0 / 1023, accuracy: 1e-12)
        let full = Effects.solarize(amount: 1)
        XCTAssertEqual(full[0], 1)
        XCTAssertEqual(full[1023], 0)
        XCTAssertEqual(Effects.solarize(amount: 0), Effects.table(count: Effects.stepTableSize) { $0 }, "0 is off")
    }
}
