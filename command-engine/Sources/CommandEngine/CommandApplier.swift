import Foundation

/// What happened when commands were applied; the UI turns these into feedback.
public enum CommandOutcome: Equatable {
    case changed(controlID: String, from: Double, to: Double)
    /// A value stored on a mask changed: a local slider, a mask setting or a part's setting.
    /// `mask` is the mask's number (1 = the first).
    case changedInMask(mask: Int, controlID: String, from: Double, to: Double)
    /// An action control ran ("auto"); the changes it made follow as `.changed` outcomes.
    case ran(controlID: String)
    /// Something happened to a mask (made, a part added, deleted…); `mask` is its number, 0 = none.
    case masked(mask: Int, event: MaskEvent)
    /// The control was named or nudged but its value did not move (e.g. already at max).
    case unchanged(controlID: String, value: Double)
    /// A word matched several controls equally well; the UI should offer them as choices.
    case ambiguous(word: String, candidateIDs: [String])
    case unknown(word: String)
    /// "more" or "less" with no control named or focused.
    case needsControl
    /// The control acts on a selected mask (or on one kind of mask part) and there is none.
    case needsMask(controlID: String)
    /// A setting of a retouch step changed (its opacity, …); `spot` is the step's number (1 = the first).
    case changedInSpot(spot: Int, controlID: String, from: Double, to: Double)
    /// Something happened to a retouch step (deleted, …); `spot` is its number, 0 = all.
    case retouched(spot: Int, event: RetouchEvent)
    /// The control acts on a selected retouch step (of a kind that has it) and there is none.
    case needsSpot(controlID: String)
    /// A setting of a layer changed (its opacity, …); `layer` is its number (1 = the lowest).
    case changedInLayer(layer: Int, controlID: String, from: Double, to: Double)
    /// Something happened to a layer (made, deleted, moved…); `layer` is its number, 0 = none.
    case layered(layer: Int, event: LayerEvent)
    /// The control acts on a selected layer (of a kind that has it) and there is none.
    case needsLayer(controlID: String)
}

/// Applies commands to slider values: [Command] → new EditState + outcomes.
/// Consecutive commands on the same control report as one change ("contrast 20 more" → 0 → 25).
/// While a mask is selected, local-capable sliders change that mask (see Masks.swift).
public struct CommandApplier {
    public let registry: ControlRegistry
    /// Runs an action control ("auto") and returns the commands it stands for, e.g. a `set` per
    /// slider. The app supplies it, because actions look at the photo. Without it actions only report `.ran`.
    public var actionHandler: ((String) -> [Command])?

    public init(registry: ControlRegistry, actionHandler: ((String) -> [Command])? = nil) {
        self.registry = registry
        self.actionHandler = actionHandler
    }

