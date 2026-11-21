import Foundation

// The workspace around an edit (Presets & batch, History panels): the user's presets and the built-in
// packs, the preset applied last (for Preset Amount), copied settings, the last photo's edit and the
// history of this one (undo, redo). The interpreter runs its actions in the order they were said,
// between the other commands ("preset portra exposure 0.3": the preset, then the exposure on top), so
// they work by voice and by touch alike.

/// Something that happened in the workspace, for the feedback line.
public enum WorkflowEvent: Equatable {
    /// A preset was applied at an amount (%); `changes`: how many settings it changed.
    case presetApplied(name: String, amount: Double, changes: Int)
    /// The current edit was saved as a preset with these panels.
    case presetSaved(name: String, groups: [String])
    case presetRenamed(from: String, to: String)
    case presetDeleted(String)
    /// No preset has that name ("" when none was said).
    case noPreset(String)
    /// Several presets fit the words: their names.
    case presetChoices(word: String, names: [String])
    /// Built-in presets can't be renamed or deleted.
    case builtInPreset(String)
    /// The settings of these panels were copied.
    case copied([String])
    /// Copied settings were pasted: how many settings changed.
    case pasted(changes: Int)
    /// "paste" before anything was copied.
    case nothingCopied
    /// The last photo's edit was applied: how many settings changed.
    case previousApplied(changes: Int)
    /// "previous" on the first photo opened.
    case noPrevious
    /// Steps undone (their labels, newest first) or redone (oldest first).
    case undone([String])
    case redone([String])
    case nothingToUndo
    case nothingToRedo
    /// The edit went to a step of the history: its number (0 = as opened) and label.
    case historyJumped(step: Int, label: String)
    /// "history" alone: how many steps there are (the app shows the History panel).
    case historyShown(steps: Int)
    /// "history 40" when there are fewer steps.
    case noHistoryStep(Int)
}

/// The presets, and later the history, copies and snapshots of the photo being edited.
public struct Workspace {
    public let registry: ControlRegistry
    /// The user's own presets, oldest first (the app keeps them in a file).
    public var presets: [Preset] = []
    /// The built-in presets, pack by pack.
    public let packs: [Preset]
    /// The preset applied last: Preset Amount applies it again at the new strength.
    public private(set) var applied: Preset?
    /// Settings copied (Copy Settings), for pasting on this photo or another.
    public var clipboard: Preset?
    /// The edit of the photo opened before this one, every panel (Previous takes the included ones).
    public var previous: Preset?
    /// This photo's edit, step by step (Undo, Redo, History).
    public var history: EditHistory

    /// The actions the workspace runs (the applier never sees them).
    public static let actions: Set<String> = ["applyPreset", "savePreset", "renamePreset", "deletePreset", "copySettings", "pasteSettings",
                                              "previousSettings", "undo", "redo", "history"]

    /// Actions that move through the history: what was changed before them is recorded first.
    public static let historyActions: Set<String> = ["undo", "redo", "history"]

    public init(registry: ControlRegistry, packs: [Preset] = Presets.bundled()) {
        self.registry = registry
        self.packs = packs
        self.history = EditHistory(registry: registry)
    }

    /// The user's presets, then the built-in ones (a name of the user's wins).
    public var allPresets: [Preset] { presets + packs }

    /// Runs one workspace action on the edit.
    public mutating func run(_ command: Command, state: inout EditState) -> [CommandOutcome] {
        guard let id = command.control else { return [] }
        let ran = CommandOutcome.ran(controlID: id)
        let words = command.text ?? command.value.map { String(Int($0)) } ?? ""
        switch id {
        case "applyPreset":
            switch find(words) {
            case .index(let i):
                let preset = allPresets[i]
                applied = preset
                if let amount = registry.control(id: Presets.amountID) { state.set(amount, to: 100) }
                let changes = preset.apply(to: &state, registry: registry)
                return [ran, .workflow(.presetApplied(name: preset.name, amount: 100, changes: changes))]
            case .failed(let event):
                return [ran, .workflow(event)]
            }
        case "savePreset":
            let name = words.isEmpty ? "Preset \(presets.count + 1)" : words
            let groups = Presets.included(state, registry: registry)
            let preset = Preset.capture(state, name: name, groups: groups, registry: registry)
            // Saving under a name the user already has replaces that preset.
            if let i = presets.firstIndex(where: { Presets.normalized($0.name) == Presets.normalized(name) }) {
                presets[i] = preset
            } else {
                presets.append(preset)
            }
            return [ran, .workflow(.presetSaved(name: name, groups: groups))]
        case "renamePreset":
            // "rename preset warm look to cosy": the last " to " splits old and new; without one the
            // preset applied last gets the new name.
            var old = applied?.name ?? ""
            var new = words
            if let r = words.range(of: " to ", options: [.backwards, .caseInsensitive]) {
                old = String(words[..<r.lowerBound])
                new = String(words[r.upperBound...])
            }
            new = new.trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty else { return [ran, .workflow(.noPreset(""))] }
            switch find(old) {
            case .index(let i):
                guard i < presets.count else { return [ran, .workflow(.builtInPreset(allPresets[i].name))] }
                let from = presets[i].name
                presets[i].name = new
                if applied?.name == from, applied?.pack == nil { applied?.name = new }
                return [ran, .workflow(.presetRenamed(from: from, to: new))]
            case .failed(let event):
                return [ran, .workflow(event)]
            }
        case "deletePreset":
            switch find(words) {
            case .index(let i):
                guard i < presets.count else { return [ran, .workflow(.builtInPreset(allPresets[i].name))] }
                let name = presets.remove(at: i).name
                if applied?.name == name, applied?.pack == nil { applied = nil }
                return [ran, .workflow(.presetDeleted(name))]
            case .failed(let event):
                return [ran, .workflow(event)]
            }
        case "copySettings":
            // The panels the Include switches choose now.
            let groups = Presets.included(state, registry: registry)
            clipboard = Preset.capture(state, name: "Copied settings", groups: groups, registry: registry)
            return [ran, .workflow(.copied(groups))]
        case "pasteSettings":
            guard let clipboard else { return [ran, .workflow(.nothingCopied)] }
            return [ran, .workflow(.pasted(changes: clipboard.apply(to: &state, registry: registry)))]
        case "previousSettings":
            // The panels the Include switches choose now.
            guard let previous else { return [ran, .workflow(.noPrevious)] }
            let groups = Presets.included(state, registry: registry)
            return [ran, .workflow(.previousApplied(changes: previous.only(groups, registry: registry).apply(to: &state, registry: registry)))]
        case "undo":
            guard history.canUndo else { return [ran, .workflow(.nothingToUndo)] }
            let undone = history.undo(Int(command.value ?? 1))
            state = history.restored(keeping: state)
            return [ran, .workflow(.undone(undone))]
        case "redo":
            guard history.canRedo else { return [ran, .workflow(.nothingToRedo)] }
            let redone = history.redo(Int(command.value ?? 1))
            state = history.restored(keeping: state)
            return [ran, .workflow(.redone(redone))]
        case "history":
            // "history 12" goes to step 12 (0 = the photo as opened); "history" alone lists them.
            guard let v = command.value else { return [ran, .workflow(.historyShown(steps: history.steps.count - 1))] }
            guard history.jump(to: Int(v)) else { return [ran, .workflow(.noHistoryStep(Int(v)))] }
            state = history.restored(keeping: state)
            return [ran, .workflow(.historyJumped(step: Int(v), label: history.current.label))]
        default:
            return [ran]
        }
    }

