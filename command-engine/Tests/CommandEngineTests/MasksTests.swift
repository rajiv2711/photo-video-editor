import XCTest
@testable import CommandEngine

/// Masks (local adjustments): names, where values go (global or the selected mask), and the mask
/// maths the iPad stretches over the photo.
final class MasksTests: XCTestCase {
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

    private func control(_ id: String) -> Control {
        registry.control(id: id)!
    }

    /// Grid values as a picture-friendly helper: the value at x, y (0…1 from the top-left).
    private func at(_ grid: [Float], _ width: Int, _ height: Int, _ x: Double, _ y: Double) -> Float {
        grid[min(height - 1, Int(y * Double(height))) * width + min(width - 1, Int(x * Double(width)))]
    }

    // MARK: - Schema

    func testMaskControlsAreWellFormed() {
        let kinds = Set(registry.controls.compactMap { $0.kind == .action ? $0.component : nil })
        for c in registry.controls {
            if c.local { XCTAssertEqual(c.kind, .slider, "\(c.id): only sliders can be local") }
            if c.local { XCTAssertNotEqual(c.group, "masks", c.id) }
            if let scope = c.scope {
                XCTAssertTrue(["mask", "component"].contains(scope), c.id)
                XCTAssertEqual(c.group, "masks", c.id)
            }
            if c.scope == "component", let kind = c.component {
                XCTAssertTrue(kinds.contains(kind), "\(c.id): no action makes a \(kind)")
            }
            if c.kind == .action, let kind = c.component {
                XCTAssertEqual(c.group, "masks", c.id)
                for option in c.options {
                    XCTAssertTrue(MaskPresets.knows(option.id, kind: kind), "\(c.id): no placement for \(option.id)")
                }
            }
        }
        XCTAssertTrue(kinds.contains("brush"))
    }

    // MARK: - Names