    public func apply(_ commands: [Command], state: inout EditState, focus: inout String?) -> [CommandOutcome] {
        var outcomes: [CommandOutcome] = []
        var run: (control: Control, target: EditState.Target, start: Double)?

        func flush() {
            guard let r = run else { return }
            let end = state.value(of: r.control, at: r.target)
            if end == r.start {
                outcomes.append(.unchanged(controlID: r.control.id, value: end))
            } else {
                switch r.target {
                case .global:
                    outcomes.append(.changed(controlID: r.control.id, from: r.start, to: end))
                case .mask(let m), .component(let m, _):
                    outcomes.append(.changedInMask(mask: m + 1, controlID: r.control.id, from: r.start, to: end))
                case .retouch(let s):
                    outcomes.append(.changedInSpot(spot: s + 1, controlID: r.control.id, from: r.start, to: end))
                case .layer(let l):
                    outcomes.append(.changedInLayer(layer: l + 1, controlID: r.control.id, from: r.start, to: end))
                }
            }
            run = nil
        }

        for command in commands {
            switch command.op {
            case .resetAll:
                flush()
                for control in registry.controls where !state.isDefault(control) {
                    let from = state.value(of: control)
                    let to = state.set(control, to: control.defaultValue)
                    outcomes.append(.changed(controlID: control.id, from: from, to: to))
                }
                if !state.masks.isEmpty {
                    state.masks = []
                    outcomes.append(.masked(mask: 0, event: .allDeleted))
                }
                if !state.retouches.isEmpty {
                    state.retouches = []
                    outcomes.append(.retouched(spot: 0, event: .allDeleted))
                }
                state.geometry = GeometryEdits()
                if !state.layers.isEmpty {
                    state.layers = []
                    outcomes.append(.layered(layer: 0, event: .allDeleted))
                }
                state.watermarkText = ""
                continue
            case .ambiguous:
                flush()
                outcomes.append(.ambiguous(word: command.word ?? "", candidateIDs: command.candidates ?? []))
                continue
            case .unknown:
                flush()
                outcomes.append(.unknown(word: command.word ?? ""))
                continue
            default:
                break
            }

            guard let id = command.control ?? focus else {
                flush()
                if outcomes.last != .needsControl { outcomes.append(.needsControl) }
                continue
            }
            guard let control = registry.control(id: id) else {
                flush()
                outcomes.append(.unknown(word: id))  // e.g. a model invented a control
                continue
            }
            if control.kind == .action {
                flush()
                if let done = maskAction(control, command, state: &state) {
                    outcomes += done
                    continue
                }
                if let done = retouchAction(control, command, state: &state) {
                    outcomes += done
                    continue
                }
                if let done = geometryAction(control, command, state: &state) {
                    outcomes += done
                    continue
                }
                if let done = mergeAction(control, command, state: &state) {
                    outcomes += done
                    continue
                }
                if let done = layerAction(control, command, state: &state) {
                    outcomes += done
                    continue
                }
                // Any command on an action runs it; its own commands are applied right here, in order.
                outcomes.append(.ran(controlID: control.id))
                let produced = (actionHandler?(control.id) ?? []).filter { $0.op != .run }
                var inner = self
                inner.actionHandler = nil
                outcomes += inner.apply(produced, state: &state, focus: &focus).filter {
                    if case .unchanged = $0 { return false }
                    return true
                }
                continue
            }
            guard let target = state.target(for: control) else {
                flush()
                outcomes.append(control.scope == "layer" ? .needsLayer(controlID: control.id) : .needsMask(controlID: control.id))
                continue
            }
            if run?.control.id != control.id || run?.target != target {
                flush()
                run = (control, target, state.value(of: control, at: target))
            }
            focus = control.id

            let current = state.value(of: control, at: target)
            defer {
                // The crop box turns and flips with the photo.
                if target == .global, control.group == "geometry" {
                    GeometryTools.follow(control.id, from: current, to: state.value(of: control), state: &state, registry: registry)
                }
            }
            switch command.op {
            case .nudge: state.set(control, to: current + Double(command.steps ?? 0) * control.step, at: target)
            case .add: state.set(control, to: current + (command.value ?? 0), at: target)
            case .set: state.set(control, to: command.value ?? current, at: target)
            case .reset: state.set(control, to: control.defaultValue, at: target)
            case .max: state.set(control, to: control.max, at: target)
            case .min: state.set(control, to: control.min, at: target)
            case .select:
                // "zoom blur": naming a creative filter that is off turns it on.
                if let on = control.on, current == control.defaultValue {
                    state.set(control, to: on, at: target)
                }
                // "mask exposure more": a bare "mask" picks the newest mask when none is selected.
                if control.id == EditState.maskSelectorID, state.selectedMask == nil, !state.masks.isEmpty {
                    state.selectMask(state.masks.count - 1)
                }
                // "spot opacity 50" after a bare "spot": the newest step.
                if control.id == EditState.spotSelectorID, state.selectedRetouch == nil, !state.retouches.isEmpty {
                    state.selectRetouch(state.retouches.count - 1)
                }
                // "layer opacity 50" after a bare "layer": the top layer.
                if control.id == EditState.layerSelectorID, state.selectedLayer == nil, !state.layers.isEmpty {
                    state.selectLayer(state.layers.count - 1)
                }
            case .run, .resetAll, .ambiguous, .unknown: break
            }
        }
        flush()
        return outcomes
    }

    // MARK: - Masks panel actions

