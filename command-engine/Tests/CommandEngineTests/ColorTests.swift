import XCTest
@testable import CommandEngine

/// The Color panel: names that reach its controls, and the colour math the iPad renderer uses.
final class ColorTests: XCTestCase {
    private var registry: ControlRegistry!
    private var parser: CommandParser!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        parser = CommandParser(registry: registry)
    }

    private func parse(_ text: String) -> [Command] {
        parser.parse(text)
    }

    /// Option ids of a choice control, in controls.json order.
    private func options(_ id: String) -> [String] {
        registry.control(id: id)?.options.map(\.id) ?? []
    }

    private func assertClose(_ a: Double, _ b: Double, _ accuracy: Double = 1e-6, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - White balance

    func testWhiteBalancePresetsMatchControlsJSON() {
        XCTAssertEqual(options("whiteBalance"), WhiteBalance.presetIDs)
    }

    func testWhiteBalancePresetNames() {
        XCTAssertEqual(parse("white balance tungsten"), [.set("whiteBalance", 5)])
        XCTAssertEqual(parse("wb cloudy"), [.set("whiteBalance", 3)])
        XCTAssertEqual(parse("white balance auto"), [.set("whiteBalance", 1)], "the preset, not the Auto action")
        XCTAssertEqual(parse("white balance as shot"), [.set("whiteBalance", 0)])
        XCTAssertEqual(parse("white balance sunny"), [.set("whiteBalance", 2)])
        XCTAssertEqual(parse("whites 20 white balance shade"), [.set("whites", 20), .set("whiteBalance", 4)])
    }

    func testWhiteBalancePickerIsAnActionThatRunsByName() {
        XCTAssertEqual(registry.control(id: "wbPicker")?.kind, .action)
        XCTAssertEqual(parse("white balance picker"), [.run("wbPicker")])
        XCTAssertEqual(parse("pick white"), [.run("wbPicker")])
        XCTAssertEqual(parse("white balance cloudy"), [.set("whiteBalance", 3)], "the picker's name doesn't swallow presets")
    }

    func testAsShotAndDaylightLeaveTheColoursAlone() {
        for preset in ["asShot", "auto", "daylight"] {
            let offset = WhiteBalance.offset(preset: preset)
            let g = WhiteBalance.gains(temperature: offset.temperature, tint: offset.tint)
            assertClose(g.r, 1, 1e-9, preset)
            assertClose(g.g, 1, 1e-9, preset)
            assertClose(g.b, 1, 1e-9, preset)
        }
    }

    func testPresetsCorrectForTheirLight() {
        func gains(_ preset: String) -> RGB {
            let o = WhiteBalance.offset(preset: preset)
            return WhiteBalance.gains(temperature: o.temperature, tint: o.tint)
        }
        // Tungsten light is orange, so the correction is blue.
        XCTAssertGreaterThan(gains("tungsten").b, 1.3)
        XCTAssertLessThan(gains("tungsten").r, 0.9)
        // Cloudy and shade light is bluish, so the correction is warm; shade more so.
        XCTAssertGreaterThan(gains("cloudy").r, gains("cloudy").b)
        XCTAssertGreaterThan(gains("shade").r / gains("shade").b, gains("cloudy").r / gains("cloudy").b)
        // Fluorescent light is green: the correction takes green out.
        let fluorescent = WhiteBalance.offset(preset: "fluorescent")
        XCTAssertLessThan(gains("fluorescent").g, WhiteBalance.gains(temperature: fluorescent.temperature, tint: 0).g)
    }

    func testGainsKeepBrightness() {
        for (t, tint) in [(-100.0, 0.0), (100, 0), (40, -60), (-169, 21)] {
            assertClose(WhiteBalance.gains(temperature: t, tint: tint).luma, 1, 1e-9)
        }
    }

    func testWarmerTemperatureRaisesRedAgainstBlue() {
        let warm = WhiteBalance.gains(temperature: 50, tint: 0)
        let cool = WhiteBalance.gains(temperature: -50, tint: 0)
        XCTAssertGreaterThan(warm.r, warm.b)
        XCTAssertLessThan(cool.r, cool.b)
        XCTAssertLessThan(WhiteBalance.gains(temperature: 0, tint: 50).g, 1, "positive tint is magenta")
    }

    func testNeutralizeUndoesACast() {
        for (t, tint) in [(-80.0, 0.0), (40, 20), (-150, -30), (0, 0)] {
            // A grey card photographed under a cast that these settings would correct.
            let cast = RGB(0.4, 0.4, 0.4) / WhiteBalance.gains(temperature: t, tint: tint)
            let found = WhiteBalance.neutralize(cast)
            assertClose(found.temperature, t, 0.01, "temperature for \(t), \(tint)")
            assertClose(found.tint, tint, 0.01, "tint for \(t), \(tint)")
        }
        let grey = WhiteBalance.neutralize(RGB(0.5, 0.5, 0.5))
        assertClose(grey.temperature, 0, 0.01)
        assertClose(grey.tint, 0, 0.01)
    }

    // MARK: - Color mixer

    /// A value lookup for ColorLook with only these controls changed.
    private func look(_ changed: [String: Double]) -> ColorLook.Values {
        ColorLook.Values { changed[$0] }
    }

    func testMixerControlsMatchColorLook() {
        for id in ColorLook.controlIDs where id.hasPrefix("mixer") {
            XCTAssertEqual(registry.control(id: id)?.section, "Color mixer", id)
        }
        XCTAssertEqual(registry.controls.filter { $0.section == "Color mixer" }.count, 24)
    }

    func testMixerTwoWordNames() {
        XCTAssertEqual(parse("red saturation 40"), [.set("mixerRedSaturation", 40)])
        XCTAssertEqual(parse("aqua hue -20"), [.set("mixerAquaHue", -20)])
        XCTAssertEqual(parse("orange luminance up"), [.nudge("mixerOrangeLuminance", 1)])
        XCTAssertEqual(parse("more blue saturation"), [.nudge("mixerBlueSaturation", 1)])
        XCTAssertEqual(parse("saturation 20"), [.set("saturation", 20)], "one word is still the global slider")
        XCTAssertEqual(parse("hue 20"), [.set("hue", 20)])
        XCTAssertEqual(parse("satur up"), [.nudge("saturation", 1)], "prefixes still find Saturation")
        XCTAssertEqual(parse("red curve 50 60"), [.set("curveRed50", 60)], "point curve names still win")
    }

    func testHSLRoundTrip() {
        for c in [RGB(0.9, 0.2, 0.1), RGB(0.1, 0.8, 0.5), RGB(0.3, 0.3, 0.9), RGB(0.5, 0.5, 0.5), RGB(1, 1, 0)] {
            let (h, s, l) = ColorLook.hsl(c)
            let back = ColorLook.rgb(hue: h, saturation: s, lightness: l)
            assertClose(back.r, c.r, 1e-9)
            assertClose(back.g, c.g, 1e-9)
            assertClose(back.b, c.b, 1e-9)
        }
        XCTAssertEqual(ColorLook.hsl(RGB(1, 0, 0)).h, 0)
        XCTAssertEqual(ColorLook.hsl(RGB(0, 0, 1)).h, 240)
    }

    func testBandWeightsShareBetweenNeighbours() {
        let red = ColorLook.bandWeights(hue: 0)
        XCTAssertEqual(red.first?.0, "red")
        XCTAssertEqual(red.first?.1, 1)
        let between = ColorLook.bandWeights(hue: 90)  // halfway yellow → green
        XCTAssertEqual(between.map(\.0), ["yellow", "green"])
        assertClose(between[0].1, 0.5)
        let wrap = ColorLook.bandWeights(hue: 330)  // halfway magenta → red
        XCTAssertEqual(wrap.map(\.0), ["magenta", "red"])
    }

    func testMixerChangesOnlyItsBand() {
        let red = RGB(0.8, 0.1, 0.1), blue = RGB(0.1, 0.2, 0.8), grey = RGB(0.5, 0.5, 0.5)
        let v = look([ColorLook.mixerID("red", "Saturation"): -100])
        let greyed = ColorLook.transform(red, v)
        assertClose(greyed.r, greyed.b, 1e-9)
        assertClose(greyed.r, greyed.g, 1e-9)
        XCTAssertEqual(ColorLook.transform(blue, v), blue)
        XCTAssertEqual(ColorLook.transform(grey, v), grey)
    }

    func testMixerHueAndLuminance() {
        let red = RGB(0.8, 0.1, 0.1)
        let towardOrange = ColorLook.transform(red, look([ColorLook.mixerID("red", "Hue"): 100]))
        assertClose(ColorLook.hsl(towardOrange).h, 30, 1e-6)
        let darker = ColorLook.transform(red, look([ColorLook.mixerID("red", "Luminance"): -100]))
        XCTAssertLessThan(darker.luma, red.luma * 0.8)
        let lighter = ColorLook.transform(red, look([ColorLook.mixerID("red", "Luminance"): 100]))
        XCTAssertGreaterThan(lighter.luma, red.luma)
    }

    func testCubeIsIdentityWhenUntouched() {
        XCTAssertTrue(ColorLook.isIdentity { _ in nil })
        XCTAssertFalse(ColorLook.isIdentity { $0 == "mixerRedHue" ? 10 : nil })
        let cube = ColorLook.cube({ _ in nil }, size: 5)
        XCTAssertEqual(cube.count, 5 * 5 * 5 * 4)
        // Entry for r = 1/4, g = 2/4, b = 3/4 sits at index (3 * 25 + 2 * 5 + 1) * 4.
        let i = (3 * 25 + 2 * 5 + 1) * 4
        XCTAssertEqual(Array(cube[i..<(i + 4)]), [0.25, 0.5, 0.75, 1])
    }

    // MARK: - Point color

    func testPointColorNames() {
        XCTAssertEqual(parse("point color picker"), [.run("pointColorPicker")])
        XCTAssertEqual(parse("target hue 200 point saturation -50"), [.set("pointHue", 200), .set("pointSaturationShift", -50)])
        XCTAssertEqual(parse("point hue 30"), [.set("pointHueShift", 30)])
        XCTAssertEqual(parse("red curve 50 60"), [.set("curveRed50", 60)])
        XCTAssertEqual(parse("point curve 50 60"), [.set("curveRgb50", 60)], "point curve keeps its name")
    }

    func testPointColorShiftsOnlyColoursNearTheTarget() {
        let v = look(["pointHue": 0, "pointSaturationShift": -100])
        let red = RGB(0.8, 0.1, 0.1), orange = RGB(0.9, 0.5, 0.1), blue = RGB(0.1, 0.2, 0.8), grey = RGB(0.4, 0.4, 0.4)
        let greyed = ColorLook.transform(red, v)
        assertClose(greyed.r, greyed.g, 1e-9)
        XCTAssertEqual(ColorLook.transform(blue, v), blue)
        XCTAssertEqual(ColorLook.transform(grey, v), grey)
        // Orange (30° away) is inside the default 35° but only partly.
        let o = ColorLook.transform(orange, v)
        XCTAssertLessThan(o.max - o.min, orange.max - orange.min)
        XCTAssertGreaterThan(o.max - o.min, 0.05)
        // A narrow range leaves orange alone.
        XCTAssertEqual(ColorLook.transform(orange, look(["pointHue": 0, "pointSaturationShift": -100, "pointRange": 0])), orange)
    }

    func testPointColorWrapsAroundRed() {
        let v = look(["pointHue": 355, "pointLuminanceShift": -100])
        XCTAssertLessThan(ColorLook.transform(RGB(0.8, 0.1, 0.12), v).luma, RGB(0.8, 0.1, 0.12).luma)
    }

    func testPickedHueIgnoresGreys() {
        XCTAssertNil(ColorLook.pickedHue(linear: RGB(0.2, 0.2, 0.21)))
        XCTAssertEqual(ColorLook.pickedHue(linear: RGB(0, 0, 0.5)) ?? -1, 240, accuracy: 1e-9)
    }

    func testTargetHueAloneChangesNothing() {
        XCTAssertTrue(ColorLook.isIdentity { $0 == "pointHue" ? 120 : nil })
        XCTAssertFalse(ColorLook.isIdentity { $0 == "pointHueShift" ? 10 : nil })
    }

    func testVarianceEvensOutHuesAroundTheTarget() {
        let orange = RGB(0.9, 0.5, 0.1)  // 30° from red
        let evened = ColorLook.transform(orange, look(["pointHue": 0, "pointRange": 100, "pointVariance": -100]))
        let h = ColorLook.hsl(evened).h
        XCTAssertLessThan(h, ColorLook.hsl(orange).h)
        XCTAssertGreaterThan(h, 0, "only partly: orange is halfway out of the range")
        let spread = ColorLook.transform(orange, look(["pointHue": 0, "pointRange": 100, "pointVariance": 100]))
        XCTAssertGreaterThan(ColorLook.hsl(spread).h, ColorLook.hsl(orange).h)
        let red = RGB(0.8, 0.1, 0.1)
        XCTAssertEqual(ColorLook.transform(red, look(["pointHue": 0, "pointVariance": -100])).r, red.r, accuracy: 1e-9,
                       "the target itself stays")
    }

    // MARK: - Color grading

    func testGradingNamesDontClashWithLight() {
        XCTAssertEqual(parse("shadows 40"), [.set("shadows", 40)])
        XCTAssertEqual(parse("shadows hue 220"), [.set("gradingShadowsHue", 220)])
        XCTAssertEqual(parse("shadows saturation up"), [.nudge("gradingShadowsSaturation", 1)])
        XCTAssertEqual(parse("highlights -30 highlights luminance 10"), [.set("highlights", -30), .set("gradingHighlightsLuminance", 10)])
        XCTAssertEqual(parse("midtones hue 40"), [.set("gradingMidtonesHue", 40)])
        XCTAssertEqual(parse("global saturation 20"), [.set("gradingGlobalSaturation", 20)])
        XCTAssertEqual(parse("tone curve shadows 20"), [.set("curveShadows", 20)])
        XCTAssertEqual(parse("balance 30"), [.set("gradingBalance", 30)])
        XCTAssertEqual(parse("white balance shade"), [.set("whiteBalance", 4)])
        XCTAssertEqual(parse("shadow up up up"), [.nudge("shadows", 3)])
    }

    func testGradingTintsOnlyItsZone() {
        let v = look(["gradingShadowsSaturation": 100, "gradingShadowsHue": 240])
        let dark = ColorLook.transform(RGB(0.1, 0.1, 0.1), v)
        XCTAssertGreaterThan(dark.b, dark.r, "dark greys turn blue")
        assertClose(dark.luma, 0.1, 1e-9, "tinting keeps luma")
        XCTAssertEqual(ColorLook.transform(RGB(0.9, 0.9, 0.9), v), RGB(0.9, 0.9, 0.9), "highlights untouched")
        let lit = ColorLook.transform(RGB(0.9, 0.9, 0.9), look(["gradingHighlightsLuminance": -100]))
        assertClose(lit.r, 0.9 - 0.15 * 0.8, 1e-9)
    }

    func testGradingBalanceAndBlendingWidenTheShadows() {
        let base = look(["gradingShadowsSaturation": 100])
        let mid = RGB(0.35, 0.35, 0.35)
        let plain = ColorLook.transform(mid, base).r
        let balanced = ColorLook.transform(mid, look(["gradingShadowsSaturation": 100, "gradingBalance": -100])).r
        let blended = ColorLook.transform(mid, look(["gradingShadowsSaturation": 100, "gradingBlending": 100])).r
        XCTAssertGreaterThan(balanced, plain)
        XCTAssertGreaterThan(blended, plain)
        XCTAssertTrue(ColorLook.isIdentity { $0 == "gradingShadowsHue" ? 200 : $0 == "gradingBlending" ? 80 : nil })
    }

    // MARK: - Calibration

    func testCalibrationKeepsWhiteAndGrey() {
        let v = look(["calibrationRedHue": 100, "calibrationGreenSaturation": -60, "calibrationBlueHue": -40])
        let m = ColorLook.calibrationMatrix(v)
        for row in m { assertClose(row.reduce(0, +), 1, 1e-9) }
        let white = ColorLook.transform(RGB(1, 1, 1), v)
        assertClose(white.r, 1, 1e-6)
        assertClose(white.b, 1, 1e-6)
        let grey = ColorLook.transform(RGB(0.5, 0.5, 0.5), v)
        assertClose(grey.g, 0.5, 1e-6)
    }

    func testRedPrimaryHueTurnsRedTowardsYellow() {
        let red = RGB(0.8, 0.1, 0.1)
        let turned = ColorLook.transform(red, look(["calibrationRedHue": 100]))
        XCTAssertGreaterThan(ColorLook.hsl(turned).h, 5)
        XCTAssertLessThan(ColorLook.hsl(turned).h, 60)
        let desaturated = ColorLook.transform(red, look(["calibrationRedSaturation": -100]))
        XCTAssertLessThan(desaturated.max - desaturated.min, red.max - red.min)
    }

    func testShadowsTintIsMagentaInTheDarks() {
        let dark = ColorLook.transform(RGB(0.1, 0.1, 0.1), look(["calibrationShadowsTint": 100]))
        XCTAssertLessThan(dark.g, dark.r)
        XCTAssertEqual(ColorLook.transform(RGB(0.9, 0.9, 0.9), look(["calibrationShadowsTint": 100])), RGB(0.9, 0.9, 0.9))
        XCTAssertEqual(parse("shadows tint 30"), [.set("calibrationShadowsTint", 30)])
        XCTAssertEqual(parse("tint 30"), [.set("tint", 30)])
    }

    // MARK: - Black & white

    func testBlackAndWhiteNames() {
        XCTAssertEqual(parse("black and white"), [.set("bw", 1)])
        XCTAssertEqual(parse("b&w off"), [.set("bw", 0)])
        XCTAssertEqual(parse("bw red 30"), [.set("bwRed", 30)])
        XCTAssertEqual(parse("black and white blue -20"), [.set("bwBlue", -20)])
        XCTAssertEqual(parse("black down whites up"), [.nudge("blacks", -1), .nudge("whites", 1)])
        XCTAssertEqual(parse("blacks -20"), [.set("blacks", -20)])
    }

    func testBlackAndWhiteMix() {
        let red = RGB(0.8, 0.1, 0.1)
        let plain = ColorLook.transform(red, look(["bw": 1]))
        XCTAssertEqual(plain, RGB(red.luma, red.luma, red.luma))
        let brighter = ColorLook.transform(red, look(["bw": 1, "bwRed": 100]))
        XCTAssertGreaterThan(brighter.r, plain.r * 1.5)
        XCTAssertEqual(brighter.r, brighter.b)
        let blueUntouched = ColorLook.transform(RGB(0.1, 0.1, 0.8), look(["bw": 1, "bwRed": 100]))
        assertClose(blueUntouched.r, RGB(0.1, 0.1, 0.8).luma, 1e-9)
        XCTAssertTrue(ColorLook.isIdentity { $0 == "bwRed" ? 50 : nil }, "the mix alone does nothing")
    }

    func testGradingTintsBlackAndWhite() {
        let v = look(["bw": 1, "gradingShadowsSaturation": 100, "gradingShadowsHue": 30])
        let c = ColorLook.transform(RGB(0.15, 0.1, 0.3), v)
        XCTAssertGreaterThan(c.r, c.b, "split-toned shadows")
    }

    // MARK: - Toning

    func testToningOptionsMatchControlsJSON() {
        XCTAssertEqual(options("toning"), ColorLook.toningOptions)
        XCTAssertEqual(parse("toning sepia"), [.set("toning", 1)])
        XCTAssertEqual(parse("toning off"), [.set("toning", 0)], "off is the None option here")
        XCTAssertEqual(parse("tone curve shadows 20"), [.set("curveShadows", 20)])
    }

    func testToningPalettesKeepBrightnessRoughly() {
        for (name, stops) in ColorLook.toningPalettes {
            for t in stride(from: 0.0, through: 1, by: 0.25) {
                assertClose(ColorLook.gradient(stops, t).luma, t, 0.12, "\(name) at \(t)")
            }
        }
    }

    func testSepiaWarmsAndAmountMixes() {
        let grey = RGB(0.5, 0.5, 0.5)
        let sepia = ColorLook.transform(grey, look(["toning": 1]))
        XCTAssertGreaterThan(sepia.r, sepia.b)
        let half = ColorLook.transform(grey, look(["toning": 1, "toningAmount": 50]))
        assertClose(half.r, (sepia.r + 0.5) / 2, 1e-9)
        XCTAssertTrue(ColorLook.isIdentity { $0 == "toningAmount" ? 30 : nil })
    }

    // MARK: - Channel mixer

    func testChannelMixerNamesAndDefaults() {
        XCTAssertEqual(parse("red from green 30"), [.set("channelRedFromGreen", 30)])
        XCTAssertEqual(parse("blue channel blue down"), [.nudge("channelBlueFromBlue", -1)])
        XCTAssertEqual(registry.control(id: "channelGreenFromGreen")?.defaultValue, 100)
        XCTAssertTrue(ColorLook.isIdentity { _ in nil }, "default mixer is the identity")
    }

    func testChannelMixerRebuildsChannels() {
        let c = RGB(0.2, 0.5, 0.8)
        XCTAssertEqual(ColorLook.channelMixer(c, look([:])), c)
        let swapped = ColorLook.channelMixer(c, look(["channelRedFromRed": 0, "channelRedFromBlue": 100]))
        assertClose(swapped.r, 0.8)
        assertClose(swapped.g, 0.5)
        let mono = ColorLook.channelMixer(c, look(["channelGreenFromRed": 50, "channelGreenFromGreen": 50]))
        assertClose(mono.g, 0.35)
    }
}