    func testMaskNames() {
        XCTAssertEqual(parse("brush mask"), [.run("brushMask")])
        XCTAssertEqual(parse("new brush mask"), [.run("brushMask", value: nil, mode: "new")])
        XCTAssertEqual(Command.run("brushMask", value: nil, mode: "new").json, #"{"control":"brushMask","mode":"new","op":"run"}"#)
        XCTAssertEqual(parse("mask 2"), [.set("mask", 2)])
        XCTAssertEqual(parse("mask 1 contrast 30"), [.set("mask", 1), .set("contrast", 30)])
        XCTAssertEqual(parse("mask exposure more"), [.select("mask"), .nudge("exposure", 1)])
        XCTAssertEqual(parse("done"), [.run("maskDone")])
        XCTAssertEqual(parse("global sliders"), [.run("maskDone")])
        XCTAssertEqual(parse("delete mask"), [.run("deleteMask")])
        XCTAssertEqual(parse("delete mask 2"), [.run("deleteMask", value: 2)])
        XCTAssertEqual(parse("brush size 20"), [.set("brushSize", 20)])
        XCTAssertEqual(parse("eraser"), [.set("brushErase", 1)])
        XCTAssertEqual(parse("eraser off"), [.set("brushErase", 0)])
        XCTAssertEqual(parse("auto mask on"), [.set("brushAutoMask", 1)])
        XCTAssertEqual(parse("brush mask exposure -1"), [.run("brushMask"), .set("exposure", -1)])
    }

    func testMaskNamesNeverTakeANearMissFromTheOtherPanels() {
        // "global" alone is the Done action now, but the grading names still win as whole names.
        XCTAssertEqual(parse("global hue 300"), [.set("gradingGlobalHue", 300)])
        XCTAssertEqual(parse("colour less"), [.ambiguous("colour", ["vibrance", "saturation"])])
        XCTAssertEqual(parse("density up"), [.nudge("photoFilterDensity", 1)])
        XCTAssertEqual(parse("red from green 30"), [.set("channelRedFromGreen", 30)], "“from” inside a name")
        XCTAssertEqual(parse("add contrast"), [.nudge("contrast", 1)], "“add” before a slider is still “more”")
    }

    // MARK: - Global and local values

    func testSlidersAreLocalWhileAMaskIsSelected() {
        XCTAssertEqual(run("exposure 0.5"), [.changed(controlID: "exposure", from: 0, to: 0.5)])
        XCTAssertEqual(run("brush mask"), [.ran(controlID: "brushMask"), .masked(mask: 1, event: .created("brush"))])
        XCTAssertEqual(state.selectedMask, 0)
        XCTAssertEqual(run("exposure -1"), [.changedInMask(mask: 1, controlID: "exposure", from: 0, to: -1)])
        XCTAssertEqual(state.value(of: control("exposure")), 0.5, "global exposure kept")
        XCTAssertEqual(state.masks[0].adjustments["exposure"], -1)
        XCTAssertEqual(state.current(control("exposure")), -1, "the slider shows the mask's value")
        XCTAssertEqual(run("more"), [.changedInMask(mask: 1, controlID: "exposure", from: -1, to: -0.9)])

        // Sliders masks can't hold stay global.
        XCTAssertEqual(run("vignette -20"), [.changed(controlID: "vignette", from: 0, to: -20)])

        XCTAssertEqual(run("done"), [.ran(controlID: "maskDone"), .masked(mask: 0, event: .deselected)])
        XCTAssertEqual(run("exposure 1"), [.changed(controlID: "exposure", from: 0.5, to: 1)])
        XCTAssertEqual(state.masks[0].adjustments["exposure"], -0.9)

        XCTAssertEqual(run("mask 1 contrast 30"), [.changed(controlID: "mask", from: 0, to: 1),
                                                    .changedInMask(mask: 1, controlID: "contrast", from: 0, to: 30)])
        XCTAssertEqual(run("mask 0 contrast 10"), [.changed(controlID: "mask", from: 1, to: 0),
                                                    .changed(controlID: "contrast", from: 0, to: 10)])
    }

    func testABareMaskPicksTheNewestMask() {
        run("brush mask")
        run("brush mask")
        run("done")
        XCTAssertEqual(run("mask exposure more"), [.changed(controlID: "mask", from: 0, to: 2),
                                                    .changedInMask(mask: 2, controlID: "exposure", from: 0, to: 0.1)])
    }

    func testOnlyExistingMasksCanBeSelected() {
        run("brush mask")
        XCTAssertEqual(run("mask 5"), [.unchanged(controlID: "mask", value: 1)])
        run("mask 0")
        XCTAssertEqual(run("mask 3"), [.changed(controlID: "mask", from: 0, to: 1)])
    }

    func testDeletingMasks() {
        XCTAssertEqual(run("delete mask"), [.needsMask(controlID: "deleteMask")])
        run("brush mask exposure 1")
        run("brush mask exposure -1")
        XCTAssertEqual(run("delete mask 1"), [.ran(controlID: "deleteMask"), .masked(mask: 1, event: .deleted)])
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].adjustments["exposure"], -1)
        XCTAssertNil(state.selectedMask, "after a delete the sliders are global")
        run("mask 1")
        XCTAssertEqual(run("delete mask"), [.ran(controlID: "deleteMask"), .masked(mask: 1, event: .deleted)])
        XCTAssertTrue(state.masks.isEmpty)
    }

    func testResetAllDeletesTheMasks() {
        run("brush mask exposure 1")
        let outcomes = run("reset all")
        XCTAssertTrue(outcomes.contains(.masked(mask: 0, event: .allDeleted)))
        XCTAssertTrue(state.masks.isEmpty)
        XCTAssertNil(state.selectedMask)
    }

    func testBrushStrokesGoToTheSelectedBrush() {
        XCTAssertFalse(state.addStroke(MaskStroke(points: [MaskPoint(0.5, 0.5)])), "no mask")
        run("brush mask")
        XCTAssertTrue(state.addStroke(MaskStroke(points: [MaskPoint(0.5, 0.5)], size: 20)))
        XCTAssertEqual(state.masks[0].components[0].strokes.count, 1)
    }

    // MARK: - Mask maths

    func testGridSizeFollowsThePhoto() {
        XCTAssertTrue(MaskRaster.gridSize(width: 800, height: 600) == (800, 600))
        XCTAssertTrue(MaskRaster.gridSize(width: 2048, height: 1536) == (1024, 768))
        XCTAssertTrue(MaskRaster.gridSize(width: 6000, height: 4000) == (2048, 1365))
    }

    func testBrushDabCoversItsCircleOnly() {
        let w = 100, h = 50
        let dab = MaskStroke(points: [MaskPoint(0.5, 0.5)], size: 20, feather: 0)  // radius 10 cells
        let grid = MaskRaster.strokes([dab], width: w, height: h, pixels: nil)
        XCTAssertEqual(at(grid, w, h, 0.5, 0.5), 1)
        XCTAssertEqual(at(grid, w, h, 0.5 + 8 / 100.0, 0.5), 1, accuracy: 1e-6, "inside the radius")
        XCTAssertEqual(at(grid, w, h, 0.5 + 12 / 100.0, 0.5), 0, "outside the radius")
        XCTAssertEqual(at(grid, w, h, 0.1, 0.1), 0)
    }

    func testBrushFeatherDensityFlowAndEraser() {
        let w = 100, h = 100
        let soft = MaskRaster.strokes([MaskStroke(points: [MaskPoint(0.5, 0.5)], size: 40, feather: 100)], width: w, height: h, pixels: nil)
        let mid = at(soft, w, h, 0.6, 0.5)
        XCTAssertGreaterThan(mid, 0.2)
        XCTAssertLessThan(mid, 0.9, "a soft brush fades towards its edge")

        let line = [MaskPoint(0.1, 0.5), MaskPoint(0.9, 0.5)]
        let half = MaskRaster.strokes([MaskStroke(points: line, size: 10, density: 50)], width: w, height: h, pixels: nil)
        XCTAssertEqual(at(half, w, h, 0.5, 0.5), 0.5, accuracy: 1e-3, "density caps the stroke")

        let light = MaskRaster.strokes([MaskStroke(points: [MaskPoint(0.5, 0.5)], size: 10, feather: 0, flow: 30)],
                                       width: w, height: h, pixels: nil)
        XCTAssertEqual(at(light, w, h, 0.5, 0.5), 0.3, accuracy: 1e-3, "one dab adds its flow")
        let built = MaskRaster.strokes([MaskStroke(points: line, size: 10, feather: 0, flow: 30)], width: w, height: h, pixels: nil)
        XCTAssertGreaterThan(at(built, w, h, 0.5, 0.5), 0.6, "overlapping dabs build up")

        let erased = MaskRaster.strokes([MaskStroke(points: line, size: 30), MaskStroke(points: [MaskPoint(0.5, 0.5)], size: 10, erase: true)],
                                        width: w, height: h, pixels: nil)
        XCTAssertEqual(at(erased, w, h, 0.5, 0.5), 0, accuracy: 1e-6, "the eraser takes it away")
        XCTAssertEqual(at(erased, w, h, 0.2, 0.5), 1, accuracy: 1e-6)
    }

    func testAutoMaskStaysOnSimilarColours() {
        // Left half red, right half blue; a big dab on the red side spills over without auto mask.
        let w = 40, h = 20
        var rgb = [Float]()
        for _ in 0..<h {
            for x in 0..<w { rgb += x < w / 2 ? [0.8, 0.1, 0.1] : [0.1, 0.1, 0.8] }
        }
        let pixels = PixelGrid(width: w, height: h, rgb: rgb)
        let point = [MaskPoint(0.4, 0.5)]
        let plain = MaskRaster.strokes([MaskStroke(points: point, size: 50)], width: w, height: h, pixels: pixels)
        let auto = MaskRaster.strokes([MaskStroke(points: point, size: 50, autoMask: true)], width: w, height: h, pixels: pixels)
        XCTAssertGreaterThan(at(plain, w, h, 0.55, 0.5), 0.5)
        XCTAssertEqual(at(auto, w, h, 0.55, 0.5), 0, "auto mask stops at the colour edge")
        XCTAssertEqual(at(auto, w, h, 0.4, 0.5), 1)
    }

    func testPartsJoinByTheirModes() {
        let a: [Float] = [0, 0.5, 1, 1], b: [Float] = [1, 1, 0.5, 0]
        XCTAssertEqual(MaskRaster.combine([(a, .add), (b, .add)], count: 4), [1, 1, 1, 1])
        XCTAssertEqual(MaskRaster.combine([(a, .add), (b, .subtract)], count: 4), [0, 0, 0.5, 1])
        XCTAssertEqual(MaskRaster.combine([(a, .add), (b, .intersect)], count: 4), [0, 0.5, 0.5, 0])
    }

    func testResampleSpacesDabsEvenly() {
        let dabs = MaskRaster.resample([(0, 0), (10, 0)], spacing: 2.5)
        XCTAssertEqual(dabs.map(\.x), [0, 2.5, 5, 7.5, 10])
        XCTAssertEqual(MaskRaster.resample([(3, 4)], spacing: 1).count, 1, "a tap is one dab")
    }
}

