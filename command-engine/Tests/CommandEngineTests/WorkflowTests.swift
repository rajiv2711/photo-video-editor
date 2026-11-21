import XCTest
@testable import CommandEngine

/// Presets & batch and History & viewing: presets (saving, applying, Amount, Include switches,
/// finding by name), and later copy/paste, previous, history, snapshots, copies and the view maths.
final class WorkflowTests: XCTestCase {
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

    private func events(_ outcomes: [CommandOutcome]) -> [WorkflowEvent] {
        outcomes.compactMap { if case .workflow(let e) = $0 { return e } else { return nil } }
    }

    // MARK: - Presets: names

    func testPresetNamesReachTheirControls() {
        XCTAssertEqual(parse("preset portrait warm"), [.run("applyPreset", text: "portrait warm")])
        XCTAssertEqual(parse("save preset portrait warm"), [.run("savePreset", text: "portrait warm")])
        XCTAssertEqual(parse("preset amount 50"), [.set("presetAmount", 50)])
        XCTAssertEqual(parse("preset strength more"), [.nudge("presetAmount", 1)])
        XCTAssertEqual(parse("rename preset warm to cosy"), [.run("renamePreset", text: "warm to cosy")])
        XCTAssertEqual(parse("delete preset cosy"), [.run("deletePreset", text: "cosy")])
        XCTAssertEqual(parse("include light off"), [.set("includeLight", 0)])
        XCTAssertEqual(parse("include masks"), [.set("includeMasks", 1)])
        XCTAssertEqual(parse("include colour off include crop on"), [.set("includeColor", 0), .set("includeGeometry", 1)])
        // Quotes keep the rest of what was said as commands.
        XCTAssertEqual(parse("save preset \"warm\" reset all"), [.run("savePreset", text: "warm"), .resetAll])
    }

    func testIncludeSwitchesCoverEveryEditingPanel() {
        for item in Presets.includes {
            let control = registry.control(id: item.id)
            XCTAssertEqual(control?.kind, .toggle, item.id)
            XCTAssertFalse(registry.controls(inGroup: item.group).isEmpty, item.group)
        }
        // The look of a photo is on by default; crop, masks, spots and layers belong to one photo.
        XCTAssertEqual(Presets.included(EditState(), registry: registry), ["light", "color", "effects", "detail", "optics", "creative"])
    }

    // MARK: - Presets: saving and applying

    func testSavedPresetPutsTheSettingsBack() {
        run("exposure 1 contrast 40 temperature 30 sharpening 60")
        let saved = state!
        run("save preset \"warm look\" reset all")
        XCTAssertEqual(value("exposure"), 0)
        let outcomes = run("preset warm look")
        XCTAssertEqual(state.normalized(registry), saved.normalized(registry))
        XCTAssertEqual(events(outcomes), [.presetApplied(name: "warm look", amount: 100, changes: 4)])
        XCTAssertEqual(interpreter.workspace.presets.map(\.name), ["warm look"])
    }

    func testAmountScalesSlidersFromTheirDefaults() {
        run("exposure 1 contrast 40 vignette midpoint 30 shadows hue 200 shadows saturation 40 black and white")
        // The words after a preset's name are commands again.
        run("save preset \"look\" reset all preset look preset amount 50")
        XCTAssertEqual(value("exposure"), 0.5)
        XCTAssertEqual(value("contrast"), 20)
        XCTAssertEqual(value("vignetteMidpoint"), 40)  // its default is 50
        XCTAssertEqual(value("gradingShadowsSaturation"), 20)
        XCTAssertEqual(value("gradingShadowsHue"), 200)  // a direction, not an amount
        XCTAssertEqual(value("bw"), 1)  // switches stay as saved
        run("preset amount 200")
        XCTAssertEqual(value("exposure"), 2)
        XCTAssertEqual(value("contrast"), 80)
        run("preset amount 0")
        XCTAssertEqual(value("exposure"), 0)
        XCTAssertEqual(value("bw"), 0)
    }

    func testApplyingResetsTheIncludedPanels() {
        run("contrast 30 save preset \"flat\" reset all exposure 2 highlights -50")
        run("preset flat")
        // The preset's light panel had exposure and highlights at 0.
        XCTAssertEqual(value("exposure"), 0)
        XCTAssertEqual(value("highlights"), 0)
        XCTAssertEqual(value("contrast"), 30)
    }

    func testIncludeSwitchesChooseThePanels() {
        run("exposure 1 temperature 40 include light off save preset \"colour only\" reset all")
        XCTAssertEqual(value("includeLight"), 0, "reset all leaves the Include switches")
        run("exposure -1 preset colour only")
        XCTAssertEqual(value("temperature"), 40)
        XCTAssertEqual(value("exposure"), -1, "the light panel wasn't saved")
    }

    func testMasksAndLayersComeAlongWhenIncluded() {
        run("linear gradient from top exposure -1 done add rectangle done include masks include layers save preset \"local\"")
        let masks = state.masks, layers = state.layers
        state = EditState()
        run("include masks include layers preset local")
        XCTAssertEqual(state.masks, masks)
        XCTAssertEqual(state.layers, layers)
        XCTAssertNil(state.selectedMask)
    }

