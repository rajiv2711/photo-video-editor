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
        XCTAssertEqual(parse("blur more"), [.unknown("blur")])
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
}