/// Linear gradient: names, placements and the gradient's maths.
final class LinearGradientTests: XCTestCase {
    private var registry: ControlRegistry!
    private var interpreter: CommandInterpreter!
    private var state = EditState()

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        interpreter = CommandInterpreter(registry: registry)
    }

    private func parse(_ text: String) -> [Command] {
        CommandParser(registry: registry).parse(text)
    }

    func testLinearGradientNames() {
        XCTAssertEqual(parse("linear gradient"), [.run("linearGradient")])
        XCTAssertEqual(parse("linear gradient from top"), [.run("linearGradient", value: 0)])
        XCTAssertEqual(parse("new linear gradient mask"), [.run("linearGradient", value: nil, mode: "new")])
        XCTAssertEqual(parse("graduated filter from bottom exposure -1"), [.run("linearGradient", value: 1), .set("exposure", -1)])
        XCTAssertEqual(parse("linear gradient left"), [.run("linearGradient", value: 2)])
        XCTAssertEqual(parse("linear angle 45"), [.set("linearAngle", 45)])
        XCTAssertEqual(parse("gradient position up"), [.nudge("linearPosition", 1)])
        XCTAssertEqual(parse("linear width 30"), [.set("linearWidth", 30)])
    }

    func testPlacementsAndSettingsGoToTheGradient() {
        _ = interpreter.interpret("linear gradient from right", state: &state)
        let part = state.masks[0].components[0]
        XCTAssertEqual(part.kind, "linear")
        XCTAssertEqual(part.values["linearAngle"], 90)
        XCTAssertEqual(part.values["linearPosition"], 25)
        XCTAssertEqual(interpreter.interpret("linear width 20", state: &state),
                       [.changedInMask(mask: 1, controlID: "linearWidth", from: 50, to: 20)])
        _ = interpreter.interpret("done", state: &state)
        XCTAssertEqual(interpreter.interpret("linear width 30", state: &state), [.needsMask(controlID: "linearWidth")])
        _ = interpreter.interpret("brush mask", state: &state)
        XCTAssertEqual(interpreter.interpret("linear angle 10", state: &state), [.needsMask(controlID: "linearAngle")],
                       "a brush mask has no linear gradient")
    }

    func testFromTopIsFullAtTheTopAndGoneByTheMiddle() {
        let w = 60, h = 80
        let grid = MaskRaster.linear(angle: 0, position: 25, fade: 50, width: w, height: h)
        XCTAssertEqual(grid[0], 1, accuracy: 1e-3)
        XCTAssertEqual(grid[(h / 2 + 1) * w], 0, accuracy: 1e-6)
        XCTAssertEqual(grid[(h / 4) * w], 0.5, accuracy: 0.05)
        for row in 1..<h { XCTAssertLessThanOrEqual(grid[row * w + 7], grid[(row - 1) * w + 7]) }
        XCTAssertEqual(grid[5], grid[w - 5], "the same across each row")
    }

    func testSidesTurnClockwise() {
        let w = 40, h = 40
        let right = MaskRaster.linear(angle: 90, position: 25, fade: 50, width: w, height: h)
        XCTAssertEqual(right[20 * w + (w - 1)], 1, accuracy: 1e-2)
        XCTAssertEqual(right[20 * w], 0)
        let bottom = MaskRaster.linear(angle: 180, position: 25, fade: 50, width: w, height: h)
        XCTAssertEqual(bottom[(h - 1) * w + 20], 1, accuracy: 1e-2)
        XCTAssertEqual(bottom[20], 0)
        let left = MaskRaster.linear(angle: -90, position: 25, fade: 50, width: w, height: h)
        XCTAssertEqual(left[20 * w], 1, accuracy: 1e-2)
    }

    func testADragSetsAngleSpotAndWidth() {
        let g = MaskGeometry.linear(from: MaskPoint(0.5, 0), to: MaskPoint(0.5, 0.5), width: 300, height: 200)
        XCTAssertEqual(g.angle, 0, accuracy: 1e-9)
        XCTAssertEqual(g.position, 25, accuracy: 1e-9)
        XCTAssertEqual(g.width, 50, accuracy: 1e-9)
        // The handles drawn for any drag (on the line through the middle) make the same gradient.
        let d = MaskGeometry.linear(from: MaskPoint(0.2, 0.7), to: MaskPoint(0.6, 0.4), width: 300, height: 200)
        let back = MaskGeometry.linearHandles(angle: d.angle, position: d.position, width: d.width, width: 300, height: 200)
        let again = MaskGeometry.linear(from: back.start, to: back.end, width: 300, height: 200)
        XCTAssertEqual(again.angle, d.angle, accuracy: 1e-9)
        XCTAssertEqual(again.position, d.position, accuracy: 1e-9)
        XCTAssertEqual(again.width, d.width, accuracy: 1e-9)
    }
}

