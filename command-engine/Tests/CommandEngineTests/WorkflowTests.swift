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

    // MARK: - Copy / paste

    func testCopyAndPasteTakeTheIncludedPanels() {
        XCTAssertEqual(parse("copy settings"), [.run("copySettings")])
        XCTAssertEqual(parse("paste"), [.run("pasteSettings")])
        XCTAssertEqual(events(run("paste settings")), [.nothingCopied])
        run("exposure 1 temperature 30 crop left 20 include light off")
        XCTAssertEqual(events(run("copy settings")), [.copied(["color", "effects", "detail", "optics", "creative"])])
        state = EditState()
        run("exposure -1 paste settings")
        XCTAssertEqual(value("temperature"), 30)
        XCTAssertEqual(value("exposure"), -1, "light wasn't copied")
        XCTAssertEqual(value("cropLeft"), 0, "the crop belongs to its own photo unless included")
    }

    // MARK: - Previous

    func testPreviousAppliesTheLastPhotosEdit() {
        XCTAssertEqual(parse("previous"), [.run("previousSettings")])
        XCTAssertEqual(parse("paste previous"), [.run("previousSettings")])
        XCTAssertEqual(events(run("previous")), [.noPrevious])
        run("exposure 1 temperature 30 crop left 20")
        interpreter.workspace.closePhoto(state)
        state = EditState()
        run("previous")
        XCTAssertEqual(value("exposure"), 1)
        XCTAssertEqual(value("temperature"), 30)
        XCTAssertEqual(value("cropLeft"), 0, "the crop is only taken when Include Geometry is on")
        run("include geometry previous")
        XCTAssertEqual(value("cropLeft"), 20)
    }

    // MARK: - Undo / redo

    func testUndoAndRedoStepThroughTheEdit() {
        XCTAssertEqual(parse("undo"), [.run("undo")])
        XCTAssertEqual(parse("undo 3"), [.run("undo", value: 3)])
        XCTAssertEqual(parse("redo 2"), [.run("redo", value: 2)])
        XCTAssertEqual(parse("undo last spot"), [.run("undoSpot")])
        XCTAssertEqual(events(run("undo")), [.nothingToUndo])
        run("exposure 1")
        run("contrast 20")
        run("linear gradient from top exposure -1 done")
        XCTAssertEqual(interpreter.workspace.history.steps.map(\.label),
                       ["Opened", "exposure 1", "contrast 20", "linear gradient from top exposure -1 done"])
        XCTAssertEqual(events(run("undo")), [.undone(["linear gradient from top exposure -1 done"])])
        XCTAssertTrue(state.masks.isEmpty)
        XCTAssertEqual(value("contrast"), 20)
        run("undo 5")
        XCTAssertEqual(value("exposure"), 0)
        XCTAssertEqual(events(run("redo 2")), [.redone(["exposure 1", "contrast 20"])])
        XCTAssertEqual(value("exposure"), 1)
        XCTAssertEqual(value("contrast"), 20)
        // A new change drops what was undone.
        run("vibrance 30")
        XCTAssertEqual(events(run("redo")), [.nothingToRedo])
        XCTAssertEqual(interpreter.workspace.history.steps.count, 4)
    }

    func testChangesSaidBeforeUndoAreAStepOfTheirOwn() {
        run("exposure 1 undo")
        XCTAssertEqual(value("exposure"), 0)
        run("redo")
        XCTAssertEqual(value("exposure"), 1)
    }

    func testViewSettingsAndSelectionAreNotSteps() {
        run("exposure 1 linear gradient from top done")
        let steps = interpreter.workspace.history.steps.count
        run("include light off")
        run("mask 1")
        run("done")
        XCTAssertEqual(interpreter.workspace.history.steps.count, steps)
        run("undo")
        XCTAssertEqual(value("includeLight"), 0, "the Include switches stay as they are")
        XCTAssertEqual(value("exposure"), 0)
    }

    func testTouchRecordsMergeWhileDragging() {
        let exposure = registry.control(id: "exposure")!
        for v in stride(from: 0.1, through: 1.0, by: 0.1) {
            state.set(exposure, to: v)
            interpreter.record(state, label: "Exposure \(v)", key: "slider:exposure")
        }
        XCTAssertEqual(interpreter.workspace.history.steps.count, 2, "one drag, one step")
        interpreter.workspace.history.seal()
        state.set(exposure, to: 2)
        interpreter.record(state, label: "Exposure 2", key: "slider:exposure")
        XCTAssertEqual(interpreter.workspace.history.steps.count, 3, "a second drag is a step of its own")
        run("undo")
        XCTAssertEqual(value("exposure"), 1)
    }

    func testHistoryJumpsToAnyStep() {
        XCTAssertEqual(parse("history 12"), [.run("history", value: 12)])
        XCTAssertEqual(parse("jump to step 4"), [.run("history", value: 4)])
        run("exposure 1")
        run("contrast 20")
        run("temperature 30")
        XCTAssertEqual(events(run("history")), [.historyShown(steps: 3)])
        XCTAssertEqual(events(run("history 1")), [.historyJumped(step: 1, label: "exposure 1")])
        XCTAssertEqual(value("contrast"), 0)
        XCTAssertEqual(value("exposure"), 1)
        run("history 3")
        XCTAssertEqual(value("temperature"), 30)
        run("history 0")
        XCTAssertEqual(state.normalized(registry), EditState().normalized(registry))
        XCTAssertEqual(events(run("history 9")), [.noHistoryStep(9)])
        XCTAssertEqual(interpreter.workspace.history.position, 0)
    }

    func testHistoryKeepsAtMostItsLimit() {
        var history = EditHistory(registry: registry)
        let exposure = registry.control(id: "exposure")!
        for i in 1...(EditHistory.limit + 20) {
            var s = EditState()
            s.set(exposure, to: Double(i % 30) / 10 + 0.05)
            history.record(s, label: "\(i)")
        }
        XCTAssertEqual(history.steps.count, EditHistory.limit)
        XCTAssertEqual(history.steps[0].label, "Opened", "the photo as opened is always kept")
    }

    // MARK: - Snapshots

    func testSnapshotsSaveAndRestoreNamedStates() {
        XCTAssertEqual(parse("snapshot before crop"), [.run("saveSnapshot", text: "before crop")])
        XCTAssertEqual(parse("restore snapshot before crop"), [.run("restoreSnapshot", text: "before crop")])
        XCTAssertEqual(parse("version 2"), [.run("restoreSnapshot", text: "2")])
        XCTAssertEqual(parse("delete snapshot warm"), [.run("deleteSnapshot", text: "warm")])
        run("exposure 1 linear gradient from top exposure -1 done")
        let saved = state!
        XCTAssertEqual(events(run("snapshot before crop")), [.snapshotSaved("before crop")])
        run("crop left 30 contrast 40")
        // The words after a snapshot's name are commands again.
        XCTAssertEqual(events(run("restore snapshot before crop vibrance 20")), [.snapshotRestored("before crop")])
        XCTAssertEqual(value("cropLeft"), 0)
        XCTAssertEqual(value("vibrance"), 20)
        XCTAssertEqual(state.masks, saved.masks)
        // Restoring is a step: undo goes back to the crop.
        run("undo")
        XCTAssertEqual(value("cropLeft"), 30)
        run("snapshot")  // no name: numbered
        XCTAssertEqual(interpreter.workspace.snapshots.map(\.name), ["before crop", "Snapshot 2"])
        run("version 1")
        XCTAssertEqual(value("cropLeft"), 0)
        XCTAssertEqual(events(run("delete snapshot before crop")), [.snapshotDeleted("before crop")])
        XCTAssertEqual(events(run("restore snapshot before crop")), [.noSnapshot("before crop")])
    }

    // MARK: - Virtual copies

    func testVirtualCopiesAreSeparateEditsWithTheirOwnHistory() {
        XCTAssertEqual(parse("virtual copy black and white"), [.run("virtualCopy", text: "black and white")])
        XCTAssertEqual(parse("go to copy original"), [.run("switchCopy", text: "original")])
        XCTAssertEqual(parse("switch to copy 2"), [.run("switchCopy", text: "2")])
        XCTAssertEqual(parse("delete copy mono"), [.run("deleteCopy", text: "mono")])
        XCTAssertEqual(parse("copy"), [.run("copySettings")], "“copy” alone copies the settings")
        run("exposure 1")
        XCTAssertEqual(events(run("virtual copy mono")), [.copyMade("mono")])
        XCTAssertEqual(value("exposure"), 1, "a copy starts from the edit it was made from")
        run("black and white")
        XCTAssertEqual(events(run("undo")), [.undone(["black and white"])])
        XCTAssertEqual(events(run("undo")), [.nothingToUndo], "the copy has a history of its own")
        run("redo")
        XCTAssertEqual(events(run("go to copy original")), [.copySwitched("Original")])
        XCTAssertEqual(value("bw"), 0)
        XCTAssertEqual(value("exposure"), 1)
        run("undo")
        XCTAssertEqual(value("exposure"), 0, "the original's history is back")
        run("redo switch to copy 2 contrast 20")
        XCTAssertEqual(value("bw"), 1)
        XCTAssertEqual(value("contrast"), 20)
        XCTAssertEqual(interpreter.workspace.copyNames, ["Original", "mono"])
        // Deleting the copy being edited goes back to the one before it.
        XCTAssertEqual(events(run("delete copy mono")), [.copyDeleted("mono")])
        XCTAssertEqual(value("bw"), 0)
        XCTAssertEqual(interpreter.workspace.copyNames, ["Original"])
        XCTAssertEqual(events(run("delete copy original")), [.noCopy("original")])
    }

    // MARK: - Before / after

    func testBeforeAndAfterNames() {
        XCTAssertEqual(parse("before"), [.set("showBefore", 1)])
        XCTAssertEqual(parse("before off"), [.set("showBefore", 0)])
        XCTAssertEqual(parse("compare split"), [.set("compare", 1)])
        XCTAssertEqual(parse("compare side by side"), [.set("compare", 2)])
        XCTAssertEqual(parse("before and after"), [.select("compare")])
        XCTAssertEqual(parse("compare off"), [.set("compare", 0)])
        XCTAssertEqual(CompareLayout.modes, registry.control(id: "compare")!.options.map(\.id))
        run("compare")
        XCTAssertEqual(value("compare"), 1, "“compare” alone shows the split")
        // The view is not part of the edit: reset all and undo leave it.
        run("exposure 1")
        run("reset all")
        XCTAssertEqual(value("compare"), 1)
        XCTAssertEqual(interpreter.workspace.history.steps.count, 3)
    }

    func testCompareLayouts() {
        // Split: the photo before (uncropped, wider) fitted into the edited frame.
        let split = CompareLayout.place(mode: "split", before: (800, 600), after: (400, 600))
        XCTAssertEqual(split.before, ViewRect(0, 150, 400, 300))
        XCTAssertEqual(split.after, ViewRect(0, 0, 400, 600))
        XCTAssertEqual(split.divider, 200)
        // Side by side: the one before at the edited one's height, a gap, then the edited one.
        let side = CompareLayout.place(mode: "sideBySide", before: (800, 600), after: (800, 600))
        XCTAssertEqual(side.before, ViewRect(0, 0, 800, 600))
        XCTAssertEqual(side.after, ViewRect(816, 0, 800, 600))
        XCTAssertEqual(side.size.width, 1616)
        XCTAssertEqual(side.size.height, 600)
        XCTAssertNil(side.divider)
    }

    // MARK: - Reset

    func testResetAPanel() {
        XCTAssertEqual(parse("reset light panel"), [.run("resetPanel", value: 0)])
        XCTAssertEqual(parse("reset the colour panel"), [.run("resetPanel", value: 1)])
        XCTAssertEqual(parse("reset effects"), [.run("resetPanel", value: 2)])
        XCTAssertEqual(parse("reset geometry"), [.run("resetPanel", value: 5)])
        XCTAssertEqual(parse("reset panel optics"), [.run("resetPanel", value: 4)])
        XCTAssertEqual(parse("contrast 20 reset creative"), [.set("contrast", 20), .run("resetPanel", value: 6)])
        XCTAssertEqual(parse("reset light"), [.run("resetPanel", value: 0)])
        XCTAssertEqual(parse("reset colour"), [.run("resetPanel", value: 1)])
        // A panel's word that is also a control's own name needs "panel" ("lights" is the Lights curve).
        XCTAssertEqual(parse("reset lights"), [.reset("curveLights")])
        XCTAssertEqual(parse("reset crop"), [.run("resetCrop")])
        XCTAssertEqual(parse("reset contrast"), [.reset("contrast")])
        XCTAssertEqual(parse("reset all"), [.resetAll])

        run("exposure 1 temperature 30 clarity 40 crop left 20 linear gradient from top exposure -1 done")
        run("reset light panel")
        XCTAssertEqual(value("exposure"), 0)
        XCTAssertEqual(value("temperature"), 30)
        XCTAssertEqual(state.masks.count, 1)
        run("reset masks panel")
        XCTAssertTrue(state.masks.isEmpty)
        // Without a panel named: the panel of the control used last.
        run("clarity 50 reset panel")
        XCTAssertEqual(value("clarity"), 0)
        XCTAssertEqual(value("cropLeft"), 20)
        run("reset geometry")
        XCTAssertEqual(value("cropLeft"), 0)
        XCTAssertEqual(value("temperature"), 30)
    }

    // MARK: - Panels

    func testPanelsByName() {
        // An option of Show Panel with "panel" or "tab" after it, or after "show" / "open".
        XCTAssertEqual(parse("light panel"), [.run("showPanel", value: 1)])
        XCTAssertEqual(parse("show layers"), [.run("showPanel", value: 11)])
        XCTAssertEqual(parse("open export"), [.run("showPanel", value: 15)])
        XCTAssertEqual(parse("open the colour panel"), [.run("showPanel", value: 2)])
        XCTAssertEqual(parse("go to the masks tab"), [.run("showPanel", value: 6)])
        XCTAssertEqual(parse("show panel creative filters"), [.run("showPanel", value: 10)])
        XCTAssertEqual(parse("lens corrections panel"), [.run("showPanel", value: 5)])
        XCTAssertEqual(parse("show history panel"), [.run("showPanel", value: 13)])
        XCTAssertEqual(parse("contrast 20 color panel exposure 0.5"),
                       [.set("contrast", 20), .run("showPanel", value: 2), .set("exposure", 0.5)])
        XCTAssertEqual(parse("panel"), [.run("showPanel")])
        // Names that start the same way keep their meaning.
        XCTAssertEqual(parse("show history"), [.run("history")])
        XCTAssertEqual(parse("show library"), [.run("browseLibrary")])
        XCTAssertEqual(parse("show layer"), [.set("layerVisible", 1)])
        XCTAssertEqual(parse("show mask overlay"), [.set("maskOverlay", 1)])
        XCTAssertEqual(parse("show color range"), [.run("colorRange")])
        XCTAssertEqual(parse("show spots"), [.set("visualizeSpots", 1)])
        XCTAssertEqual(parse("export"), [.run("export")])
        XCTAssertEqual(parse("include light panel"), [.set("includeLight", 1)])
        XCTAssertEqual(parse("reset light panel"), [.run("resetPanel", value: 0)])
        XCTAssertEqual(parse("panel reset"), [.run("resetPanel")])

        // Every panel the app shows has an option, each with a name of its own.
        let options = registry.control(id: "showPanel")!.options
        XCTAssertEqual(options.map(\.id), ["library", "light", "color", "effects", "detail", "optics", "masks", "retouch", "geometry",
                                           "merge", "creative", "layers", "presets", "history", "view", "export"])
        for (i, option) in options.enumerated() {
            XCTAssertEqual(parse(option.label.lowercased() + " panel"), [.run("showPanel", value: Double(i))], option.label)
            XCTAssertEqual(parse("open " + option.label.lowercased()), [.run("showPanel", value: Double(i))], option.label)
        }

        // The app is told which panel; the edit and its history don't change.
        run("exposure 1")
        let steps = interpreter.workspace.history.steps.count
        XCTAssertEqual(events(run("layers panel")), [.panelShown("layers")])
        XCTAssertEqual(events(run("panel")), [.panelShown(nil)])
        XCTAssertEqual(interpreter.workspace.history.steps.count, steps)
        XCTAssertEqual(value("exposure"), 1)
        XCTAssertEqual(run("undo").first, .ran(controlID: "undo"))
        XCTAssertEqual(value("exposure"), 0, "undo skips the panels shown")
    }

    // MARK: - Scopes

    func testHistogramBinsTheShownLevels() {
        XCTAssertEqual(parse("histogram"), [.set("histogram", 1)])
        XCTAssertEqual(parse("show histogram"), [.set("histogram", 1)])
        XCTAssertEqual(parse("histogram off"), [.set("histogram", 0)])
        XCTAssertEqual(parse("histogram equalize"), [.set("equalize", 1)], "the Light panel's Equalize keeps its name")
        // Black, white, pure red, mid grey, and a see-through pixel that doesn't count.
        let pixels: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 255, 128, 128, 128, 255, 200, 200, 200, 0]
        let h = Scopes.histogram(rgba: pixels)
        XCTAssertEqual(h.count, 4)
        XCTAssertEqual(h.red[255], 2)
        XCTAssertEqual(h.green[0], 2)
        XCTAssertEqual(h.luma[0], 1)
        XCTAssertEqual(h.luma[255], 1)
        XCTAssertEqual(h.luma[54], 1, "pure red's luma is 0.2126 × 255")
        XCTAssertEqual(h.luma[128], 1)
        XCTAssertEqual(h.red.reduce(0, +), 4)
        // A clipped spike doesn't flatten the rest.
        var bins = Array(repeating: 10, count: 256)
        bins[255] = 5000
        let heights = Scopes.heights(bins)
        XCTAssertEqual(heights[100], 1)
        XCTAssertEqual(heights[255], 1)
    }

    func testClippingWarnings() {
        XCTAssertEqual(parse("clipping warning"), [.set("clippingWarning", 1)])
        XCTAssertEqual(parse("show clipping"), [.set("clippingWarning", 1)])
        XCTAssertEqual(parse("clipping off"), [.set("clippingWarning", 0)])
        XCTAssertEqual(Scopes.clipping(255, 10, 10), 1, "one channel at white has lost detail")
        XCTAssertEqual(Scopes.clipping(254, 254, 254), 1)
        XCTAssertEqual(Scopes.clipping(253, 253, 253), 0)
        XCTAssertEqual(Scopes.clipping(0, 1, 0), -1)
        XCTAssertEqual(Scopes.clipping(0, 0, 2), 0, "a deep blue still has detail")
        let pixels: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 255, 120, 90, 60, 255, 255, 255, 255, 255]
        let shares = Scopes.clippedShares(rgba: pixels)
        XCTAssertEqual(shares.highlights, 0.5)
        XCTAssertEqual(shares.shadows, 0.25)
    }

    func testVectorscopeBinsChroma() {
        XCTAssertEqual(parse("vectorscope"), [.set("vectorscope", 1)])
        XCTAssertEqual(parse("show skin tone line"), [.set("vectorscope", 1)])
        XCTAssertEqual(parse("vectorscope off"), [.set("vectorscope", 0)])
        // Greys sit in the middle; red up and to the left of it; blue to the right.
        let grey = Scopes.chroma(0.5, 0.5, 0.5)
        XCTAssertEqual(grey.cb, 0, accuracy: 1e-9)
        XCTAssertEqual(grey.cr, 0, accuracy: 1e-9)
        let red = Scopes.chroma(1, 0, 0), blue = Scopes.chroma(0, 0, 1)
        XCTAssertEqual(red.cr, 0.5, accuracy: 1e-3)
        XCTAssertEqual(blue.cb, 0.5, accuracy: 1e-3)
        // Skin lies near the skin-tone line.
        for skin in [(0.87, 0.68, 0.58), (0.55, 0.38, 0.28), (0.95, 0.80, 0.70)] {
            let c = Scopes.chroma(skin.0, skin.1, skin.2)
            XCTAssertEqual(atan2(c.cr, c.cb) * 180 / .pi, Scopes.skinToneAngle, accuracy: 8)
        }
        let cells = Scopes.vectorscope(rgba: [128, 128, 128, 255, 255, 0, 0, 255, 0, 0, 255, 255, 9, 9, 9, 0], size: 16)
        XCTAssertEqual(cells.reduce(0, +), 3)
        XCTAssertEqual(cells[8 * 16 + 8], 1, "grey in the middle")
        XCTAssertEqual(cells[0 * 16 + 6], 1, "red at the top, left of the middle")
        XCTAssertEqual(Scopes.intensities([0, 1, 100]).last, 1)
    }

    func testColorSamplerReadouts() {
        XCTAssertEqual(parse("color sampler"), [.run("colorSampler")])
        XCTAssertEqual(parse("sample colour"), [.run("colorSampler")])
        XCTAssertEqual(parse("clear samplers"), [.run("clearSamplers")])
        let white = Scopes.readout(1, 1, 1)
        XCTAssertEqual(white.rgb, [255, 255, 255])
        XCTAssertEqual(white.lab[0], 100, accuracy: 0.1)
        XCTAssertEqual(white.lab[1], 0, accuracy: 0.1)
        XCTAssertEqual(white.lab[2], 0, accuracy: 0.1)
        let red = Scopes.readout(1, 0, 0)
        XCTAssertEqual(red.rgb, [255, 0, 0])
        XCTAssertEqual(red.lab[0], 53.2, accuracy: 0.2)
        XCTAssertEqual(red.lab[1], 80.1, accuracy: 0.5)
        XCTAssertEqual(red.lab[2], 67.2, accuracy: 0.5)
        XCTAssertEqual(Scopes.readout(0.5, 0.5, 0.5).lab[0], 53.4, accuracy: 0.2)
    }

    // MARK: - Zoom

    func testZoomNamesAndLevels() {
        XCTAssertEqual(parse("zoom 100"), [.set("zoom", 3)])
        XCTAssertEqual(parse("zoom 1 to 1"), [.set("zoom", 3)])
        XCTAssertEqual(parse("zoom 200%"), [.set("zoom", 4)])
        XCTAssertEqual(parse("zoom in"), [.nudge("zoom", 1)])
        XCTAssertEqual(parse("zoom out"), [.nudge("zoom", -1)])
        XCTAssertEqual(parse("fit"), [.run("zoomFit")])
        XCTAssertEqual(parse("zoom to fit"), [.run("zoomFit")])
        XCTAssertEqual(parse("zoom blur"), [.select("zoomBlur")], "the creative filter keeps its name")
        XCTAssertEqual(parse("cut out 70"), [.set("cutout", 70)])
        XCTAssertEqual(Viewport.levels.count, registry.control(id: "zoom")!.options.count)
        XCTAssertEqual(registry.control(id: "zoom")!.options.map(\.id).dropFirst().map { Double($0)! }, Array(Viewport.levels.dropFirst()))
    }

    func testViewportMaths() {
        // A 4000 px photo fitted at 1000 px: 100 % is four times fit; 25 % is fit itself.
        XCTAssertEqual(Viewport.magnification(percent: 100, full: 4000, fit: 1000), 4)
        XCTAssertEqual(Viewport.magnification(percent: 10, full: 4000, fit: 1000), 1, "never smaller than fit")
        XCTAssertEqual(Viewport.magnification(percent: 0, full: 4000, fit: 1000), 1)
        XCTAssertEqual(Viewport.fitPercent(full: 4000, fit: 1000), 25)
        XCTAssertEqual(Viewport.firstLevel(above: 25), 2, "zoom in from fit goes to 50 %")
        XCTAssertEqual(Viewport.firstLevel(above: 60), 3)
        // The view stays inside the photo.
        XCTAssertEqual(Viewport.visible(magnification: 2, center: (0.5, 0.5)), ViewRect(0.25, 0.25, 0.5, 0.5))
        XCTAssertEqual(Viewport.visible(magnification: 4, center: (0, 1)), ViewRect(0, 0.75, 0.25, 0.25))
        XCTAssertEqual(Viewport.visible(magnification: 1, center: (0.9, 0.1)), ViewRect(0, 0, 1, 1))
    }

    // MARK: - Grid & guides

    func testGridNamesAndLines() {
        XCTAssertEqual(parse("grid thirds"), [.set("gridOverlay", 1)])
        XCTAssertEqual(parse("golden ratio grid"), [.set("gridOverlay", 2)])
        XCTAssertEqual(parse("guides diagonals"), [.set("gridOverlay", 4)])
        XCTAssertEqual(parse("grid off"), [.set("gridOverlay", 0)])
        XCTAssertEqual(parse("clear guides"), [.run("clearGuides")], "upright's guides keep their names")
        XCTAssertEqual(Guides.kinds, registry.control(id: "gridOverlay")!.options.map(\.id))
        run("grid")
        XCTAssertEqual(value("gridOverlay"), 1, "“grid” alone shows the thirds")
        let thirds = Guides.lines("thirds", width: 600, height: 400)
        XCTAssertEqual(thirds.count, 4)
        XCTAssertEqual(thirds[0].from.x, 1.0 / 3, accuracy: 1e-9)
        let golden = Guides.lines("goldenRatio", width: 600, height: 400)
        XCTAssertEqual(golden[0].from.x, 0.382, accuracy: 0.001)
        // Square cells: 8 along the long side, as many as fit along the short one.
        let grid = Guides.lines("grid", width: 800, height: 400)
        XCTAssertEqual(grid.filter { $0.from.x == $0.to.x }.count, 7)
        XCTAssertEqual(grid.filter { $0.from.y == $0.to.y }.count, 3)
        XCTAssertTrue(Guides.lines("off", width: 1, height: 1).isEmpty)
    }

    // MARK: - Targeted adjustment

    func testTargetedAdjustment() {
        XCTAssertEqual(parse("targeted saturation"), [.set("targetedAdjustment", 3)])
        XCTAssertEqual(parse("targeted tone curve"), [.set("targetedAdjustment", 1)])
        XCTAssertEqual(parse("targeted adjustment hue"), [.set("targetedAdjustment", 2)])
        XCTAssertEqual(parse("targeted off"), [.set("targetedAdjustment", 0)])
        XCTAssertEqual(TargetedAdjustment.modes, registry.control(id: "targetedAdjustment")!.options.map(\.id))
        // A red drags the red band only; an orange-red shares it with orange.
        let red = TargetedAdjustment.targets(mode: "saturation", color: RGB(0.8, 0.1, 0.1))
        XCTAssertEqual(red.map(\.id), ["mixerRedSaturation"])
        let orangeRed = TargetedAdjustment.targets(mode: "hue", color: RGB(0.9, 0.3, 0.1))
        XCTAssertEqual(orangeRed.map(\.id), ["mixerRedHue", "mixerOrangeHue"])
        XCTAssertEqual(orangeRed.map(\.weight).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertTrue(TargetedAdjustment.targets(mode: "saturation", color: RGB(0.5, 0.5, 0.5)).isEmpty, "greys have no band")
        // Tone curve: the regions nearest the brightness.
        XCTAssertEqual(TargetedAdjustment.targets(mode: "toneCurve", color: RGB(0.05, 0.05, 0.05)).map(\.id), ["curveShadows"])
        let mid = TargetedAdjustment.targets(mode: "toneCurve", color: RGB(0.5, 0.5, 0.5))
        XCTAssertEqual(mid.map(\.id), ["curveDarks", "curveLights"])
        XCTAssertEqual(mid[0].weight, 0.5, accuracy: 1e-9)
        XCTAssertEqual(TargetedAdjustment.targets(mode: "toneCurve", color: RGB(1, 1, 1)).map(\.id), ["curveHighlights"])
        // A drag up a quarter of the picture: +50 split between the regions, from where they were.
        let v = TargetedAdjustment.values(mode: "toneCurve", color: RGB(0.5, 0.5, 0.5), rise: 0.25) { $0 == "curveDarks" ? 10 : 0 }
        XCTAssertEqual(v, ["curveDarks": 35, "curveLights": 25])
    }

    // MARK: - Soft proofing

    func testSoftProofNames() {
        XCTAssertEqual(parse("soft proof print"), [.set("softProof", 2)])
        XCTAssertEqual(parse("proof matte"), [.set("softProof", 3)])
        XCTAssertEqual(parse("soft proof srgb"), [.set("softProof", 1)])
        XCTAssertEqual(parse("soft proof off"), [.set("softProof", 0)])
        XCTAssertEqual(parse("gamut warning"), [.set("gamutWarning", 1)])
        XCTAssertEqual(parse("show out of gamut"), [.set("gamutWarning", 1)])
        XCTAssertEqual(SoftProof.profiles, registry.control(id: "softProof")!.options.map(\.id))
    }

    func testSoftProofMaths() {
        // Lab and back.
        for c in [RGB(0.2, 0.5, 0.8), RGB(1, 1, 1), RGB(0.9, 0.3, 0.1)] {
            let lab = SoftProof.lab(c)
            let back = SoftProof.rgb(l: lab.l, a: lab.a, b: lab.b)
            XCTAssertEqual(back.r, c.r, accuracy: 0.01)
            XCTAssertEqual(back.g, c.g, accuracy: 0.01)
            XCTAssertEqual(back.b, c.b, accuracy: 0.01)
        }
        let glossy = SoftProof.papers["glossy"]!, newsprint = SoftProof.papers["newsprint"]!
        // Inks reach most chroma at their own lightness, none at paper white or ink black.
        XCTAssertEqual(SoftProof.maxChroma(l: 88, hue: 95, paper: glossy), 92, accuracy: 0.5)
        XCTAssertEqual(SoftProof.maxChroma(l: 96, hue: 95, paper: glossy), 0, accuracy: 0.5)
        XCTAssertEqual(SoftProof.maxChroma(l: 8, hue: 40, paper: glossy), 0, accuracy: 0.5)
        XCTAssertLessThan(SoftProof.maxChroma(l: 50, hue: 40, paper: newsprint), SoftProof.maxChroma(l: 50, hue: 40, paper: glossy))
        // A pure screen blue can't be printed; a muted skin tone can.
        XCTAssertTrue(SoftProof.proof(RGB(0, 0, 1), profile: "glossy").outOfGamut)
        XCTAssertFalse(SoftProof.proof(RGB(0.8, 0.62, 0.52), profile: "glossy").outOfGamut)
        // Paper white is darker than screen white, ink black lighter than screen black.
        XCTAssertLessThan(SoftProof.proof(RGB(1, 1, 1), profile: "matte").color.g, 0.97)
        XCTAssertGreaterThan(SoftProof.proof(RGB(0, 0, 0), profile: "matte").color.g, 0.1)
        // sRGB: as it is; saturated colours on the edge are warned about, greys and white are not.
        XCTAssertEqual(SoftProof.proof(RGB(0.3, 0.4, 0.5), profile: "srgb").color, RGB(0.3, 0.4, 0.5))
        XCTAssertTrue(SoftProof.proof(RGB(1, 0.1, 0.1), profile: "srgb").outOfGamut)
        XCTAssertFalse(SoftProof.proof(RGB(1, 1, 1), profile: "srgb").outOfGamut)
        let cube = SoftProof.cube(profile: "glossy", warn: true, size: 5)
        XCTAssertEqual(cube.count, 5 * 5 * 5 * 4)
        // The pure blue corner (r 0, g 0, b 1) is painted grey.
        let i = (4 * 25 + 0 * 5 + 0) * 4
        XCTAssertEqual(Array(cube[i..<(i + 3)]), [0.5, 0.5, 0.5])
    }

    // MARK: - Match exposures

    func testMatchExposuresEvensTheKeys() {
        XCTAssertEqual(parse("match exposures"), [.run("matchExposures")])
        func picture(_ lumas: [Float]) -> [Float] { lumas.flatMap { [$0, $0, $0, 1] } }
        let bright = picture([0.02, 0.2, 0.4, 0.8])
        let dark = picture([0.01, 0.1, 0.2, 0.4])
        XCTAssertEqual(MatchExposure.stops(reference: MatchExposure.key(rgba: bright), photo: MatchExposure.key(rgba: dark)), 1, accuracy: 0.01)
        XCTAssertEqual(MatchExposure.stops(reference: MatchExposure.key(rgba: dark), photo: MatchExposure.key(rgba: bright)), -1, accuracy: 0.01)
        // One bright lamp hardly moves the key; see-through pixels don't count.
        let lamp = picture(Array(repeating: [0.01, 0.1, 0.2, 0.4] as [Float], count: 5).flatMap { $0 } + [50])
        XCTAssertLessThan(MatchExposure.stops(reference: MatchExposure.key(rgba: lamp), photo: MatchExposure.key(rgba: dark)), 0.5)
        XCTAssertEqual(MatchExposure.key(rgba: dark + [9, 9, 9, 0]), MatchExposure.key(rgba: dark), accuracy: 1e-9)
        XCTAssertEqual(MatchExposure.stops(reference: 1, photo: 0.0001), 4)
    }

    func testNoPresetSaysSo() {
        XCTAssertEqual(events(run("preset nothing like this")), [.noPreset("nothing like this")])
        XCTAssertEqual(value("exposure"), 0)
    }
}
