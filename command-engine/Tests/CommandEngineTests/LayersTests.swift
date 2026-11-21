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

    func testPlacePhotoMakesALayerTheNextWordsChange() {
        XCTAssertEqual(run("place photo 2 layer opacity 40"), [.ran(controlID: "placePhoto"), .layered(layer: 1, event: .created("photo")),
                                                              .changedInLayer(layer: 1, controlID: "layerOpacity", from: 100, to: 40)])
        XCTAssertEqual(state.layers[0].values["picked"], 2)
        run("place photo")
        XCTAssertEqual(state.layers[1].values["picked"], 0, "the last photo picked")
    }

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

    // MARK: - Adjustment layers and layer masks

    func testAdjustmentLayersTakeTheMaskSliders() {
        XCTAssertEqual(parse("new adjustment layer"), [.run("newAdjustmentLayer")])
        XCTAssertEqual(run("new adjustment layer"), [.ran(controlID: "newAdjustmentLayer"), .layered(layer: 1, event: .created("adjustment"))])
        XCTAssertEqual(run("exposure -1"), [.changedInLayer(layer: 1, controlID: "exposure", from: 0, to: -1)])
        XCTAssertEqual(state.layers[0].adjustments["exposure"], -1)
        XCTAssertNil(state.values["exposure"], "the photo's own exposure stays")
        XCTAssertEqual(state.current(registry.control(id: "exposure")!), -1, "the slider shows the layer's")
        run("hdr on")
        XCTAssertEqual(value("hdr"), 1, "sliders a mask can't hold stay global")
        run("done exposure 0.5")
        XCTAssertEqual(value("exposure"), 0.5, "deselected: the photo's own")
        XCTAssertEqual(state.layers[0].adjustments["exposure"], -1)
        // A photo layer selected: exposure is the photo's.
        state.layers.append(Layers.make("photo", registry: registry))
        state.selectLayer(1)
        run("exposure 1")
        XCTAssertEqual(value("exposure"), 1)
        XCTAssertTrue(state.layers[1].adjustments.isEmpty)
    }

    private func value(_ id: String) -> Double {
        state.value(of: registry.control(id: id)!)
    }

    func testLayerMasksAreMaskPartsOnTheCanvas() {
        XCTAssertEqual(registry.control(id: "layerMask")!.options.map(\.id), Layers.maskOptions)
        XCTAssertEqual(parse("layer mask from top"), [.run("layerMask", value: 1)])
        XCTAssertEqual(parse("layer mask off"), [.run("layerMask", value: 6)])
        XCTAssertEqual(parse("invert layer mask"), [.run("invertLayerMask")])
        XCTAssertEqual(run("layer mask top"), [.needsLayer(controlID: "layerMask")])
        run("new adjustment layer exposure -1")
        run("layer mask top")
        let part = state.layers[0].mask!.components[0]
        XCTAssertEqual(part.kind, "linear")
        XCTAssertEqual(part.values["linearAngle"], 0, "full at the top")
        run("layer mask center")
        XCTAssertEqual(state.layers[0].mask!.components.map(\.kind), ["radial"], "a preset replaces the mask")
        run("layer mask brush")
        XCTAssertEqual(state.layers[0].mask!.components.map(\.kind), ["radial", "brush"], "a brush adds to it")
        run("layer mask brush")
        XCTAssertEqual(state.layers[0].mask!.components.count, 2, "painting on goes on the same brush")
        XCTAssertTrue(state.addLayerMaskStroke(MaskStroke(points: [MaskPoint(0.1, 0.5), MaskPoint(0.9, 0.5)])))
        XCTAssertEqual(state.layers[0].mask!.components[1].strokes.count, 1)
        run("invert layer mask")
        XCTAssertEqual(state.layers[0].mask!.settings["maskInvert"], 1)
        run("invert layer mask")
        XCTAssertEqual(state.layers[0].mask!.settings["maskInvert"], 0)
        // The mask's picture: the Masks panel's raster on the canvas.
        run("layer mask left")
        let grid = MaskRaster.render(state.layers[0].mask!, width: 40, height: 20, pixels: nil)
        XCTAssertGreaterThan(grid[10 * 40 + 1], 0.9, "left side shows")
        XCTAssertLessThan(grid[10 * 40 + 38], 0.1, "right side hidden")
        run("layer mask none")
        XCTAssertNil(state.layers[0].mask)
        XCTAssertEqual(run("invert layer mask"), [.ran(controlID: "invertLayerMask"), .layered(layer: 1, event: .noMask)])
        XCTAssertFalse(state.addLayerMaskStroke(MaskStroke(points: [MaskPoint(0.5, 0.5)])))
    }

    // MARK: - Text

    func testWordsAfterATextNameAreTheText() {
        XCTAssertEqual(parse("new text layer hello world"), [.run("newTextLayer", text: "hello world")])
        XCTAssertEqual(parse("New text layer, Happy Birthday Mum!"), [.run("newTextLayer", text: "Happy Birthday Mum!")], "as typed")
        XCTAssertEqual(parse("Add text: Hello world."), [.run("newTextLayer", text: "Hello world")], "speech's full stop goes")
        XCTAssertEqual(parse("add text Wait..."), [.run("newTextLayer", text: "Wait...")])
        XCTAssertEqual(parse("new text layer"), [.run("newTextLayer", text: nil)])
        // Quotes keep the words apart from the commands after them.
        XCTAssertEqual(parse("new text layer \"Sale 50%\" text size 80 text colour red"),
                       [.run("newTextLayer", text: "Sale 50%"), .set("textSize", 80), .set("textColor", 2)])
        XCTAssertEqual(parse("text size 80 add text “Hi, there”"), [.set("textSize", 80), .run("newTextLayer", text: "Hi, there")])
        XCTAssertEqual(parse("edit text 'goodbye'"), [.run("editText", text: "goodbye")])
        XCTAssertEqual(parse("change text to Good night"), [.run("editText", text: "Good night")])
        XCTAssertEqual(parse("new text layer to do"), [.run("newTextLayer", text: "to do")], "only after Edit Text")
        // Words of the text that are names stay words.
        XCTAssertEqual(parse("add text contrast more"), [.run("newTextLayer", text: "contrast more")])
        // A longer name that only starts like one takes no words.
        XCTAssertEqual(parse("text size 48"), [.set("textSize", 48)])
        XCTAssertEqual(parse("text font serif"), [.set("textFont", 1)])
        XCTAssertEqual(parse("text colour white"), [.set("textColor", 0)])
        XCTAssertEqual(parse("white text colour"), [.set("textColor", 0)], "an option before its name")
        XCTAssertEqual(Command.run("newTextLayer", text: "Hi").json, #"{"control":"newTextLayer","op":"run","text":"Hi"}"#)
        XCTAssertEqual(Command.run("auto").json, #"{"control":"auto","op":"run"}"#, "no text: no key")
    }

    func testTokenRangesMatchTheTokenizer() {
        for text in ["contrast more, more!", "  Exposure 0.5.  ", "red curve 75 up", "a;b:c?d", "New text layer “Hi”"] {
            XCTAssertEqual(CommandParser.tokenRanges(text).map(\.token), CommandParser.tokenize(text), text)
        }
    }

    func testTextLayers() {
        run("new text layer Hello")
        XCTAssertEqual(state.layers.count, 1)
        XCTAssertEqual(state.layers[0].kind, "text")
        XCTAssertEqual(state.layers[0].text, "Hello")
        XCTAssertEqual(state.layers[0].values["textSize"], 60)
        XCTAssertEqual(state.selectedLayer, 0)
        run("text size 120 text font script text colour yellow")
        XCTAssertEqual(state.layers[0].values["textSize"], 120)
        XCTAssertEqual(Layers.fonts[Int(state.layers[0].values["textFont"]!)], "script")
        XCTAssertEqual(Layers.color(state.layers[0].values["textColor"]!), Layers.colors[4].rgb)
        XCTAssertEqual(registry.control(id: "textFont")!.options.map(\.id), Layers.fonts)
        XCTAssertEqual(registry.control(id: "textColor")!.options.map(\.id), Layers.colors.map(\.id))
        run("edit text Goodbye")
        XCTAssertEqual(state.layers[0].text, "Goodbye")
        // Text settings go to the newest text layer when another kind is selected.
        state.layers.append(Layers.make("photo", registry: registry))
        state.selectLayer(1)
        run("text size 30")
        XCTAssertEqual(state.layers[0].values["textSize"], 30)
        XCTAssertNil(state.layers[1].values["textSize"])
        run("new text layer")
        XCTAssertEqual(state.layers[2].text, "Text", "no words: a placeholder")
        // Its outline: about 0.6 of the size per letter, 1.2 per line.
        let size = Layers.size(of: state.layers[0])!
        XCTAssertEqual(size.width, 7 * 0.6 * 0.03, accuracy: 1e-9)
        XCTAssertEqual(size.height, 1.2 * 0.03, accuracy: 1e-9)
    }

    // MARK: - Shapes and pen paths

    func testShapeNames() {
        XCTAssertEqual(parse("add rectangle"), [.run("addRectangle")], "a shape layer, not a marquee mask")
        XCTAssertEqual(parse("add ellipse"), [.run("addEllipse")])
        XCTAssertEqual(parse("rectangle"), [.run("rectangleMarquee")], "alone it is still the mask")
        XCTAssertEqual(parse("shape fill red"), [.set("shapeFill", 3)])
        XCTAssertEqual(parse("shape fill none"), [.set("shapeFill", 0)])
        XCTAssertEqual(parse("pen tool"), [.run("penTool")])
        XCTAssertEqual(parse("polygon sides 5"), [.set("polygonSides", 5)])
        XCTAssertEqual(registry.control(id: "shapeFill")!.options.map(\.id), ["none"] + Layers.colors.map(\.id))
        XCTAssertEqual(Layers.color(registry.control(id: "shapeFill")!.defaultValue, none: true), Layers.colors[6].rgb, "blue")
        XCTAssertNil(Layers.color(0, none: true))
        for id in Layers.shapeActions.keys { XCTAssertEqual(registry.control(id: id)?.layer, "shape", id) }
    }

    func testAddShapesMakesShapeLayers() {
        run("add ellipse")
        XCTAssertEqual(state.layers[0].kind, "shape")
        XCTAssertEqual(state.layers[0].shapeType, "ellipse")
        XCTAssertEqual(state.layers[0].values["shapeWidth"], 25)
        run("shape width 40 shape fill red")
        XCTAssertEqual(state.layers[0].values["shapeWidth"], 40)
        XCTAssertEqual(Layers.color(state.layers[0].values["shapeFill"]!, none: true), Layers.colors[2].rgb)
        run("add line line width 3")
        XCTAssertEqual(state.layers[1].shapeType, "line")
        XCTAssertEqual(state.layers[1].values["lineWidth"], 3)
        let box = Layers.box(of: state.layers[1])!
        XCTAssertEqual(box.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(box.height, 0.03, accuracy: 1e-9)
    }

    func testRegularPolygons() {
        let triangle = Layers.polygon(sides: 3, width: 2, height: 2)
        XCTAssertEqual(triangle.count, 3)
        XCTAssertEqual(triangle[0].x, 0, accuracy: 1e-12)
        XCTAssertEqual(triangle[0].y, -1, accuracy: 1e-12, "first corner at the top")
        XCTAssertGreaterThan(triangle[1].x, 0, "then clockwise: to the right")
        let square = Layers.polygon(sides: 4, width: 2, height: 1)
        XCTAssertEqual(square[1].x, 1, accuracy: 1e-12)
        XCTAssertEqual(square[2].y, 0.5, accuracy: 1e-12)
    }

    func testPenPathsByTapsAndDrags() {
        run("pen tool")
        XCTAssertEqual(state.layers[0].shapeType, "path")
        // Canvas 1000 × 500 (L = 1000), the layer's centre at 500, 250.
        XCTAssertTrue(state.penPoint(Vec2(400, 150), width: 1000, height: 500))
        XCTAssertTrue(state.penPoint(Vec2(600, 150), handleEnd: Vec2(650, 150), width: 1000, height: 500))
        XCTAssertTrue(state.penPoint(Vec2(600, 350), width: 1000, height: 500))
        XCTAssertEqual(state.layers[0].path[0].point, MaskPoint(-0.1, -0.1))
        XCTAssertEqual(state.layers[0].path[1].handle.x, 0.05, accuracy: 1e-9, "dragged out: a curve")
        XCTAssertEqual(state.layers[0].path[1].handle.y, 0, accuracy: 1e-9)
        XCTAssertEqual(run("pen tool"), [.ran(controlID: "penTool")], "the open path goes on")
        XCTAssertEqual(state.layers.count, 1)
        XCTAssertTrue(state.penPoint(Vec2(405, 152), width: 1000, height: 500), "on the first point: closes")
        XCTAssertTrue(state.layers[0].closed)
        XCTAssertEqual(state.layers[0].path.count, 3)
        XCTAssertFalse(state.penPoint(Vec2(500, 250), width: 1000, height: 500), "closed: no more points")
        let pieces = Layers.bezier(state.layers[0].path, closed: true)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces[0].2.x, 0.05, accuracy: 1e-9, "arrives from point − handle")
        XCTAssertEqual(pieces[0].2.y, -0.1, accuracy: 1e-9)
        XCTAssertEqual(Layers.point(on: pieces[0], at: 0), Vec2(-0.1, -0.1))
        XCTAssertEqual(Layers.point(on: pieces[0], at: 1), Vec2(0.1, -0.1))
        let box = Layers.box(of: state.layers[0])!
        XCTAssertEqual(box.x, -0.1, accuracy: 1e-9)
        XCTAssertEqual(box.maxY, 0.1, accuracy: 1e-9)
        run("pen tool")
        XCTAssertEqual(state.layers.count, 2, "a closed path done: a new one")
    }

    // MARK: - Layer styles

    func testStyleNames() {
        XCTAssertEqual(parse("drop shadow on"), [.set("dropShadow", 1)], "not “drop” (less) shadows")
        XCTAssertEqual(parse("drop shadow off"), [.set("dropShadow", 0)])
        XCTAssertEqual(parse("drop shadow"), [.set("dropShadow", 1)])
        XCTAssertEqual(parse("exposure drop"), [.nudge("exposure", -1)], "“drop” alone is still less")
        XCTAssertEqual(parse("outer glow"), [.set("outerGlow", 1)])
        XCTAssertEqual(parse("stroke 4"), [.set("layerStroke", 4)])
        XCTAssertEqual(parse("stroke off"), [.set("layerStroke", 0)])
        XCTAssertEqual(parse("stroke colour white"), [.set("strokeColor", 0)])
        XCTAssertEqual(parse("bevel and emboss"), [.set("bevel", 1)])
        XCTAssertEqual(parse("zoom blur off"), [.set("zoomBlur", 0)], "off turns off a slider that naming turns on")
        XCTAssertEqual(parse("stroke opacity 50"), [.set("spotOpacity", 50)], "still the retouch step's")
    }

    func testStylesGoToTheSelectedLayer() {
        run("new text layer Hi")
        run("stroke")
        XCTAssertEqual(state.layers[0].values["layerStroke"], 5, "naming it turns it on")
        run("stroke 12 drop shadow outer glow bevel")
        XCTAssertEqual(state.layers[0].values["layerStroke"], 12)
        XCTAssertEqual(state.layers[0].values["dropShadow"], 1)
        XCTAssertEqual(state.layers[0].values["outerGlow"], 1)
        XCTAssertEqual(state.layers[0].values["bevel"], 1)
        run("stroke off")
        XCTAssertEqual(state.layers[0].values["layerStroke"], 0)
        XCTAssertEqual(Layers.color(state.layers[0].values["strokeColor"]!), Layers.colors[1].rgb, "black by default")
    }

    // MARK: - Paint brush

    func testPaintBrushNamesAndLayers() {
        XCTAssertEqual(parse("paint brush"), [.run("paintBrush")])
        XCTAssertEqual(parse("brush colour blue"), [.set("brushColor", 6)], "not the mask brush")
        XCTAssertEqual(parse("brush size 20"), [.set("brushSize", 20)], "still the mask brush's size")
        XCTAssertEqual(parse("paint size 3"), [.set("paintSize", 3)])
        run("paint brush")
        XCTAssertEqual(state.layers.map(\.kind), ["paint"])
        run("paint brush")
        XCTAssertEqual(state.layers.count, 1, "painting goes on on the selected paint layer")
        run("brush colour blue paint size 2")
        XCTAssertEqual(state.layers[0].values["brushColor"], nil, "brush settings are for new strokes, not the layer's")
        // Canvas 1000 × 500: points in pixels become L units around the layer's centre.
        XCTAssertTrue(state.addPaintStroke([Vec2(500, 250), Vec2(600, 250)], pressure: [1, 0.5], tilt: [0, 1], size: 2, color: 7,
                                           width: 1000, height: 500))
        let stroke = state.layers[0].strokes[0]
        XCTAssertEqual(stroke.points, [MaskPoint(0, 0), MaskPoint(0.1, 0)])
        XCTAssertEqual(stroke.width(at: 0), 0.02, accuracy: 1e-12, "full pressure, upright: the brush size")
        XCTAssertEqual(stroke.width(at: 1), 0.02 * 0.65 * 3, accuracy: 1e-12, "half pressure, lying flat")
        XCTAssertEqual(PaintStroke(points: [MaskPoint(0, 0)], size: 2).width(at: 0), 0.02, accuracy: 1e-12, "fingers: full and upright")
        let box = Layers.box(of: state.layers[0])!
        XCTAssertEqual(box.maxX, 0.1 + 0.0195, accuracy: 1e-9)
        state.layers.append(Layers.make("text", registry: registry))
        state.selectLayer(1)
        XCTAssertFalse(state.addPaintStroke([Vec2(1, 1)], size: 2, color: 2, width: 10, height: 10), "only on a paint layer")
    }

    // MARK: - Gradient and fill

    func testFillLayers() {
        XCTAssertEqual(parse("gradient fill"), [.run("gradientFill")])
        XCTAssertEqual(parse("gradient fill radial"), [.run("gradientFill", value: 1)])
        XCTAssertEqual(parse("fill colour red"), [.set("fillColor", 2)])
        XCTAssertEqual(parse("fill end colour transparent"), [.set("fillEndColor", 0)])
        XCTAssertEqual(parse("fill angle 0"), [.set("fillAngle", 0)])
        XCTAssertEqual(parse("fill edges on"), [.set("fillEdges", 1)], "still the panorama's")
        run("gradient fill radial")
        XCTAssertEqual(state.layers[0].kind, "fill")
        XCTAssertEqual(Layers.fillStyles[Int(state.layers[0].values["fillStyle"]!)], "radial")
        XCTAssertNil(Layers.box(of: state.layers[0]), "covers the whole canvas")
        run("solid fill fill colour white")
        XCTAssertEqual(Layers.fillStyles[Int(state.layers[1].values["fillStyle"]!)], "solid")
        XCTAssertEqual(Layers.color(state.layers[1].values["fillColor"]!), RGB(1, 1, 1))
        XCTAssertNil(Layers.color(state.layers[1].values["fillEndColor"]!, none: true), "fades to transparent")
    }

    func testFillGeometry() {
        var layer = Layers.make("fill", registry: registry)
        // Default: from the bottom (start colour) up to the top, across the whole 1000 × 500 canvas.
        var ends = Layers.linearFill(layer, width: 1000, height: 500)
        XCTAssertEqual(ends.start.x, 500, accuracy: 1e-9)
        XCTAssertEqual(ends.start.y, 500, accuracy: 1e-9)
        XCTAssertEqual(ends.end.y, 0, accuracy: 1e-9)
        layer.values["fillAngle"] = 0
        layer.values["layerScale"] = 50
        ends = Layers.linearFill(layer, width: 1000, height: 500)
        XCTAssertEqual(ends.start.x, 250, accuracy: 1e-9, "left to right, half as long at scale 50")
        XCTAssertEqual(ends.end.x, 750, accuracy: 1e-9)
        let radial = Layers.radialFill(Layers.make("fill", registry: registry), width: 300, height: 400)
        XCTAssertEqual(radial.centre, Vec2(150, 200))
        XCTAssertEqual(radial.radius, 250, accuracy: 1e-9, "half the diagonal")
    }

    // MARK: - Stickers

    func testStickers() {
        XCTAssertEqual(registry.control(id: "addSticker")!.options.map(\.id), Stickers.ids)
        XCTAssertEqual(parse("sticker heart"), [.run("addSticker", value: 0)])
        XCTAssertEqual(parse("add sticker speech bubble"), [.run("addSticker", value: 9)])
        run("sticker smiley")
        XCTAssertEqual(state.layers[0].kind, "sticker")
        XCTAssertEqual(state.layers[0].values["sticker"], 2)
        XCTAssertEqual(Layers.size(of: state.layers[0])?.width, Stickers.side)
        for id in Stickers.ids {
            let parts = Stickers.parts(id)
            XCTAssertFalse(parts.isEmpty, id)
            for part in parts {
                let points: [Vec2]
                switch part.shape {
                case .polygon(let p), .line(let p, _): points = p
                case .ellipse(let c, let rx, let ry): points = [Vec2(c.x - rx, c.y - ry), Vec2(c.x + rx, c.y + ry)]
                }
                for p in points {
                    XCTAssertTrue(abs(p.x) <= 0.5 + 1e-9 && abs(p.y) <= 0.5 + 1e-9, "\(id) leaves its box at \(p)")
                }
            }
        }
        guard case .polygon(let heart) = Stickers.parts("heart")[0].shape else { return XCTFail("heart") }
        XCTAssertTrue(Stickers.inside(Vec2(0, 0), heart), "the heart's middle is inside it")
        XCTAssertFalse(Stickers.inside(Vec2(0, -0.3), heart), "the dip between its lobes is not")
        XCTAssertEqual(Stickers.star(points: 5, outer: 0.5, inner: 0.2).count, 10)
    }

    // MARK: - Collage

    func testCollageNames() {
        XCTAssertEqual(parse("collage 2 by 2"), [.run("collage", value: 0)])
        XCTAssertEqual(parse("collage 3 by 1"), [.run("collage", value: 3)])
        XCTAssertEqual(parse("collage side by side"), [.run("collage", value: 1)])
        XCTAssertEqual(parse("collage layout 1 by 2"), [.set("collageLayout", 2)])
        XCTAssertEqual(parse("collage spacing 4"), [.set("collageSpacing", 4)])
        XCTAssertEqual(parse("collage background black"), [.set("collageBackground", 1)])
        XCTAssertEqual(registry.control(id: "collageLayout")!.options.map(\.id), Collage.layouts)
        XCTAssertEqual(registry.control(id: "collage")!.options.map(\.id), Collage.layouts)
        XCTAssertEqual(run("collage 3 by 2"), [.ran(controlID: "collage"), .changed(controlID: "collageLayout", from: 0, to: 5)],
                       "the app makes the collage from the photos picked, as a merge")
        XCTAssertEqual(MergeTools.actions["collage"], "collage")
        XCTAssertTrue(MergeTools.settings(for: "collage").contains("collageSpacing"), "a new spacing makes it again")
    }

    func testCollageGrids() {
        // Two portrait photos side by side, long side 1600, 2 % spacing (32 px).
        let side = Collage.layout("2x1", aspect: 2.0 / 3, spacing: 2, long: 1600)
        XCTAssertEqual(side.width, 1600)
        XCTAssertEqual(side.cells.count, 2)
        XCTAssertEqual(side.cells[0], GeoRect(x: 32, y: 32, width: 752, height: 1128))
        XCTAssertEqual(side.cells[1].x, 32 + 752 + 32)
        XCTAssertEqual(side.height, 1128 + 64)
        // Stacked: the height is the long side.
        let stacked = Collage.layout("1x2", aspect: 1.5, spacing: 0, long: 1200)
        XCTAssertEqual(stacked.height, 1200)
        XCTAssertEqual(stacked.cells[1].y, 600)
        XCTAssertLessThanOrEqual(stacked.width, 1200)
        // Every cell inside the canvas, none overlapping, row by row.
        let nine = Collage.layout("3x3", aspect: 1, spacing: 3, long: 3000)
        XCTAssertEqual(nine.cells.count, 9)
        for cell in nine.cells {
            XCTAssertTrue(cell.x >= 0 && cell.maxX <= nine.width && cell.y >= 0 && cell.maxY <= nine.height)
        }
        XCTAssertLessThan(nine.cells[0].maxX, nine.cells[1].x)
        XCTAssertLessThan(nine.cells[2].maxY, nine.cells[3].y)
        // A wide photo in a square cell: its middle.
        let part = Collage.fill(width: 400, height: 200, cell: GeoRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(part, GeoRect(x: 100, y: 0, width: 200, height: 200))
        let tall = Collage.fill(width: 200, height: 400, cell: GeoRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(tall, GeoRect(x: 0, y: 150, width: 200, height: 100))
    }

    // MARK: - Watermark

    func testWatermarkNames() {
        XCTAssertEqual(parse("watermark text © Rajiv 2026"), [.run("watermarkText", text: "© Rajiv 2026")])
        XCTAssertEqual(parse("watermark text “Draft” watermark opacity 30"), [.run("watermarkText", text: "Draft"), .set("watermarkOpacity", 30)])
        XCTAssertEqual(parse("watermark opacity 30"), [.set("watermarkOpacity", 30)], "a longer name takes no words")
        XCTAssertEqual(parse("watermark logo"), [.set("watermark", 2)])
        XCTAssertEqual(parse("watermark off"), [.set("watermark", 0)])
        XCTAssertEqual(parse("watermark position top left"), [.set("watermarkPosition", 3)])
        XCTAssertEqual(parse("watermark size 8"), [.set("watermarkSize", 8)])
        XCTAssertEqual(registry.control(id: "watermark")!.options.map(\.id), Watermark.styles)
        XCTAssertEqual(registry.control(id: "watermarkPosition")!.options.map(\.id), Watermark.positions)
    }

    func testWatermarkTextSwitchesItOn() {
        XCTAssertEqual(run("watermark text Proof"), [.ran(controlID: "watermarkText"), .changed(controlID: "watermark", from: 0, to: 1)])
        XCTAssertEqual(state.watermarkText, "Proof")
        run("watermark off")
        XCTAssertEqual(state.watermarkText, "Proof", "off keeps the words for later")
        run("reset all")
        XCTAssertEqual(state.watermarkText, "")
    }

    func testWatermarkPlaces() {
        // 1000 × 500 picture, margin 30 px, a 200 × 40 stamp.
        func at(_ position: String) -> Vec2 {
            Watermark.origin(position, width: 200, height: 40, canvasWidth: 1000, canvasHeight: 500)
        }
        XCTAssertEqual(at("bottomRight"), Vec2(770, 430))
        XCTAssertEqual(at("topLeft"), Vec2(30, 30))
        XCTAssertEqual(at("center"), Vec2(400, 230))
        XCTAssertEqual(at("bottom"), Vec2(400, 430))
    }
}