/// Radial gradient: names, placements, drags and the ellipse's maths.
final class RadialGradientTests: XCTestCase {
    private var registry: ControlRegistry!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
    }

    private func parse(_ text: String) -> [Command] {
        CommandParser(registry: registry).parse(text)
    }

    func testRadialGradientNames() {
        XCTAssertEqual(parse("radial gradient"), [.run("radialGradient")])
        XCTAssertEqual(parse("radial gradient center"), [.run("radialGradient", value: 0)])
        XCTAssertEqual(parse("new radial mask center"), [.run("radialGradient", value: 0, mode: "new")])
        XCTAssertEqual(parse("radial filter top left exposure 1"), [.run("radialGradient", value: 5), .set("exposure", 1)])
        XCTAssertEqual(parse("radial size 80"), [.set("radialSize", 80)])
        XCTAssertEqual(parse("radial feather less"), [.nudge("radialFeather", -1)])
    }

    func testPlacements() {
        var state = EditState()
        var interpreter = CommandInterpreter(registry: registry)
        _ = interpreter.interpret("radial gradient bottom right", state: &state)
        let part = state.masks[0].components[0]
        XCTAssertEqual(part.values["radialX"], 75)
        XCTAssertEqual(part.values["radialY"], 75)
        XCTAssertEqual(part.values["radialSize"], registry.control(id: "radialSize")!.defaultValue)
    }

    func testFullInsideNothingOutside() {
        let w = 100, h = 60
        // Radius 50 % of half the short side = 15 cells.
        let grid = MaskRaster.radial(x: 50, y: 50, size: 50, aspect: 0, angle: 0, feather: 0, width: w, height: h)
        XCTAssertEqual(grid[30 * w + 50], 1)
        XCTAssertEqual(grid[30 * w + 50 + 12], 1, "inside")
        XCTAssertEqual(grid[30 * w + 50 + 17], 0, "outside")
        XCTAssertEqual(grid[0], 0)
        let soft = MaskRaster.radial(x: 50, y: 50, size: 50, aspect: 0, angle: 0, feather: 100, width: w, height: h)
        XCTAssertGreaterThan(soft[30 * w + 50 + 7], 0.3)
        XCTAssertLessThan(soft[30 * w + 50 + 7], 0.9, "feather 100 fades from the centre")
    }

    func testAspectAndAngle() {
        let w = 100, h = 100
        let wide = MaskRaster.radial(x: 50, y: 50, size: 40, aspect: 100, angle: 0, feather: 0, width: w, height: h)
        XCTAssertEqual(wide[50 * w + 50 + 30], 1, "40 cells wide each way")
        XCTAssertEqual(wide[(50 + 15) * w + 50], 0, "10 cells tall each way")
        let turned = MaskRaster.radial(x: 50, y: 50, size: 40, aspect: 100, angle: 90, feather: 0, width: w, height: h)
        XCTAssertEqual(turned[(50 + 30) * w + 50], 1, "turned upright")
        XCTAssertEqual(turned[50 * w + 50 + 15], 0)
        let left = MaskRaster.radial(x: 20, y: 50, size: 20, aspect: 0, angle: 0, feather: 0, width: w, height: h)
        XCTAssertEqual(left[50 * w + 20], 1)
        XCTAssertEqual(left[50 * w + 50], 0)
    }

    func testDragsMoveOrResize() {
        let base: [String: Double] = ["radialX": 50, "radialY": 50, "radialSize": 50, "radialAspect": 0, "radialAngle": 0]
        let moved = MaskGeometry.radialDrag(base, from: MaskPoint(0.5, 0.5), to: MaskPoint(0.3, 0.6), width: 200, height: 100)
        XCTAssertEqual(moved["radialX"]!, 30, accuracy: 1e-9)
        XCTAssertEqual(moved["radialY"]!, 60, accuracy: 1e-9)
        XCTAssertNil(moved["radialSize"])
        // Radius is 25 px; a drag from 40 px out to 80 px out doubles it.
        let grown = MaskGeometry.radialDrag(base, from: MaskPoint(0.7, 0.5), to: MaskPoint(0.9, 0.5), width: 200, height: 100)
        XCTAssertEqual(grown["radialSize"]!, 100, accuracy: 1e-9)
    }
}

