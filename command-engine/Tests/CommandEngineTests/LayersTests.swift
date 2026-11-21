import XCTest
@testable import CommandEngine

/// The Layers panel: names, selecting and routing to the selected layer, the stack (move, copy,
/// delete, hide), placement maths, and later the blend modes, text, shapes, styles and the rest.
final class LayersTests: XCTestCase {
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

    /// Two photo layers, as the app adds them for "place photo" (the second selected).
    private func twoPhotoLayers() {
        for photo in 0..<2 {
            var layer = Layers.make("photo", registry: registry)
            layer.values["photo"] = Double(photo)
            state.layers.append(layer)
        }
        state.selectLayer(1)
    }

    // MARK: - Names

    func testLayerControlsAreWellFormed() {
        for c in registry.controls where c.scope == "layer" || c.layer != nil || c.takesText {
            XCTAssertEqual(c.group, "layers", c.id)
            if c.takesText { XCTAssertEqual(c.kind, .action, "\(c.id): only actions take words") }
            if c.layer != nil, c.kind != .action { XCTAssertEqual(c.scope, "layer", "\(c.id): a kind's setting is a layer setting") }
        }
    }

    func testLayerNamesReachTheirControls() {
        XCTAssertEqual(parse("layer 2"), [.set("layer", 2)])
        XCTAssertEqual(parse("layer opacity 60"), [.set("layerOpacity", 60)])
        XCTAssertEqual(parse("move layer up"), [.run("moveLayerUp")])
        XCTAssertEqual(parse("move layer down"), [.run("moveLayerDown")])
        XCTAssertEqual(parse("duplicate layer"), [.run("duplicateLayer")])
        XCTAssertEqual(parse("delete layer 2"), [.run("deleteLayer", value: 2)])
        XCTAssertEqual(parse("place photo"), [.run("placePhoto")])
        XCTAssertEqual(parse("layer scale 150"), [.set("layerScale", 150)])
        XCTAssertEqual(parse("rotate layer 30"), [.set("layerRotation", 30)])
        XCTAssertEqual(parse("layer x 20 layer y 80"), [.set("layerX", 20), .set("layerY", 80)])
        XCTAssertEqual(parse("layer position top left"), [.run("layerPosition", value: 5)])
        XCTAssertEqual(parse("move layer to bottom right"), [.run("layerPosition", value: 8)])
        XCTAssertEqual(parse("layer up"), [.nudge("layer", 1)], "the next layer up")
    }

    func testNamesStartingWithKeywordsAreThoseNames() {
        XCTAssertEqual(parse("hide layer"), [.run("hideLayer")])
        XCTAssertEqual(parse("show layer"), [.set("layerVisible", 1)])
        XCTAssertEqual(parse("layer visible off"), [.set("layerVisible", 0)])
        // Keywords still work where no name starts with them.
        XCTAssertEqual(parse("show mask overlay"), [.set("maskOverlay", 1)])
        XCTAssertEqual(parse("hide spots"), [.set("visualizeSpots", 0)])
        XCTAssertEqual(parse("add radial gradient"), [Command(op: .run, control: "radialGradient", mode: "add")])
        XCTAssertEqual(parse("more contrast"), [.nudge("contrast", 1)])
        XCTAssertEqual(parse("add a vignette"), [.nudge("vignette", 1)])
    }

    func testMisheardWordsNeverChangeTheStack() {
        for text in ["delet layer", "duplicat layer", "hid layer"] {
            XCTAssertFalse(parse(text).contains { $0.op == .run }, text)
        }
    }

    // MARK: - Selecting and routing

    func testLayerSettingsNeedALayer() {
        XCTAssertEqual(run("layer opacity 50"), [.needsLayer(controlID: "layerOpacity")])
        XCTAssertEqual(run("delete layer"), [.needsLayer(controlID: "deleteLayer")])
    }

    func testSettingsGoToTheSelectedLayer() {
        twoPhotoLayers()
        XCTAssertEqual(run("layer opacity 60"), [.changedInLayer(layer: 2, controlID: "layerOpacity", from: 100, to: 60)])
        run("layer 1")
        XCTAssertEqual(state.selectedLayer, 0)
        run("layer scale more")
        XCTAssertEqual(state.layers[0].values["layerScale"], 110)
        XCTAssertEqual(state.layers[1].values["layerOpacity"], 60)
        XCTAssertEqual(state.layers[0].opacity, 1)
        XCTAssertEqual(state.layers[1].opacity, 0.6, accuracy: 1e-9)
        run("layer 9")
        XCTAssertEqual(state.selectedLayer, 1, "only layers that exist")
        run("done")
        XCTAssertNil(state.selectedLayer)
        run("layer opacity 20")
        XCTAssertEqual(state.layers[1].values["layerOpacity"], 60, "nothing selected: nothing changes")
        run("layer")
        XCTAssertEqual(state.selectedLayer, 1, "a bare “layer” picks the top one")
    }