    /// Another photo is opened: the edit of this one becomes Previous.
    public mutating func closePhoto(_ state: EditState) {
        previous = Preset.capture(state, name: "Previous", groups: Presets.allGroups, registry: registry)
        applied = nil
    }

    /// After other commands: a new Preset Amount applies the last preset again at that strength.
    public mutating func follow(_ outcomes: [CommandOutcome], state: inout EditState) -> [CommandOutcome] {
        guard let preset = applied, let amount = registry.control(id: Presets.amountID),
              outcomes.contains(where: { if case .changed(Presets.amountID, _, _) = $0 { return true } else { return false } }) else {
            return []
        }
        let value = state.value(of: amount)
        let changes = preset.apply(to: &state, amount: value / 100, registry: registry)
        return [.workflow(.presetApplied(name: preset.name, amount: value, changes: changes))]
    }

    /// The longest run of words at the start of `text` that is exactly a name the action looks for
    /// (a preset's name, or its pack and name), and the words after it; nil when no name starts the
    /// text or nothing follows it.
    public func knownName(at text: String, for action: String) -> (name: String, rest: String)? {
        guard action == "applyPreset" else { return nil }
        let names = Set(allPresets.flatMap { p in [Presets.normalized(p.name)] + (p.pack.map { [Presets.normalized($0 + " " + p.name)] } ?? []) })
        let words = text.split(separator: " ").map(String.init)
        for count in stride(from: words.count - 1, through: 1, by: -1) {
            let head = words.prefix(count).joined(separator: " ")
            if names.contains(Presets.normalized(head)) {
                return (head, words.dropFirst(count).joined(separator: " "))
            }
        }
        return nil
    }

    /// A preset found by name, or what to say instead.
    enum Found {
        case index(Int)
        case failed(WorkflowEvent)
    }

    /// The preset `words` name, as an index into `allPresets`, or why there is none.
    private func find(_ words: String) -> Found {
        let all = allPresets
        switch Presets.find(words, in: all) {
        case .found(let i): return .index(i)
        case .ambiguous(let found): return .failed(.presetChoices(word: words, names: found.map { all[$0].name }))
        case .none: return .failed(.noPreset(words))
        }
    }
}

/// Which controls are part of the edit, and history step names.
public enum Workflow {
    /// A history step's name from what a command did: "Exposure 0.5", "Linear Gradient", "Contrast 20 +2".
    public static func label(_ outcomes: [CommandOutcome], registry: ControlRegistry) -> String {
        var parts: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .changed(let id, _, let to), .changedInMask(_, let id, _, let to), .changedInSpot(_, let id, _, let to),
                 .changedInLayer(_, let id, _, let to):
                if let control = registry.control(id: id), !isSetting(control) { parts.append(control.label + " " + number(to)) }
            case .ran(let id):
                if let control = registry.control(id: id) { parts.append(control.label) }
            default:
                break
            }
        }
        guard let first = parts.first else { return "Edit" }
        return parts.count == 1 ? first : first + " +\(parts.count - 1)"
    }

    /// 20 → "20", 0.5 → "0.5".
    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String((v * 100).rounded() / 100)
    }

    /// How the user looks at the photo and works (the View panel, the Include switches), not the edit:
    /// "reset all", undo and presets leave them as they are.
    public static func isSetting(_ control: Control) -> Bool {
        control.group == "view" || Presets.includes.contains { $0.id == control.id }
    }
}