/// Color range: names, the tap, named hues and the colour maths.
final class ColorRangeTests: XCTestCase {
    private var registry: ControlRegistry!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
    }

    private func parse(_ text: String) -> [Command] {
        CommandParser(registry: registry).parse(text)
    }

    /// Left third red, middle third orange, right third grey (sRGB levels).
    private func stripes(width: Int = 30, height: Int = 4) -> PixelGrid {
        var rgb: [Float] = []
        for _ in 0..<height {
            for x in 0..<width {
                switch x * 3 / width {
                case 0: rgb += [0.85, 0.15, 0.12]
                case 1: rgb += [0.9, 0.55, 0.1]
                default: rgb += [0.5, 0.5, 0.5]
                }
            }
        }
        return PixelGrid(width: width, height: height, rgb: rgb)
    }

    func testColorRangeNames() {
        XCTAssertEqual(parse("color range"), [.run("colorRange")])
        XCTAssertEqual(parse("colour range red"), [.run("colorRange", value: 0)])
        XCTAssertEqual(parse("new color range mask blue exposure -1"), [.run("colorRange", value: 5, mode: "new"), .set("exposure", -1)])
        XCTAssertEqual(parse("color range refine 70"), [.set("colorRangeRefine", 70)])
        XCTAssertEqual(parse("colour more"), [.ambiguous("colour", ["vibrance", "saturation"])], "still asks as before")
    }

    func testATapSelectsThatColour() {
        let pixels = stripes()
        var part = MaskComponent(kind: "colorRange", values: ["colorRangeRefine": 50])
        XCTAssertEqual(MaskRaster.colorRange(part, width: 30, height: 4, pixels: pixels).max(), 0, "nothing until tapped")
        part.point = MaskPoint(0.15, 0.5)
        let grid = MaskRaster.colorRange(part, width: 30, height: 4, pixels: pixels)
        XCTAssertEqual(grid[2 * 30 + 4], 1)
        XCTAssertEqual(grid[2 * 30 + 15], 0, "orange is too far")
        XCTAssertEqual(grid[2 * 30 + 25], 0, "grey is too far")
    }

    func testANamedHueSelectsEveryShadeOfIt() {
        let pixels = stripes()
        var part = MaskComponent(kind: "colorRange", values: ["colorRangeRefine": 50, "hue": 0])
        var grid = MaskRaster.colorRange(part, width: 30, height: 4, pixels: pixels)
        XCTAssertEqual(grid[4], 1, accuracy: 1e-6)
        XCTAssertEqual(grid[15], 0, "orange (36°) is outside red's band")
        XCTAssertEqual(grid[25], 0, "grey has no hue")
        part.values["hue"] = 30
        grid = MaskRaster.colorRange(part, width: 30, height: 4, pixels: pixels)
        XCTAssertGreaterThan(grid[15], 0.9)
        part.values["colorRangeRefine"] = 100
        part.values["hue"] = 0
        XCTAssertGreaterThan(MaskRaster.colorRange(part, width: 30, height: 4, pixels: pixels)[15], 0.1, "refine widens the band")
    }

    func testLabOfKnownColours() {
        let white = MaskRaster.lab(1, 1, 1)
        XCTAssertEqual(white.l, 100, accuracy: 0.1)
        XCTAssertEqual(white.a, 0, accuracy: 0.1)
        let red = MaskRaster.lab(1, 0, 0)
        XCTAssertEqual(red.l, 53.2, accuracy: 0.5)
        XCTAssertEqual(red.a, 80.1, accuracy: 0.5)
    }

    func testATapMovesToTheSelectedColourRange() {
        var state = EditState()
        var interpreter = CommandInterpreter(registry: registry)
        _ = interpreter.interpret("color range red", state: &state)
        XCTAssertEqual(state.masks[0].components[0].values["hue"], 0)
        XCTAssertTrue(state.setPoint(MaskPoint(0.2, 0.3)))
        XCTAssertNil(state.masks[0].components[0].values["hue"], "a tap replaces the named colour")
        XCTAssertEqual(state.masks[0].components[0].point, MaskPoint(0.2, 0.3))
    }
}

