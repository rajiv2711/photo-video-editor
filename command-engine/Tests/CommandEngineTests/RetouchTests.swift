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
}
