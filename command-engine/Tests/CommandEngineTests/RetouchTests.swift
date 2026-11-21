import XCTest
@testable import CommandEngine

/// Retouching: tool and spot names, where the steps live in the edit, and the maths of each tool on
/// small made-up pictures (a stripe or a grey background with a dark spot, …).
final class RetouchTests: XCTestCase {
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

    // MARK: - Pictures

    /// A `width` × `height` picture where every pixel is `f(x, y)` (grey levels, or a colour).
    static func picture(_ width: Int, _ height: Int, _ f: (Int, Int) -> (Float, Float, Float)) -> RGBBuffer {
        var pixels: [Float] = []
        pixels.reserveCapacity(width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let c = f(x, y)
                pixels += [c.0, c.1, c.2]
            }
        }
        return RGBBuffer(width: width, height: height, pixels: pixels)
    }

    /// Horizontal stripes 4 px light, 4 px dark.
    static func stripes(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        let v: Float = (y / 4) % 2 == 0 ? 0.8 : 0.3
        return (v, v, v)
    }

    /// Mean absolute difference of two pictures over a box (all three channels).
    static func difference(_ a: RGBBuffer, _ b: RGBBuffer, in box: PixelBox) -> Float {
        var sum: Float = 0
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let p = a.color(x, y), q = b.color(x, y)
                sum += abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2)
            }
        }
        return sum / Float(3 * box.width * box.height)
    }

    /// Mean of one channel over a box.
    static func mean(_ a: RGBBuffer, _ box: PixelBox, channel: Int = 1) -> Float {
        var sum: Float = 0
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 { sum += a.pixels[3 * (y * a.width + x) + channel] }
        }
        return sum / Float(box.width * box.height)
    }

    /// A step at the pixel (x, y) of a `width` × `height` picture.
    static func tap(_ tool: String, _ x: Double, _ y: Double, of size: (Int, Int), brush: Double, values: [String: Double] = [:]) -> Retouch {
        Retouch(tool: tool, points: [MaskPoint(x / Double(size.0), y / Double(size.1))], size: brush, feather: 30,
                values: values)
    }

    // MARK: - Schema

    func testRetouchControlsAreWellFormed() {
        let tools = control(EditState.retouchToolID)
        XCTAssertEqual(tools.options.map(\.id), RetouchTools.ids, "RetouchTools.ids mirrors the Retouch Tool options")
        for c in registry.controls {
            if let tool = c.tool {
                XCTAssertEqual(c.kind, .action, c.id)
                XCTAssertEqual(c.group, "retouch", c.id)
                XCTAssertTrue(RetouchTools.ids.contains(tool), "\(c.id): no Retouch Tool option \(tool)")
            }
            if c.scope == "retouch" { XCTAssertEqual(c.group, "retouch", c.id) }
        }
        for tool in RetouchTools.ids.dropFirst() {
            XCTAssertTrue(registry.controls.contains { $0.tool == tool }, "no action picks \(tool)")
            for id in RetouchTools.settings(for: tool) { XCTAssertNotNil(registry.control(id: id), "\(tool): no control \(id)") }
        }
    }

    // MARK: - Names

    func testRemoveBrushAndSpotNames() {
        XCTAssertEqual(parse("remove brush"), [.run("removeBrush")])
        XCTAssertEqual(parse("content aware fill"), [.run("removeBrush")])
        XCTAssertEqual(parse("content-aware remove"), [.run("removeBrush")])
        XCTAssertEqual(parse("spot 2"), [.set("spot", 2)])
        XCTAssertEqual(parse("spot opacity 50"), [.set("spotOpacity", 50)])
        XCTAssertEqual(parse("opacity less"), [.nudge("spotOpacity", -1)])
        XCTAssertEqual(parse("delete spot"), [.run("deleteSpot")])
        XCTAssertEqual(parse("delete spot 2"), [.run("deleteSpot", value: 2)])
        XCTAssertEqual(parse("undo last spot"), [.run("undoSpot")])
        XCTAssertEqual(parse("remove last spot"), [.run("undoSpot")])
        XCTAssertEqual(parse("retouch tool off"), [.set("retouchTool", 0)])
        XCTAssertEqual(parse("tool remove brush"), [.set("retouchTool", 1)])
        // Older names keep their meaning.
        XCTAssertEqual(parse("remove mask"), [.run("deleteMask")])
        XCTAssertEqual(parse("remove haze up"), [.nudge("dehaze", 1)])
        XCTAssertEqual(parse("brush size 20"), [.set("brushSize", 20)])
        XCTAssertEqual(parse("undo"), [.unknown("undo")], "Undo (history) is a later feature")
        XCTAssertEqual(parse("blur more"), [.nudge("gaussianBlur", 1)], "“blur” alone is the Gaussian blur filter")
    }

    // MARK: - Steps in the edit

    func testPickingAToolLeavesTheMasksAndPickingAMaskPutsTheToolAway() {
        run("brush mask")
        XCTAssertEqual(run("remove brush"), [.ran(controlID: "removeBrush"), .masked(mask: 0, event: .deselected)])
        XCTAssertEqual(state.retouchTool, "remove")
        XCTAssertNil(state.selectedMask)
        run("mask 1")
        XCTAssertNil(state.retouchTool, "touches go to the mask again")
        run("remove brush")
        XCTAssertEqual(run("done"), [.ran(controlID: "maskDone"), .masked(mask: 0, event: .deselected)])
        XCTAssertNil(state.retouchTool, "done puts the tool away")
        run("retouch tool remove brush")
        XCTAssertEqual(state.retouchTool, "remove")
        run("radial gradient")
        XCTAssertNil(state.retouchTool)
    }

    func testSpotsAreSelectedChangedAndDeleted() {
        let step = Retouch(tool: "remove", points: [MaskPoint(0.5, 0.5)], values: ["spotOpacity": 100])
        for _ in 0..<3 { state.addRetouch(step) }
        XCTAssertEqual(state.selectedRetouch, 2, "a new step is selected")
        XCTAssertEqual(run("spot opacity 50"), [.changedInSpot(spot: 3, controlID: "spotOpacity", from: 100, to: 50)])
        XCTAssertEqual(state.current(control("spotOpacity")), 50, "the slider shows the spot's own opacity")
        XCTAssertEqual(state.value(of: control("spotOpacity")), 100, "new spots still get 100 %")
        XCTAssertEqual(run("spot 1"), [.changed(controlID: "spot", from: 3, to: 1)])
        XCTAssertEqual(run("spot 9"), [.changed(controlID: "spot", from: 1, to: 3)], "at most the last spot")
        run("spot 1")
        XCTAssertEqual(run("delete spot"), [.ran(controlID: "deleteSpot"), .retouched(spot: 1, event: .deleted)])
        XCTAssertEqual(state.retouches.count, 2)
        XCTAssertNil(state.selectedRetouch)
        XCTAssertEqual(run("opacity 30"), [.changed(controlID: "spotOpacity", from: 100, to: 30)], "none selected: for new spots")
        XCTAssertEqual(run("undo last spot"), [.ran(controlID: "undoSpot"), .retouched(spot: 2, event: .deleted)])
        XCTAssertEqual(run("delete spot 5"), [.needsSpot(controlID: "deleteSpot")])
        XCTAssertEqual(run("delete spot 1"), [.ran(controlID: "deleteSpot"), .retouched(spot: 1, event: .deleted)])
        XCTAssertEqual(run("undo last spot"), [.needsSpot(controlID: "undoSpot")])
        state.addRetouch(step)
        XCTAssertEqual(run("reset all").last, .retouched(spot: 0, event: .allDeleted))
        XCTAssertTrue(state.retouches.isEmpty)
    }

    // MARK: - Content-aware fill

    func testInpaintMakesUpStripesAcrossAHole() {
        let clean = Self.picture(64, 64, Self.stripes)
        var spotted = clean
        let hole = (0..<(64 * 64)).map { i -> Bool in
            let x = i % 64, y = i / 64
            return x >= 26 && x < 38 && y >= 26 && y < 38
        }
        for i in hole.indices where hole[i] {
            spotted.pixels[3 * i] = 0.9
            spotted.pixels[3 * i + 1] = 0.1
            spotted.pixels[3 * i + 2] = 0.1
        }
        let filled = Inpaint.fill(spotted, hole: hole)
        let box = PixelBox(x0: 26, y0: 26, x1: 38, y1: 38)
        XCTAssertGreaterThan(Self.difference(spotted, clean, in: box), 0.3)
        XCTAssertLessThan(Self.difference(filled, clean, in: box), 0.08, "the stripes run on through the hole")
        XCTAssertEqual(Self.difference(filled, spotted, in: PixelBox(x0: 0, y0: 0, x1: 64, y1: 20)), 0, "outside stays")
        XCTAssertEqual(Inpaint.fill(spotted, hole: hole), filled, "the same every time")
    }

    func testRemoveBrushTakesASpotAway() {
        let size = (80, 60)
        let clean = Self.picture(size.0, size.1) { x, _ in
            let v = 0.6 + 0.2 * Float(x) / 80
            return (v, v, v)
        }
        var dusty = clean
        for y in 26..<34 {
            for x in 36..<44 { dusty.pixels.replaceSubrange((3 * (y * 80 + x))..<(3 * (y * 80 + x) + 3), with: [0.2, 0.2, 0.2]) }
        }
        let canvas = RetouchCanvas(base: dusty)
        let step = Self.tap("remove", 40, 30, of: size, brush: 20, values: ["spotOpacity": 100])
        let spot = PixelBox(x0: 36, y0: 26, x1: 44, y1: 34)
        let done = canvas.render([step]).image
        XCTAssertLessThan(Self.difference(done, clean, in: spot), 0.03, "the spot is gone")
        XCTAssertEqual(Self.difference(done, dusty, in: PixelBox(x0: 0, y0: 0, x1: 80, y1: 10)), 0, "far away nothing changes")

        // Opacity mixes the result with the picture before the step; deleting the step brings the spot back.
        var half = step
        half.values["spotOpacity"] = 50
        let halfDone = canvas.render([half]).image
        XCTAssertEqual(Self.mean(halfDone, spot), (Self.mean(done, spot) + Self.mean(dusty, spot)) / 2, accuracy: 0.01)
        XCTAssertEqual(canvas.render([]).image, dusty)
        XCTAssertEqual(canvas.render([step]).image, done, "the same again")
    }

    func testCanvasKeepsOtherStepsWhenOneIsDeleted() {
        let size = (90, 40)
        let base = Self.picture(size.0, size.1) { x, y in
            let dark = (abs(x - 20) < 4 && abs(y - 20) < 4) || (abs(x - 70) < 4 && abs(y - 20) < 4)
            return dark ? (0.1, 0.1, 0.1) : (0.7, 0.7, 0.7)
        }
        let canvas = RetouchCanvas(base: base)
        let a = Self.tap("remove", 20, 20, of: size, brush: 15), b = Self.tap("remove", 70, 20, of: size, brush: 15)
        let both = canvas.render([a, b]).image
        let left = PixelBox(x0: 17, y0: 17, x1: 24, y1: 24), right = PixelBox(x0: 67, y0: 17, x1: 74, y1: 24)
        XCTAssertGreaterThan(Self.mean(both, left), 0.6)
        XCTAssertGreaterThan(Self.mean(both, right), 0.6)
        let onlyB = canvas.render([b]).image
        XCTAssertEqual(Self.mean(onlyB, left), 0.1, accuracy: 0.001, "the deleted spot's dust is back")
        XCTAssertEqual(Self.difference(onlyB, both, in: right), 0, "the other spot is kept")
    }

    // MARK: - Heal

    func testHealNames() {
        XCTAssertEqual(parse("heal"), [.run("healTool")])
        XCTAssertEqual(parse("healing brush"), [.run("healTool")])
        XCTAssertEqual(parse("heal brush size 3"), [.run("healTool"), .set("brushSize", 3)], "“size” alone is the brush size")
        XCTAssertEqual(parse("clone source"), [.run("spotSource")])
        XCTAssertEqual(parse("pick source"), [.run("spotSource")])
        XCTAssertEqual(parse("clone mask"), [.run("duplicateMask")])
    }

    func testSourceNeedsASpotThatCopies() {
        XCTAssertEqual(run("clone source"), [.needsSpot(controlID: "spotSource")])
        state.addRetouch(Retouch(tool: "remove", points: [MaskPoint(0.5, 0.5)]))
        XCTAssertEqual(run("clone source"), [.needsSpot(controlID: "spotSource")], "the Remove brush has no source")
        state.addRetouch(Retouch(tool: "heal", points: [MaskPoint(0.5, 0.5)]))
        XCTAssertEqual(run("clone source"), [.ran(controlID: "spotSource")])
        XCTAssertEqual(state.retouches[1].centre, MaskPoint(0.5, 0.5))
        XCTAssertEqual(Retouch(tool: "heal", points: [MaskPoint(0.2, 0.4), MaskPoint(0.6, 0.5)]).centre, MaskPoint(0.4, 0.45))
    }

    func testMembraneIsSmoothBetweenItsEdges() {
        // A linear ramp is harmonic: the membrane fills the hole with the same ramp.
        let w = 30, h = 24
        let ramp = (0..<(w * h * 3)).map { i -> Float in
            let p = i / 3
            return 0.01 * Float(p % w) + 0.02 * Float(p / w) + (i % 3 == 0 ? 0.1 : 0)
        }
        let hole = (0..<(w * h)).map { p in abs(p % w - 15) < 8 && abs(p / w - 12) < 7 }
        var edgeOnly = ramp
        for p in 0..<(w * h) where hole[p] { edgeOnly.replaceSubrange((3 * p)..<(3 * p + 3), with: [9, 9, 9]) }
        let filled = Healing.membrane(edgeOnly, hole: hole, width: w, height: h, iterations: 200)
        let error = zip(filled, ramp).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(error, 0.01)
    }

    func testHealTakesTextureFromNearbyAndMatchesTheColoursAround() {
        // Dark left half, light right half, the same fine texture on both; a spot on the left.
        let size = (120, 60)
        func clean(_ x: Int, _ y: Int) -> (Float, Float, Float) {
            let v: Float = (x < 60 ? 0.35 : 0.75) + ((x + y) % 4 == 0 ? 0.04 : 0)
            return (v, v, v)
        }
        let picture = Self.picture(size.0, size.1) { x, y in
            abs(x - 30) < 4 && abs(y - 30) < 4 ? (0.05, 0.05, 0.05) : clean(x, y)
        }
        let canvas = RetouchCanvas(base: picture)
        let spot = PixelBox(x0: 26, y0: 26, x1: 34, y1: 34)
        let truth = Self.picture(size.0, size.1, clean)

        // Automatic source: a clean place nearby, kept as the step's offset.
        let auto = Self.tap("heal", 30, 30, of: size, brush: 15, values: ["spotOpacity": 100])
        let result = canvas.render([auto])
        XCTAssertLessThan(Self.difference(result.image, truth, in: spot), 0.04)
        let offset = try! XCTUnwrap(result.sources[0])
        let pixels = (offset.x * 120, offset.y * 60)
        XCTAssertGreaterThan((pixels.0 * pixels.0 + pixels.1 * pixels.1).squareRoot(), 12, "the source doesn't overlap the spot")
        var pinned = auto
        pinned.offset = offset
        XCTAssertEqual(canvas.render([pinned]).image, result.image, "the picked source, kept, draws the same")
        XCTAssertTrue(canvas.render([pinned]).sources.isEmpty)

        // A source on the light half still comes out dark: heal matches the colours around the spot.
        var light = auto
        light.offset = MaskPoint(55.0 / 120, 0)
        let healed = canvas.render([light]).image
        XCTAssertEqual(Self.mean(healed, spot), Self.mean(truth, spot), accuracy: 0.04)
    }

    // MARK: - Clone

    func testCloneNames() {
        XCTAssertEqual(parse("clone"), [.run("cloneTool")])
        XCTAssertEqual(parse("clone stamp"), [.run("cloneTool")])
        XCTAssertEqual(parse("clone brush size 4"), [.run("cloneTool"), .set("brushSize", 4)])
        XCTAssertEqual(parse("clone source"), [.run("spotSource")])
    }

    func testCloneCopiesPixelsExactly() {
        // A checkerboard on the left, flat grey on the right; clone the checkerboard onto the grey.
        let size = (100, 50)
        let picture = Self.picture(size.0, size.1) { x, y in
            x < 50 ? (((x / 3 + y / 3) % 2 == 0) ? (0.9, 0.2, 0.2) : (0.1, 0.1, 0.6)) : (0.5, 0.5, 0.5)
        }
        var step = Self.tap("clone", 75, 25, of: size, brush: 20, values: ["spotOpacity": 100])
        step.offset = MaskPoint(-50.0 / 100, 0)
        let out = RetouchCanvas(base: picture).render([step]).image
        // In the brush's hard core every pixel is the one 50 px to the left.
        for y in 22..<28 {
            for x in 72..<78 {
                let a = out.color(x, y), b = picture.color(x - 50, y)
                XCTAssertEqual(a.0, b.0, accuracy: 1e-5)
                XCTAssertEqual(a.2, b.2, accuracy: 1e-5)
            }
        }
        XCTAssertEqual(out.color(95, 5).0, 0.5, "outside the brush nothing changes")

        // No source chosen: one is picked where the surroundings match, so cloning on grey copies grey.
        let auto = Self.tap("clone", 75, 25, of: size, brush: 20)
        let result = RetouchCanvas(base: picture).render([auto])
        XCTAssertEqual(Self.mean(result.image, PixelBox(x0: 70, y0: 20, x1: 80, y1: 30)), 0.5, accuracy: 0.01)
        XCTAssertNotNil(result.sources[0])
    }

    // MARK: - Patch and Content-Aware Move

    func testPatchAndMoveNames() {
        XCTAssertEqual(parse("patch"), [.run("patchTool")])
        XCTAssertEqual(parse("patch tool"), [.run("patchTool")])
        XCTAssertEqual(parse("content aware move"), [.run("moveTool")])
        XCTAssertEqual(parse("content-aware move"), [.run("moveTool")])
        XCTAssertEqual(parse("move tool"), [.run("moveTool")])
    }

    func testOutlineContainsPoints() {
        let square = Retouch(tool: "patch", points: [MaskPoint(0.2, 0.2), MaskPoint(0.6, 0.2), MaskPoint(0.6, 0.5), MaskPoint(0.2, 0.5)])
        XCTAssertTrue(square.contains(MaskPoint(0.4, 0.3)))
        XCTAssertFalse(square.contains(MaskPoint(0.7, 0.3)))
        XCTAssertFalse(Retouch(tool: "patch", points: [MaskPoint(0.2, 0.2), MaskPoint(0.6, 0.2)]).contains(MaskPoint(0.4, 0.2)))
        XCTAssertEqual(square.centre, MaskPoint(0.4, 0.35))
    }

    /// An outline (a square of side 2 × `half` px) around the pixel (x, y) of a `size` picture.
    static func outline(_ tool: String, _ x: Double, _ y: Double, half: Double, of size: (Int, Int)) -> Retouch {
        let w = Double(size.0), h = Double(size.1)
        return Retouch(tool: tool, points: [MaskPoint((x - half) / w, (y - half) / h), MaskPoint((x + half) / w, (y - half) / h),
                                            MaskPoint((x + half) / w, (y + half) / h), MaskPoint((x - half) / w, (y + half) / h)],
                       feather: 30, values: ["spotOpacity": 100])
    }

    func testPatchHealsTheOutlineFromWhereItWasDragged() {
        let size = (100, 60)
        let clean = Self.picture(size.0, size.1) { x, y in
            let v: Float = 0.5 + 0.2 * Float(y) / 60 + ((x + 2 * y) % 5 == 0 ? 0.05 : 0)
            return (v, v, v)
        }
        var flawed = clean
        for y in 25..<35 {
            for x in 20..<30 { flawed.pixels.replaceSubrange((3 * (y * 100 + x))..<(3 * (y * 100 + x) + 3), with: [0.9, 0.1, 0.1]) }
        }
        let spot = PixelBox(x0: 20, y0: 25, x1: 30, y1: 35)
        var patch = Self.outline("patch", 25, 30, half: 8, of: size)
        patch.offset = MaskPoint(45.0 / 100, 0)  // dragged 45 px to the right, onto clean texture
        let canvas = RetouchCanvas(base: flawed)
        XCTAssertLessThan(Self.difference(canvas.render([patch]).image, clean, in: spot), 0.05)
        // Not dragged: a source is picked nearby.
        patch.offset = nil
        let auto = canvas.render([patch])
        XCTAssertNotNil(auto.sources[0])
        XCTAssertLessThan(Self.difference(auto.image, clean, in: spot), 0.05)
    }

    func testContentAwareMoveFillsTheOldPlaceAndPutsTheAreaDown() {
        let size = (120, 60)
        let ground: Float = 0.7
        let picture = Self.picture(size.0, size.1) { x, y in
            abs(x - 30) < 6 && abs(y - 30) < 6 ? (0.1, 0.1, 0.1) : (ground, ground, ground)
        }
        var move = Self.outline("move", 30, 30, half: 9, of: size)
        let canvas = RetouchCanvas(base: picture)
        XCTAssertEqual(canvas.render([move]).image, picture, "not dragged yet: nothing moves")
        move.offset = MaskPoint(55.0 / 120, 0)
        let moved = canvas.render([move]).image
        XCTAssertEqual(Self.mean(moved, PixelBox(x0: 26, y0: 26, x1: 34, y1: 34)), ground, accuracy: 0.03, "the old place is filled")
        XCTAssertEqual(Self.mean(moved, PixelBox(x0: 81, y0: 26, x1: 89, y1: 34)), 0.1, accuracy: 0.01, "the object is 55 px to the right")
    }

    // MARK: - Visualize spots

    func testVisualizeSpotsNames() {
        XCTAssertEqual(parse("show spots"), [.set("visualizeSpots", 1)])
        XCTAssertEqual(parse("hide spots"), [.set("visualizeSpots", 0)])
        XCTAssertEqual(parse("visualize spots"), [.set("visualizeSpots", 1)])
        XCTAssertEqual(parse("visualize threshold 70"), [.set("visualizeThreshold", 70)])
        XCTAssertEqual(parse("spot 2"), [.set("spot", 2)], "“spot” still selects a spot")
    }

    func testVisualizeTableStretchesSmallDifferences() {
        let middle = VisualizeSpots.table(threshold: 50)
        XCTAssertEqual(middle.count, 256)
        XCTAssertEqual(middle[0], 0)
        // A speck 0.1 darker than its surroundings shows bright; noise of 0.005 stays nearly black.
        func at(_ table: [Double], _ x: Double) -> Double { table[Int((x * 255).rounded())] }
        XCTAssertGreaterThan(at(middle, 0.1), 0.7)
        XCTAssertLessThan(at(middle, 0.004), 0.05)
        XCTAssertGreaterThan(at(VisualizeSpots.table(threshold: 90), 0.03), at(middle, 0.03), "a higher threshold shows more")
        XCTAssertEqual(VisualizeSpots.table(threshold: 100).max(), 1)
    }

    // MARK: - Red eye and pet eye

    func testEyeNames() {
        XCTAssertEqual(parse("red eye"), [.run("redEye")])
        XCTAssertEqual(parse("red-eye"), [.run("redEye")])
        XCTAssertEqual(parse("pet eye"), [.run("petEye")])
        XCTAssertEqual(parse("pupil size 70"), [.set("pupilSize", 70)])
        XCTAssertEqual(parse("darken more"), [.nudge("pupilDarken", 1)])
        XCTAssertEqual(parse("catchlight off"), [.set("catchlight", 0)])
        XCTAssertEqual(parse("red saturation -40"), [.set("mixerRedSaturation", -40)], "other “red” names keep their meaning")
    }

    /// Skin with an eye at (40, 30): a brown iris of radius 10 and a pupil of radius 6 in `pupil`'s colour.
    static func eye(pupil: (Float, Float, Float)) -> RGBBuffer {
        picture(80, 60) { x, y in
            let d = (Double((x - 40) * (x - 40) + (y - 30) * (y - 30))).squareRoot()
            return d < 6 ? pupil : d < 10 ? (0.45, 0.3, 0.2) : (0.87, 0.68, 0.58)
        }
    }

    func testRedEyeTakesTheRedOutOfThePupilOnly() {
        let size = (80, 60)
        let picture = Self.eye(pupil: (0.85, 0.12, 0.1))
        let pupil = PixelBox(x0: 37, y0: 27, x1: 43, y1: 33), skin = PixelBox(x0: 0, y0: 0, x1: 20, y1: 20)
        let values: [String: Double] = ["spotOpacity": 100, "pupilSize": 50, "pupilDarken": 50]
        let fixed = RetouchCanvas(base: picture).render([Self.tap("redEye", 40, 30, of: size, brush: 25, values: values)]).image
        XCTAssertLessThan(Self.mean(fixed, pupil, channel: 0), 0.15, "no more red")
        XCTAssertEqual(Self.mean(fixed, PixelBox(x0: 37, y0: 22, x1: 43, y1: 23)), Self.mean(picture, PixelBox(x0: 37, y0: 22, x1: 43, y1: 23)),
                       accuracy: 0.01, "the brown iris keeps its colour")
        XCTAssertEqual(Self.difference(fixed, picture, in: skin), 0)
        // A brush wider than the iris: the brown iris and the skin still keep their colour.
        let wide = RetouchCanvas(base: picture).render([Self.tap("redEye", 40, 30, of: size, brush: 50, values: values)]).image
        XCTAssertEqual(Self.difference(wide, picture, in: PixelBox(x0: 30, y0: 28, x1: 33, y1: 32)), 0, accuracy: 0.001)
        XCTAssertLessThan(Self.mean(wide, pupil, channel: 0), 0.15)
        // Darker with more Pupil Darken; drawn around the eye works like a tap.
        var darker = values
        darker["pupilDarken"] = 100
        let around = Retouch(tool: "redEye", points: [MaskPoint(30.0 / 80, 30.0 / 60), MaskPoint(40.0 / 80, 20.0 / 60),
                                                       MaskPoint(50.0 / 80, 30.0 / 60), MaskPoint(40.0 / 80, 40.0 / 60)], values: darker)
        let dark = RetouchCanvas(base: picture).render([around]).image
        XCTAssertLessThan(Self.mean(dark, pupil), Self.mean(fixed, pupil))
        XCTAssertLessThan(Self.mean(dark, pupil, channel: 0), 0.15)
    }

    func testPetEyeDarkensTheGlowAndAddsACatchlight() {
        let size = (80, 60)
        let picture = Self.eye(pupil: (0.75, 1, 0.7))
        let pupil = PixelBox(x0: 38, y0: 30, x1: 44, y1: 34)
        var values: [String: Double] = ["spotOpacity": 100, "pupilSize": 50, "pupilDarken": 50, "catchlight": 0]
        let plain = RetouchCanvas(base: picture).render([Self.tap("petEye", 40, 30, of: size, brush: 25, values: values)]).image
        XCTAssertLessThan(Self.mean(plain, pupil), 0.2, "the glow is gone")
        values["catchlight"] = 1
        let lit = RetouchCanvas(base: picture).render([Self.tap("petEye", 40, 30, of: size, brush: 25, values: values)]).image
        let dot = PixelBox(x0: 37, y0: 27, x1: 39, y1: 29)
        XCTAssertGreaterThan(Self.mean(lit, dot), Self.mean(plain, dot) + 0.4,
                             "a highlight up and to the left of the middle")
    }

    func testEyeSettingsBelongToTheSelectedEye() {
        state.addRetouch(Retouch(tool: "redEye", points: [MaskPoint(0.5, 0.5)], values: ["spotOpacity": 100, "pupilSize": 50, "pupilDarken": 50]))
        XCTAssertEqual(run("pupil size 80"), [.changedInSpot(spot: 1, controlID: "pupilSize", from: 50, to: 80)])
        XCTAssertEqual(state.value(of: control("pupilSize")), 50, "new eyes still get 50")
        XCTAssertEqual(run("catchlight off"), [.changed(controlID: "catchlight", from: 1, to: 0)], "a red eye has no catchlight: for new eyes")
        XCTAssertEqual(RetouchTools.settings(for: "petEye"), ["spotOpacity", "pupilSize", "pupilDarken", "catchlight"])
    }

    // MARK: - Liquify

    func testLiquifyNames() {
        XCTAssertEqual(parse("liquify"), [.run("liquify")])
        XCTAssertEqual(parse("liquify pucker"), [.run("liquify", value: 2)])
        XCTAssertEqual(parse("liquefy bloat"), [.run("liquify", value: 3)])
        XCTAssertEqual(parse("liquify forward warp"), [.run("liquify", value: 0)])
        XCTAssertEqual(parse("liquify mode twirl"), [.set("liquifyMode", 1)])
        XCTAssertEqual(parse("tool strength 80"), [.set("toolStrength", 80)])
        XCTAssertEqual(parse("pressure less"), [.nudge("toolStrength", -1)])
        XCTAssertEqual(run("liquify reconstruct"), [.ran(controlID: "liquify")])
        XCTAssertEqual(state.retouchTool, "liquify")
        XCTAssertEqual(state.value(of: control("liquifyMode")), 4, "the option sets Liquify Mode")
        XCTAssertEqual(control("liquifyMode").options.map(\.id), LiquifyField.modes)
        XCTAssertEqual(control("liquify").options.map(\.id), LiquifyField.modes)
    }

    /// Grey with dark vertical lines every 8 px (x = 4, 12, 20, …).
    static func lines(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        x % 8 == 4 ? (0.1, 0.1, 0.1) : (0.8, 0.8, 0.8)
    }

    func testLiquifyPushMovesLinesAlongTheStroke() {
        let size = (96, 64)
        let picture = Self.picture(size.0, size.1, Self.lines)
        let push = Retouch(tool: "liquify", points: [MaskPoint(40.0 / 96, 0.5), MaskPoint(52.0 / 96, 0.5)], size: 40,
                           values: ["liquifyMode": 0, "toolStrength": 100, "spotOpacity": 100])
        let canvas = RetouchCanvas(base: picture)
        let pushed = canvas.render([push]).image
        // Near the stroke's end the line from x = 44 is now about 12 px further right (strength 100 moves with the brush).
        let row = 32
        let darkest = (40..<64).min { pushed.color($0, row).0 < pushed.color($1, row).0 }!
        XCTAssertNotEqual(darkest % 8, 4, "the lines moved")
        XCTAssertGreaterThan(Self.difference(pushed, picture, in: PixelBox(x0: 36, y0: 26, x1: 60, y1: 38)), 0.1)
        XCTAssertEqual(Self.difference(pushed, picture, in: PixelBox(x0: 0, y0: 0, x1: 96, y1: 6)), 0, "far away nothing moves")

        // Reconstruct over it brings the lines back.
        var restore = push
        restore.points = [MaskPoint(46.0 / 96, 0.5)]
        restore.size = 80
        restore.values["liquifyMode"] = 4
        let restored = canvas.render([push, restore]).image
        XCTAssertLessThan(Self.difference(restored, picture, in: PixelBox(x0: 36, y0: 26, x1: 60, y1: 38)), 0.03)

        // A spot made after liquifying is kept where its pixels were before liquify.
        let moved = canvas.unwarp(MaskPoint(52.0 / 96, 0.5))
        _ = canvas.render([push])
        XCTAssertLessThan(canvas.unwarp(MaskPoint(52.0 / 96, 0.5)).x, 50.0 / 96, "the brush's end shows what was further left")
        XCTAssertEqual(moved.y, 0.5, accuracy: 0.001)
    }

    func testTwirlPuckerAndBloat() {
        let size = (64, 64)
        let picture = Self.picture(size.0, size.1, Self.lines)
        func tap(_ mode: Double) -> RGBBuffer {
            RetouchCanvas(base: picture).render([Retouch(tool: "liquify", points: [MaskPoint(0.5, 0.5)], size: 50,
                                                         values: ["liquifyMode": mode, "toolStrength": 100, "spotOpacity": 100])]).image
        }
        let middle = PixelBox(x0: 20, y0: 20, x1: 44, y1: 44)
        // Twirl bends the vertical lines: a column that was all light now crosses dark.
        let twirled = tap(1)
        XCTAssertGreaterThan(Self.difference(twirled, picture, in: middle), 0.1)
        // Pucker pulls the line 4 px right of the middle (x = 36) towards it, bloat pushes it away.
        func line(_ image: RGBBuffer) -> Int { (33...42).min { image.color($0, 32).0 < image.color($1, 32).0 }! }
        XCTAssertEqual(line(picture), 36)
        XCTAssertLessThan(line(tap(2)), 36)
        XCTAssertGreaterThan(line(tap(3)), 36)
    }

    // MARK: - Dodge and burn

    func testDodgeAndBurnNames() {
        XCTAssertEqual(parse("dodge"), [.run("dodge")])
        XCTAssertEqual(parse("dodge midtones"), [.run("dodge", value: 1)])
        XCTAssertEqual(parse("burn highlights"), [.run("burn", value: 2)])
        XCTAssertEqual(parse("tone range shadows"), [.set("toneRange", 0)])
        XCTAssertEqual(parse("dodge exposure 30"), [.set("toolStrength", 30)])
        XCTAssertEqual(parse("highlights 20"), [.set("highlights", 20)], "the Light slider keeps its name")
        run("burn shadows")
        XCTAssertEqual(state.retouchTool, "burn")
        XCTAssertEqual(state.value(of: control("toneRange")), 0)
        for tool in ["dodge", "burn"] { XCTAssertEqual(control(tool).options.map(\.id), control("toneRange").options.map(\.id)) }
    }

    func testToneRangesWeighTheirTones() {
        XCTAssertEqual(ToneBrushes.rangeWeight(0.05, range: 0), 1)
        XCTAssertEqual(ToneBrushes.rangeWeight(0.8, range: 0), 0)
        XCTAssertEqual(ToneBrushes.rangeWeight(0.5, range: 1), 1)
        XCTAssertEqual(ToneBrushes.rangeWeight(0, range: 1), 0)
        XCTAssertEqual(ToneBrushes.rangeWeight(0.95, range: 2), 1)
        XCTAssertEqual(ToneBrushes.rangeWeight(0.3, range: 2), 0)
        XCTAssertEqual(ToneBrushes.encode(ToneBrushes.decode(0.42)), 0.42, accuracy: 1e-5)
    }

    func testDodgeLightensMidtonesAndBurnDarkensWherePainted() {
        // A grey ramp from black (left) to white (right); a stroke across all of it.
        let size = (100, 60)
        let ramp = Self.picture(size.0, size.1) { x, _ in
            let v = Float(x) / 99
            return (v, v, v)
        }
        let stroke = [MaskPoint(0.01, 0.5), MaskPoint(0.99, 0.5)]
        func painted(_ tool: String, range: Double) -> RGBBuffer {
            RetouchCanvas(base: ramp).render([Retouch(tool: tool, points: stroke, size: 30, feather: 0,
                                                      values: ["toneRange": range, "toolStrength": 100, "spotOpacity": 100])]).image
        }
        let dodged = painted("dodge", range: 1)
        func at(_ image: RGBBuffer, _ x: Int) -> Float { image.color(x, 30).1 }
        XCTAssertGreaterThan(at(dodged, 50), at(ramp, 50) + 0.15, "mid grey about a stop lighter")
        XCTAssertLessThan(at(dodged, 5) - at(ramp, 5), 0.02, "black barely changes")
        XCTAssertEqual(at(dodged, 50), ToneBrushes.encode(ToneBrushes.decode(at(ramp, 50)) * 2), accuracy: 0.01)
        XCTAssertEqual(dodged.color(50, 5).1, ramp.color(50, 5).1, "outside the brush nothing changes")

        let burned = painted("burn", range: 0)
        XCTAssertLessThan(at(burned, 15), at(ramp, 15) - 0.03, "shadows darker")
        XCTAssertEqual(at(burned, 85), at(ramp, 85), accuracy: 0.001, "lights untouched")

        // Pressure: a light press does less.
        var light = Retouch(tool: "dodge", points: stroke, pressure: [0.3, 0.3], size: 30, feather: 0,
                            values: ["toneRange": 1, "toolStrength": 100, "spotOpacity": 100])
        let soft = RetouchCanvas(base: ramp).render([light]).image
        XCTAssertLessThan(at(soft, 50), at(dodged, 50) - 0.05)
        light.pressure = []
        XCTAssertEqual(RetouchCanvas(base: ramp).render([light]).image, dodged)
    }

    // MARK: - Sponge

    func testSpongeNames() {
        XCTAssertEqual(parse("sponge"), [.run("sponge")])
        XCTAssertEqual(parse("sponge desaturate"), [.run("sponge", value: 1)])
        XCTAssertEqual(parse("sponge saturate"), [.run("sponge", value: 0)])
        XCTAssertEqual(parse("sponge mode saturate"), [.set("spongeMode", 0)])
        XCTAssertEqual(parse("sponge flow 60"), [.set("toolStrength", 60)])
        XCTAssertEqual(parse("saturation 20"), [.set("saturation", 20)], "the Color slider keeps its name")
        XCTAssertEqual(control("sponge").options.map(\.id), control("spongeMode").options.map(\.id))
    }

    func testSpongeTakesColourAwayOrAddsIt() {
        let size = (60, 60)
        let red = Self.picture(size.0, size.1) { _, _ in (0.7, 0.3, 0.3) }
        func sponged(_ mode: Double, strength: Double) -> RGBBuffer {
            RetouchCanvas(base: red).render([Self.tap("sponge", 30, 30, of: size, brush: 60,
                                                      values: ["spongeMode": mode, "toolStrength": strength, "spotOpacity": 100])]).image
        }
        func chroma(_ image: RGBBuffer) -> Float { let c = image.color(30, 30); return c.0 - c.1 }
        XCTAssertLessThan(chroma(sponged(1, strength: 100)), 0.01, "fully grey at full strength")
        XCTAssertEqual(chroma(sponged(1, strength: 50)), 0.2, accuracy: 0.01, "half the colour at half strength")
        XCTAssertEqual(chroma(sponged(0, strength: 50)), 0.6, accuracy: 0.01)
        let c = sponged(1, strength: 100).color(30, 30)
        XCTAssertEqual(c.0, 0.2126 * 0.7 + 0.7152 * 0.3 + 0.0722 * 0.3, accuracy: 0.001, "its own brightness kept")
    }

    // MARK: - Blur, sharpen and smudge brushes

    func testBlurSharpenSmudgeNames() {
        XCTAssertEqual(parse("blur brush"), [.run("blurBrush")])
        XCTAssertEqual(parse("blur brush brush size 6"), [.run("blurBrush"), .set("brushSize", 6)])
        XCTAssertEqual(parse("sharpen brush"), [.run("sharpenBrush")])
        XCTAssertEqual(parse("sharpen more more"), [.nudge("sharpening", 2)], "“sharpen” alone is still Sharpening")
        XCTAssertEqual(parse("smudge"), [.run("smudge")])
        XCTAssertEqual(parse("smudge strength 70"), [.set("toolStrength", 70)])
        XCTAssertEqual(parse("blur more"), [.nudge("gaussianBlur", 1)], "“blur” alone is the Gaussian blur filter")
    }

    func testBlurAndSharpenBrushesChangeDetailWherePainted() {
        let size = (64, 64)
        let picture = Self.picture(size.0, size.1, Self.stripes)
        func painted(_ tool: String) -> RGBBuffer {
            RetouchCanvas(base: picture).render([Retouch(tool: tool, points: [MaskPoint(0.1, 0.5), MaskPoint(0.9, 0.5)], size: 40, feather: 0,
                                                         values: ["toolStrength": 100, "spotOpacity": 100])]).image
        }
        /// Brightness range down one column in the stroke's middle (rows 26…37).
        func range(_ image: RGBBuffer) -> Float {
            let values = (26..<38).map { image.color(32, $0).1 }
            return values.max()! - values.min()!
        }
        XCTAssertLessThan(range(painted("blurBrush")), range(picture) - 0.1, "stripes softened")
        XCTAssertGreaterThan(range(painted("sharpenBrush")), range(picture) + 0.05, "stripes crisper")
        XCTAssertEqual(painted("blurBrush").color(32, 2).1, picture.color(32, 2).1, "outside the brush nothing changes")
    }

    func testSmudgeDragsColourAlongTheStroke() {
        // Red on the left half, blue on the right; smudge from the red into the blue.
        let size = (80, 40)
        let picture = Self.picture(size.0, size.1) { x, _ in x < 40 ? (0.9, 0.1, 0.1) : (0.1, 0.1, 0.9) }
        let stroke = Retouch(tool: "smudge", points: [MaskPoint(30.0 / 80, 0.5), MaskPoint(55.0 / 80, 0.5)], size: 20, feather: 30,
                             values: ["toolStrength": 80, "spotOpacity": 100])
        let smudged = RetouchCanvas(base: picture).render([stroke]).image
        XCTAssertGreaterThan(smudged.color(46, 20).0, 0.3, "red carried into the blue")
        XCTAssertEqual(smudged.color(46, 2).0, 0.1, "outside the brush nothing changes")
        XCTAssertEqual(smudged.color(10, 20).0, 0.9, "behind the stroke's start nothing changes")
    }
}