/// Luminance range: names, tones and the brightness maths.
final class LuminanceRangeTests: XCTestCase {
    private var registry: ControlRegistry!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
    }

    private func parse(_ text: String) -> [Command] {
        CommandParser(registry: registry).parse(text)
    }

    /// A grey ramp, black to white, 101 cells wide.
    private let ramp = PixelGrid(width: 101, height: 1, rgb: (0...100).flatMap { i in [Float(i) / 100, Float(i) / 100, Float(i) / 100] })

    func testLuminanceRangeNames() {
        XCTAssertEqual(parse("luminance range"), [.run("luminanceRange")])
        XCTAssertEqual(parse("luminance range shadows"), [.run("luminanceRange", value: 0)])
        XCTAssertEqual(parse("subtract luminance range"), [.run("luminanceRange", value: nil, mode: "subtract")])
        XCTAssertEqual(parse("brightness range highlights exposure -1"), [.run("luminanceRange", value: 4), .set("exposure", -1)])
        XCTAssertEqual(parse("luminance range low 40"), [.set("luminanceRangeLow", 40)])
        XCTAssertEqual(parse("lumin more"), [.ambiguous("lumin", [
            "mixerRedLuminance", "mixerOrangeLuminance", "mixerYellowLuminance", "mixerGreenLuminance", "mixerAquaLuminance",
            "mixerBlueLuminance", "mixerPurpleLuminance", "mixerMagentaLuminance"])], "a near-miss still asks among the mixer")
    }

    func testOnlyTheRangeIsSelected() {
        let grid = MaskRaster.luminanceRange(low: 40, high: 60, smoothness: 0, width: 101, height: 1, pixels: ramp)
        XCTAssertEqual(grid[50], 1)
        XCTAssertEqual(grid[40], 1)
        XCTAssertEqual(grid[60], 1)
        XCTAssertEqual(grid[30], 0)
        XCTAssertEqual(grid[70], 0)
        let smooth = MaskRaster.luminanceRange(low: 40, high: 60, smoothness: 100, width: 101, height: 1, pixels: ramp)
        XCTAssertGreaterThan(smooth[30], 0.2, "smoothness fades it out farther")
        XCTAssertEqual(smooth[5], 0)
        XCTAssertEqual(MaskRaster.luminanceRange(low: 60, high: 40, smoothness: 0, width: 101, height: 1, pixels: ramp)[50], 1,
                       "low and high can be swapped")
    }

    func testTonesAndTaps() {
        var state = EditState()
        var interpreter = CommandInterpreter(registry: registry)
        _ = interpreter.interpret("luminance range", state: &state)
        XCTAssertEqual(state.masks[0].components[0].values["luminanceRangeLow"], 75, "highlights unless told")
        _ = interpreter.interpret("luminance range midtones", state: &state)
        XCTAssertEqual(state.masks[1].components[0].values["luminanceRangeLow"], 25)
        XCTAssertEqual(state.masks[1].components[0].values["luminanceRangeHigh"], 75)
        XCTAssertTrue(MaskPresets.luminanceRange(around: 50) == (35, 65))
        XCTAssertTrue(MaskPresets.luminanceRange(around: 5) == (0, 20))
    }
}

