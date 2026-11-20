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
