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