/// Mask math: parts joined by add, subtract, intersect; inverting; duplicating; parts selected and deleted.
final class MaskMathTests: XCTestCase {
    private var registry: ControlRegistry!
    private var interpreter: CommandInterpreter!
    private var state = EditState()

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        interpreter = CommandInterpreter(registry: registry)
    }

    private func parse(_ text: String) -> [Command] {
        CommandParser(registry: registry).parse(text)
    }

    @discardableResult
    private func run(_ text: String) -> [CommandOutcome] {
        interpreter.interpret(text, state: &state)
    }

    func testModeWordsBeforeAPart() {
        XCTAssertEqual(parse("add radial gradient"), [.run("radialGradient", value: nil, mode: "add")])
        XCTAssertEqual(parse("intersect linear gradient from left"), [.run("linearGradient", value: 2, mode: "intersect")])
        XCTAssertEqual(parse("subtract a brush"), [.run("brushMask", value: nil, mode: "subtract")])
        XCTAssertEqual(parse("invert mask"), [.set("maskInvert", 1)])
        XCTAssertEqual(parse("invert"), [.set("invert", 1)], "invert alone is still the photo negative")
        XCTAssertEqual(parse("component 2"), [.set("maskComponent", 2)])
        XCTAssertEqual(parse("component mode subtract"), [.set("componentMode", 1)])
        XCTAssertEqual(parse("outside"), [.set("invertComponent", 1)])
        XCTAssertEqual(parse("duplicate mask"), [.run("duplicateMask")])
        XCTAssertEqual(parse("delete component"), [.run("deleteComponent")])
    }

    func testPartsJoinTheSelectedMask() {
        run("linear gradient from top")
        XCTAssertEqual(run("subtract radial gradient center"),
                       [.ran(controlID: "radialGradient"), .masked(mask: 1, event: .added("radial", .subtract))])
        XCTAssertEqual(state.masks.count, 1)
        XCTAssertEqual(state.masks[0].components.map(\.kind), ["linear", "radial"])
        XCTAssertEqual(state.masks[0].components[1].mode, .subtract)
        XCTAssertEqual(state.masks[0].selectedComponent, 1)
        run("done")
        XCTAssertEqual(run("intersect brush"), [.needsMask(controlID: "brushMask")], "nothing to intersect with")
        XCTAssertEqual(run("add brush"), [.ran(controlID: "brushMask"), .masked(mask: 2, event: .created("brush"))],
                       "add with no mask selected makes one")
    }

    func testSelectingAndDeletingParts() {
        run("linear gradient from top add radial gradient center")
        XCTAssertEqual(run("component 1"), [.changedInMask(mask: 1, controlID: "maskComponent", from: 2, to: 1)])
        XCTAssertEqual(run("component mode intersect"), [.changedInMask(mask: 1, controlID: "componentMode", from: 0, to: 2)])
        XCTAssertEqual(state.masks[0].components[0].mode, .intersect)
        XCTAssertEqual(run("component 9"), [.changedInMask(mask: 1, controlID: "maskComponent", from: 1, to: 2)], "only parts that exist")
        XCTAssertEqual(run("delete component"), [.ran(controlID: "deleteComponent"), .masked(mask: 1, event: .partDeleted)])
        XCTAssertEqual(state.masks[0].components.map(\.kind), ["linear"])
        XCTAssertEqual(run("delete component"), [.ran(controlID: "deleteComponent"), .masked(mask: 1, event: .deleted)],
                       "the last part takes its mask with it")
        XCTAssertTrue(state.masks.isEmpty)
    }

    func testInvertAndDuplicate() {
        run("radial gradient center exposure 1 invert mask")
        XCTAssertEqual(state.masks[0].settings["maskInvert"], 1)
        XCTAssertEqual(run("duplicate mask"), [.ran(controlID: "duplicateMask"), .masked(mask: 2, event: .duplicated(from: 1))])
        XCTAssertEqual(state.masks[1], state.masks[0])
        XCTAssertEqual(state.selectedMask, 1)

        let w = 40, h = 40
        let full = MaskRaster.render(state.masks[0], width: w, height: h, pixels: nil)
        XCTAssertEqual(full[20 * w + 20], 0, accuracy: 1e-6, "inverted: nothing in the middle")
        XCTAssertEqual(full[0], 1, accuracy: 1e-6, "everything outside")
        var part = state.masks[0]
        part.settings["maskInvert"] = 0
        part.components[0].values["invertComponent"] = 1
        XCTAssertEqual(MaskRaster.render(part, width: w, height: h, pixels: nil), full, "a part's invert gives the same here")
    }
}