    func testCommandsAfterAPresetGoOnTop() {
        run("exposure 1 save preset \"bright\" reset all")
        run("preset bright exposure 0.3")
        XCTAssertEqual(value("exposure"), 0.3)
        XCTAssertEqual(value("presetAmount"), 100)
    }

    func testRenameAndDelete() {
        interpreter.workspace = Workspace(registry: registry, packs: [])
        run("exposure 1 save preset \"warm\"")
        var outcomes = run("rename preset warm to cosy")
        XCTAssertEqual(events(outcomes), [.presetRenamed(from: "warm", to: "cosy")])
        outcomes = run("delete preset warm")
        XCTAssertEqual(events(outcomes), [.noPreset("warm")])
        outcomes = run("delete preset cosy")
        XCTAssertEqual(events(outcomes), [.presetDeleted("cosy")])
        XCTAssertTrue(interpreter.workspace.presets.isEmpty)
        // Saving under an existing name replaces it.
        run("save preset \"a\" exposure 2 save preset \"A\"")
        XCTAssertEqual(interpreter.workspace.presets.count, 1)
        XCTAssertEqual(interpreter.workspace.presets[0].values["exposure"], 2)
    }

    func testFindingPresetsByName() {
        let presets = [Preset(name: "Portra"), Preset(name: "Portrait Glow", pack: "Portrait"), Preset(name: "Noir", pack: "Black & White")]
        XCTAssertEqual(Presets.find("portra", in: presets), .found(0))
        XCTAssertEqual(Presets.find("NOIR!", in: presets), .found(2))
        XCTAssertEqual(Presets.find("black and white noir", in: presets), .found(2))
        XCTAssertEqual(Presets.find("portrait glo", in: presets), .found(1))
        XCTAssertEqual(Presets.find("port", in: presets), .ambiguous([0, 1]))
        XCTAssertEqual(Presets.find("velvia", in: presets), .none)
    }

    func testBuiltInPresetsCantBeRenamedOrDeleted() {
        interpreter.workspace = Workspace(registry: registry, packs: [Preset(name: "Noir", pack: "Black & White", groups: ["look"],
                                                                                values: ["bw": 1, "contrast": 30])])
        XCTAssertEqual(events(run("delete preset noir")), [.builtInPreset("Noir")])
        XCTAssertEqual(events(run("rename preset noir to dark")), [.builtInPreset("Noir")])
        run("exposure 1 temperature 20 vibrance 30 preset noir")
        // A built-in look leaves exposure and white balance, and puts the rest of the look back.
        XCTAssertEqual(value("exposure"), 1)
        XCTAssertEqual(value("temperature"), 20)
        XCTAssertEqual(value("vibrance"), 0)
        XCTAssertEqual(value("bw"), 1)
    }

    // MARK: - Built-in packs

    func testBuiltInPacksAreWellFormed() {
        let packs = Presets.bundled()
        XCTAssertGreaterThanOrEqual(packs.count, 30)
        XCTAssertEqual(Set(packs.compactMap(\.pack)), ["Film", "Portrait", "Travel", "Landscape", "Black & White", "Cinematic", "Vintage"])
        XCTAssertEqual(Set(packs.map { Presets.normalized($0.name) }).count, packs.count, "names are unique")
        for preset in packs {
            XCTAssertEqual(preset.groups, ["look"], preset.name)
            XCTAssertFalse(preset.values.isEmpty, preset.name)
            for (id, v) in preset.values {
                guard let control = registry.control(id: id) else { return XCTFail("\(preset.name): no control \(id)") }
                // A look: never exposure, white balance or anything outside the colour treatment, curves and effects.
                XCTAssertTrue(Presets.isLook(control), "\(preset.name): \(id) is not part of the look")
                XCTAssertEqual(control.clamp(v), v, "\(preset.name): \(id) \(v) is out of range")
            }
        }
    }

    func testBuiltInPresetsApplyByName() {
        run("exposure 0.5 temperature 20 preset noir")
        XCTAssertEqual(value("bw"), 1)
        XCTAssertEqual(value("exposure"), 0.5)
        XCTAssertEqual(value("temperature"), 20)
        // Another built-in look replaces it instead of piling up.
        run("preset golden hour")
        XCTAssertEqual(value("bw"), 0)
        XCTAssertEqual(value("vignette"), -15)
        XCTAssertGreaterThan(value("gradingHighlightsSaturation"), 0)
        // Its pack and name, and a near-miss.
        guard case .presetApplied(let name, _, _)? = events(run("preset black and white noir")).first else { return XCTFail("not applied") }
        XCTAssertEqual(name, "Noir")
        run("preset sepa")
        XCTAssertEqual(value("toning"), 1)
    }

    func testNoPresetSaysSo() {
        XCTAssertEqual(events(run("preset nothing like this")), [.noPreset("nothing like this")])
        XCTAssertEqual(value("exposure"), 0)
    }
}