    func testMasksAndLayersAreNotSelectedTogether() {
        twoPhotoLayers()
        run("linear gradient from top")
        XCTAssertNil(state.selectedLayer, "a new mask deselects the layer")
        run("layer 1")
        XCTAssertEqual(state.selectedLayer, 0)
        XCTAssertNil(state.selectedMask, "a layer deselects the mask")
        run("heal")
        XCTAssertNil(state.selectedLayer, "a retouch tool deselects the layer")
    }

    // MARK: - The stack

    func testMoveDuplicateDeleteAndHide() {
        twoPhotoLayers()
        run("move layer down")
        XCTAssertEqual(state.layers.map { $0.values["photo"] }, [1, 0])
        XCTAssertEqual(state.selectedLayer, 0, "the selection moves with it")
        run("move layer down")
        XCTAssertEqual(state.layers.map { $0.values["photo"] }, [1, 0], "already the lowest")
        run("move layer up")
        XCTAssertEqual(state.layers.map { $0.values["photo"] }, [0, 1])

        XCTAssertEqual(run("duplicate layer"), [.ran(controlID: "duplicateLayer"), .layered(layer: 3, event: .duplicated(from: 2))])
        XCTAssertEqual(state.layers.count, 3)
        XCTAssertEqual(state.layers[2].values["photo"], 1)
        XCTAssertEqual(state.layers[2].values["layerX"], 53, "nudged so both show")
        XCTAssertEqual(state.selectedLayer, 2)

        run("hide layer 1")
        XCTAssertFalse(state.layers[0].isVisible)
        run("layer 1 show layer")
        XCTAssertTrue(state.layers[0].isVisible)

        XCTAssertEqual(run("delete layer 2"), [.ran(controlID: "deleteLayer"), .layered(layer: 2, event: .deleted)])
        XCTAssertEqual(state.layers.map { $0.values["photo"] }, [0, 1])
        XCTAssertNil(state.selectedLayer)

        run("reset all")
        XCTAssertTrue(state.layers.isEmpty)
    }

    func testNamedPositionsPlaceTheSelectedLayer() {
        twoPhotoLayers()
        run("layer position top right")
        XCTAssertEqual(state.layers[1].values["layerX"], 80)
        XCTAssertEqual(state.layers[1].values["layerY"], 15)
        run("layer position")
        XCTAssertEqual(state.layers[1].values["layerX"], 50, "centre when no place is said")
        XCTAssertEqual(state.layers[0].values["layerX"], 50)
    }

    func testNewLayersGetTheirKindsSettings() {
        let photo = Layers.make("photo", registry: registry)
        XCTAssertEqual(photo.values["layerOpacity"], 100)
        XCTAssertEqual(photo.values["layerVisible"], 1)
        XCTAssertEqual(photo.transform, LayerTransform(x: 0.5, y: 0.5, scale: 1, angle: 0))
        for id in Layers.positions.keys {
            XCTAssertTrue(registry.control(id: "layerPosition")!.options.contains { $0.id == id }, id)
        }
    }

    // MARK: - Placement maths

    func testTransformMapsBothWays() {
        let t = LayerTransform(x: 0.3, y: 0.6, scale: 1.5, angle: 30)
        let p = Vec2(0.1, -0.05)
        let canvas = t.toCanvas(p, width: 1200, height: 800)
        let back = t.toLayer(canvas, width: 1200, height: 800)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        XCTAssertEqual(t.toCanvas(Vec2(0, 0), width: 1200, height: 800), Vec2(360, 480), "the centre")
        // A quarter turn clockwise on screen: right of the centre goes below it.
        let q = LayerTransform(x: 0.5, y: 0.5, scale: 1, angle: 90).toCanvas(Vec2(0.1, 0), width: 1000, height: 1000)
        XCTAssertEqual(q.x, 500, accuracy: 1e-9)
        XCTAssertEqual(q.y, 600, accuracy: 1e-9)
    }

    func testOutlineFollowsTheLayer() {
        var layer = Layers.make("photo", registry: registry)
        layer.values["layerX"] = 25
        let box = Layers.outline(layer, aspect: 2, width: 1000, height: 500)
        // 0.5 L wide (500 px), 250 px tall, centred at 250, 250.
        XCTAssertEqual(box[0], Vec2(0, 125))
        XCTAssertEqual(box[2], Vec2(500, 375))
        layer.values["layerRotation"] = 90
        let turned = Layers.outline(layer, aspect: 2, width: 1000, height: 500)
        XCTAssertEqual(turned[0].x, 375, accuracy: 1e-9, "top-left corner turns to the top-right")
        XCTAssertEqual(turned[0].y, 0, accuracy: 1e-9)
    }