/// Mask refine: expand and contract, smooth, refine edge and feather.
final class MaskRefineTests: XCTestCase {
    private var registry: ControlRegistry!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
    }

    private func parse(_ text: String) -> [Command] {
        CommandParser(registry: registry).parse(text)
    }

    /// A hard 20 × 20 square in a 100 × 100 grid.
    private func square() -> [Float] {
        (0..<10_000).map { i in (40..<60).contains(i % 100) && (40..<60).contains(i / 100) ? 1 : 0 }
    }

    func testRefineNames() {
        XCTAssertEqual(parse("mask feather 50"), [.set("maskFeather", 50)])
        XCTAssertEqual(parse("smooth mask less"), [.nudge("maskSmooth", -1)])
        XCTAssertEqual(parse("expand mask 30"), [.set("maskExpand", 30)])
        XCTAssertEqual(parse("shift edge -20"), [.set("maskExpand", -20)])
        XCTAssertEqual(parse("refine edge 60"), [.set("maskRefineEdge", 60)])
    }

    func testExpandAndContract() {
        let sq = square()
        // 100 cells long side: 100 % expand = 3 cells.
        let grown = MaskRaster.refine(sq, settings: ["maskExpand": 100], width: 100, height: 100, pixels: nil)
        XCTAssertEqual(grown.reduce(0, +), 26 * 26)
        XCTAssertEqual(grown[50 * 100 + 37], 1)
        XCTAssertEqual(grown[50 * 100 + 36], 0)
        let shrunk = MaskRaster.refine(sq, settings: ["maskExpand": -100], width: 100, height: 100, pixels: nil)
        XCTAssertEqual(shrunk.reduce(0, +), 14 * 14)
        // At the picture's edge the edge value repeats outwards.
        let edge = MaskRaster.extreme([1, 0, 0, 0, 0, 0], width: 6, height: 1, radius: 2, grow: true)
        XCTAssertEqual(edge, [1, 1, 1, 0, 0, 0])
        XCTAssertEqual(MaskRaster.extreme([0, 1, 1, 1, 1, 1, 1, 0], width: 8, height: 1, radius: 1, grow: false), [0, 0, 1, 1, 1, 1, 0, 0])
    }

    func testFeatherSoftensTheEdgeAndKeepsTheArea() {
        let sq = square()
        let soft = MaskRaster.refine(sq, settings: ["maskFeather": 100], width: 100, height: 100, pixels: nil)
        XCTAssertEqual(soft.reduce(0, +), sq.reduce(0, +), accuracy: 1)
        XCTAssertGreaterThan(soft[50 * 100 + 38], 0.05, "spills out")
        XCTAssertLessThan(soft[50 * 100 + 41], 0.9, "softens inside")
        XCTAssertEqual(soft[50 * 100 + 50], 1, accuracy: 0.05)
    }

    func testSmoothRemovesSpecksAndKeepsBigShapes() {
        var sq = square()
        sq[10 * 100 + 10] = 1  // a one-cell speck
        let smooth = MaskRaster.refine(sq, settings: ["maskSmooth": 100], width: 100, height: 100, pixels: nil)
        XCTAssertEqual(smooth[10 * 100 + 10], 0, "the speck is gone")
        XCTAssertEqual(smooth[50 * 100 + 50], 1)
        XCTAssertEqual(smooth[50 * 100 + 30], 0)
    }

    func testRefineEdgeFollowsThePhotosEdges() {
        // The photo: dark left half, bright right half. The mask: a soft ramp across the middle, not
        // lined up with the photo's edge. Refined, it follows the edge: high on the bright side, low on the dark.
        let w = 100, h = 10  // Refine Edge 100 reaches 3 cells
        var rgb: [Float] = []
        for _ in 0..<h { for x in 0..<w { let v: Float = x < 50 ? 0.1 : 0.9; rgb += [v, v, v] } }
        let pixels = PixelGrid(width: w, height: h, rgb: rgb)
        let ramp: [Float] = (0..<(w * h)).map { i in Float(min(1, max(0, Double(i % w - 40) / 20))) }
        let refined = MaskRaster.refine(ramp, settings: ["maskRefineEdge": 100], width: w, height: h, pixels: pixels)
        XCTAssertLessThan(refined[5 * w + 49], ramp[5 * w + 49] - 0.05, "dark side: less")
        XCTAssertGreaterThan(refined[5 * w + 50], ramp[5 * w + 50] + 0.05, "bright side: more")
        XCTAssertEqual(refined[5 * w + 30], 0, "far from the edge: as it was")
        XCTAssertEqual(refined[5 * w + 70], 1)
        XCTAssertTrue(MaskRaster.needsPixels(Mask(settings: ["maskRefineEdge": 50])))
    }

    func testBoxMeanAtTheBorders() {
        XCTAssertEqual(MaskRaster.box([0, 0, 3, 0, 0], width: 5, height: 1, radius: 1), [0, 1, 1, 1, 0])
        XCTAssertEqual(MaskRaster.box([3, 0, 0], width: 3, height: 1, radius: 1), [1.5, 1, 0])
    }
}