    /// Runs a Masks-panel action (make a mask part, delete, duplicate, done); nil for other actions.
    private func maskAction(_ control: Control, _ command: Command, state: inout EditState) -> [CommandOutcome]? {
        if let kind = control.component {
            let option = command.value.flatMap { v -> String? in
                let i = Int(v)
                return control.options.indices.contains(i) ? control.options[i].id : nil
            }
            let mode = command.mode.flatMap { MaskComponent.Mode(rawValue: $0) }
            if let mode, let m = state.selectedMask {
                // "subtract luminance range": a new part of the selected mask.
                state.masks[m].components.append(MaskPresets.component(kind: kind, mode: mode, option: option, registry: registry))
                state.masks[m].selectedComponent = state.masks[m].components.count - 1
                return [.ran(controlID: control.id), .masked(mask: m + 1, event: .added(kind, mode))]
            }
            if let mode, mode != .add {
                return [.needsMask(controlID: control.id)]
            }
            // A new mask (also "add …" with no mask selected).
            state.masks.append(Mask(components: [MaskPresets.component(kind: kind, mode: .add, option: option, registry: registry)]))
            state.selectMask(state.masks.count - 1)
            return [.ran(controlID: control.id), .masked(mask: state.masks.count, event: .created(kind))]
        }

        /// "delete mask 2" names a mask; otherwise the selected one.
        func named() -> Int? {
            if let v = command.value {
                let i = Int(v) - 1
                return state.masks.indices.contains(i) ? i : nil
            }
            return state.selectedMask
        }

        switch control.id {
        case "deleteMask":
            guard let m = named() else { return [.needsMask(controlID: control.id)] }
            state.masks.remove(at: m)
            state.selectMask(nil)
            return [.ran(controlID: control.id), .masked(mask: m + 1, event: .deleted)]
        case "duplicateMask":
            guard let m = named() else { return [.needsMask(controlID: control.id)] }
            state.masks.append(state.masks[m])
            state.selectMask(state.masks.count - 1)
            return [.ran(controlID: control.id), .masked(mask: state.masks.count, event: .duplicated(from: m + 1))]
        case "maskDone":
            // Also puts the retouch tool away and deselects the layer: touches on the photo do nothing
            // until a tool, mask or layer is picked.
            state.selectMask(nil)
            state.setRetouchTool(nil)
            state.selectLayer(nil)
            return [.ran(controlID: control.id), .masked(mask: 0, event: .deselected)]
        case "deleteComponent":
            guard let s = state.selectedComponent else { return [.needsMask(controlID: control.id)] }
            state.masks[s.mask].components.remove(at: s.component)
            if state.masks[s.mask].components.isEmpty {
                state.masks.remove(at: s.mask)
                state.selectMask(nil)
                return [.ran(controlID: control.id), .masked(mask: s.mask + 1, event: .deleted)]
            }
            state.masks[s.mask].selectedComponent = min(s.component, state.masks[s.mask].components.count - 1)
            return [.ran(controlID: control.id), .masked(mask: s.mask + 1, event: .partDeleted)]
        default:
            return nil
        }
    }

    // MARK: - Retouch panel actions