    func testPictureMapPutsAPhotoOnItsLayer() {
        // A 400 × 200 photo (y up) as a layer at the canvas's top-left quarter, a quarter turn clockwise.
        let t = LayerTransform(x: 0.25, y: 0.25, scale: 1, angle: 90)
        let m = t.pictureMap(contentWidth: 400, contentHeight: 200, side: 0.5, width: 1000, height: 800)
        func map(_ x: Double, _ y: Double) -> Vec2 { Vec2(m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]) }
        let centre = map(200, 100)
        XCTAssertEqual(centre.x, 250, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 600, accuracy: 1e-9, "y up: 25 % from the top is 600 from the bottom")
        // Long side 0.5 × 1000 = 500 px; the photo's right edge middle turns to below the centre (y up: lower).
        let right = map(400, 100)
        XCTAssertEqual(right.x, 250, accuracy: 1e-9)
        XCTAssertEqual(right.y, 600 - 250, accuracy: 1e-9)
        // Its top edge middle (y up: 200) turns to the right of the centre.
        let top = map(200, 200)
        XCTAssertEqual(top.x, 250 + 125, accuracy: 1e-9)
        XCTAssertEqual(top.y, 600, accuracy: 1e-9)
    }

    // MARK: - Blend modes

    func testBlendModeNamesMatchControls() {
        XCTAssertEqual(registry.control(id: "layerBlend")!.options.map(\.id), LayerBlend.modes)
        XCTAssertEqual(parse("layer blend multiply"), [.set("layerBlend", 1)])
        XCTAssertEqual(parse("layer blend mode soft light"), [.set("layerBlend", 4)])
        XCTAssertEqual(parse("blend mode screen"), [.set("blendMode", 0)], "still the double exposure's")
    }

    func testSeparableBlendModes() {
        func blend(_ b: Double, _ s: Double, _ mode: String) -> Double { LayerBlend.blend(RGB(b, b, b), RGB(s, s, s), mode: mode).r }
        XCTAssertEqual(blend(0.5, 0.5, "multiply"), 0.25, accuracy: 1e-12)
        XCTAssertEqual(blend(0.5, 0.5, "screen"), 0.75, accuracy: 1e-12)
        XCTAssertEqual(blend(0.2, 0.9, "normal"), 0.9, accuracy: 1e-12)
        XCTAssertEqual(blend(0.25, 0.5, "overlay"), 0.25, accuracy: 1e-12, "dark base: multiply × 2")
        XCTAssertEqual(blend(0.75, 0.5, "overlay"), 0.75, accuracy: 1e-12, "light base: screen")
        XCTAssertEqual(blend(0.5, 0.25, "hardLight"), 0.25, accuracy: 1e-12, "overlay with the layers swapped")
        XCTAssertEqual(blend(0.4, 0.5, "softLight"), 0.4, accuracy: 1e-12, "50 % grey leaves soft light alone")
        XCTAssertLessThan(blend(0.4, 0.2, "softLight"), 0.4)
        XCTAssertEqual(blend(0.3, 0.6, "darken"), 0.3, accuracy: 1e-12)
        XCTAssertEqual(blend(0.3, 0.6, "lighten"), 0.6, accuracy: 1e-12)
        XCTAssertEqual(blend(0.3, 0.5, "colorDodge"), 0.6, accuracy: 1e-12)
        XCTAssertEqual(blend(0, 1, "colorDodge"), 0, accuracy: 1e-12, "black stays black")
        XCTAssertEqual(blend(0.7, 0.5, "colorBurn"), 0.4, accuracy: 1e-12)
        XCTAssertEqual(blend(1, 0, "colorBurn"), 1, accuracy: 1e-12, "white stays white")
        XCTAssertEqual(blend(0.8, 0.3, "difference"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(blend(0.5, 0.5, "exclusion"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(blend(0.9, 1, "exclusion"), 0.1, accuracy: 1e-12, "white inverts")
        // Every separable mode keeps black on white and white on black in range.
        for mode in LayerBlend.modes {
            for (b, s) in [(0.0, 1.0), (1.0, 0.0), (0.0, 0.0), (1.0, 1.0)] {
                let v = blend(b, s, mode)
                XCTAssertTrue(v >= -1e-12 && v <= 1 + 1e-12, "\(mode) \(b) \(s) → \(v)")
            }
        }
    }

    func testNonSeparableBlendModes() {
        let red = RGB(0.9, 0.1, 0.1), grey = RGB(0.5, 0.5, 0.5)
        // Colour: the layer's hue and saturation with the base's luminosity.
        let colored = LayerBlend.blend(grey, red, mode: "color")
        XCTAssertEqual(LayerBlend.lum(colored), 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(colored.r, colored.g)
        // Luminosity: the base's colour at the layer's luminosity.
        let lit = LayerBlend.blend(red, RGB(0.8, 0.8, 0.8), mode: "luminosity")
        XCTAssertEqual(LayerBlend.lum(lit), 0.8, accuracy: 1e-9)
        XCTAssertGreaterThan(lit.r, lit.g)
        // Hue onto grey: grey has no saturation to keep, so it stays grey.
        let hued = LayerBlend.blend(grey, red, mode: "hue")
        XCTAssertEqual(hued.r, hued.g, accuracy: 1e-9)
        // Saturation: grey on top takes the colour out.
        let flat = LayerBlend.blend(red, grey, mode: "saturation")
        XCTAssertEqual(flat.r, flat.b, accuracy: 1e-9)
        XCTAssertEqual(LayerBlend.lum(flat), LayerBlend.lum(red), accuracy: 1e-9)
    }
}