    /// Runs a Retouch-panel action (pick a tool, delete or undo a step); nil for other actions.
    private func retouchAction(_ control: Control, _ command: Command, state: inout EditState) -> [CommandOutcome]? {
        if let tool = control.tool, control.group == "retouch" {
            // Picking a tool leaves the masks (touches on the photo now retouch) and starts a new step.
            var out: [CommandOutcome] = [.ran(controlID: control.id)]
            if state.selectedMask != nil {
                state.selectMask(nil)
                out.append(.masked(mask: 0, event: .deselected))
            }
            if state.selectedLayer != nil {
                state.selectLayer(nil)
                out.append(.layered(layer: 0, event: .deselected))
            }
            state.setRetouchTool(tool)
            state.selectRetouch(nil)
            // "liquify pucker": the action's option sets the tool's mode.
            if let v = command.value, let id = RetouchTools.optionSetting[tool], let setting = registry.control(id: id) {
                state.set(setting, to: v)
            }
            return out
        }

        /// "delete spot 2" names a step; otherwise the selected one.
        func named() -> Int? {
            if let v = command.value {
                let i = Int(v) - 1
                return state.retouches.indices.contains(i) ? i : nil
            }
            return state.selectedRetouch
        }

        switch control.id {
        case "deleteSpot":
            guard let s = named() else { return [.needsSpot(controlID: control.id)] }
            state.retouches.remove(at: s)
            state.selectRetouch(nil)
            return [.ran(controlID: control.id), .retouched(spot: s + 1, event: .deleted)]
        case "spotSource":
            // A tap on the photo then sets the selected spot's source (the app arms a picker on .ran).
            guard let s = state.selectedRetouch, RetouchTools.copying.contains(state.retouches[s].tool) else {
                return [.needsSpot(controlID: control.id)]
            }
            return [.ran(controlID: control.id)]
        case "undoSpot":
            guard !state.retouches.isEmpty else { return [.needsSpot(controlID: control.id)] }
            state.retouches.removeLast()
            state.selectRetouch(nil)
            return [.ran(controlID: control.id), .retouched(spot: state.retouches.count + 1, event: .deleted)]
        default:
            return nil
        }
    }

    // MARK: - Geometry panel actions

    /// Runs a Geometry-panel action (reset the crop, turn, clear guides, pick a touch tool); nil for
    /// other actions and for those the app works out from the photo (auto straighten, …).
    private func geometryAction(_ control: Control, _ command: Command, state: inout EditState) -> [CommandOutcome]? {
        guard control.group == "geometry", !GeometryTools.fromPhoto.contains(control.id) else { return nil }
        var out: [CommandOutcome] = [.ran(controlID: control.id)]
        func set(_ id: String, _ value: Double) {
            guard let c = registry.control(id: id) else { return }
            let from = state.value(of: c)
            let to = state.set(c, to: value)
            if from != to { out.append(.changed(controlID: id, from: from, to: to)) }
            GeometryTools.follow(id, from: from, to: to, state: &state, registry: registry)
        }
        if GeometryTools.actions[control.id] != nil {
            // A touch tool for the photo: masks, retouch tools and layers are put away (the app arms the tool on .ran).
            state.selectMask(nil)
            state.setRetouchTool(nil)
            state.selectLayer(nil)
        }
        switch control.id {
        case "resetCrop":
            for id in GeometryTools.cropIDs {
                if let c = registry.control(id: id) { set(id, c.defaultValue) }
            }
        case "guidedUpright":
            set("upright", Double(Upright.modes.firstIndex(of: "guided") ?? 0))
        case "clearGuides":
            state.geometry.guides = []
        case "clearPerspectiveCrop":
            state.geometry.quad = []
        case "warp":
            // The grid of handles to drag (puppet pins are added by tapping instead).
            if state.geometry.pins.isEmpty { state.geometry.pins = Warp.lattice }
        case "resetWarp":
            state.geometry.pins = []
        case "rotateLeft", "rotateRight":
            let turns = registry.control(id: "rotation").map { state.value(of: $0) } ?? 0
            set("rotation", Double(((Int(turns) + (control.id == "rotateRight" ? 1 : 3)) % 4)))
        default:
            break
        }
        return out
    }

    // MARK: - Merge panel actions

    /// A merge action ("hdr merge"): reports `.ran` (the app merges the photos picked) after applying
    /// what was said with it: an option sets its choice ("stack median"), a number how many of the
    /// last photos picked to use ("hdr merge 3"). Nil for other actions.
    private func mergeAction(_ control: Control, _ command: Command, state: inout EditState) -> [CommandOutcome]? {
        guard MergeTools.actions[control.id] != nil else { return nil }
        var out: [CommandOutcome] = [.ran(controlID: control.id)]
        let setting = control.options.isEmpty ? MergeTools.countID : MergeTools.optionSetting[control.id]
        if let v = command.value, let id = setting, let c = registry.control(id: id) {
            let from = state.value(of: c)
            let to = state.set(c, to: v)
            if from != to { out.append(.changed(controlID: id, from: from, to: to)) }
        }
        return out
    }
}
