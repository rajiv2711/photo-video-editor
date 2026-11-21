import Foundation

/// Convenience used by the app: parse text, then apply the commands, remembering which control
/// is focused so a bare "more" acts on it. Parsing and applying stay separate underneath.
///
///     parse("contrast more more more") → [{"op":"nudge","control":"contrast","steps":3}]
///     apply(...)                       → Contrast 0 → 15
public struct CommandInterpreter {
    public typealias Outcome = CommandOutcome

    public let registry: ControlRegistry
    public private(set) var lastControlID: String?
    public private(set) var lastCommands: [Command] = []
    /// Presets and (later) the history of the edit: its actions run here, in order with the rest.
    public var workspace: Workspace
    private let parser: CommandParser
    private var applier: CommandApplier

    /// Runs action controls such as "auto" (see `CommandApplier.actionHandler`).
    public var actionHandler: ((String) -> [Command])? {
        get { applier.actionHandler }
        set { applier.actionHandler = newValue }
    }

    public init(registry: ControlRegistry) {
        self.registry = registry
        self.parser = CommandParser(registry: registry)
        self.applier = CommandApplier(registry: registry)
        self.workspace = Workspace(registry: registry)
    }

    /// Remember a control the user picked by touch, so a following "more" applies to it.
    public mutating func focus(controlID: String) {
        lastControlID = controlID
    }

    public mutating func interpret(_ text: String, state: inout EditState) -> [Outcome] {
        let commands = parser.parse(text)
        lastCommands = commands
        return run(commands, state: &state, label: text)
    }

    /// Applies commands that didn't come from text, e.g. a button press: `[.run("auto")]`.
    public mutating func apply(_ commands: [Command], state: inout EditState) -> [Outcome] {
        lastCommands = commands
        return run(commands, state: &state, label: nil)
    }

    /// A change made on the edit directly (by touch), as a history step; `key`: a drag's records merge.
    public mutating func record(_ state: EditState, label: String, key: String? = nil) {
        workspace.history.record(state, label: label, key: key)
    }

    /// Runs the commands in order: workspace actions (presets, …) by the workspace, the rest by the
    /// applier, a run of them at a time; then records the history step, named by what was said (or
    /// what the commands did, for buttons).
    private mutating func run(_ commands: [Command], state: inout EditState, label: String?) -> [Outcome] {
        var outcomes: [Outcome] = []
        let registry = self.registry
        func name() -> String { label ?? Workflow.label(outcomes, registry: registry) }
        var pending: [Command] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let done = applier.apply(pending, state: &state, focus: &lastControlID)
            outcomes += done + workspace.follow(done, state: &state)
            pending = []
        }
        var queue = commands
        while !queue.isEmpty {
            var command = queue.removeFirst()
            if command.op == .run, let id = command.control, Workspace.actions.contains(id) {
                flush()
                // "exposure 1 undo": what was changed first is a step of its own.
                if Workspace.historyActions.contains(id) { workspace.history.record(state, label: name()) }
                // "preset portra exposure 0.3": the words after a known name are commands again.
                if let text = command.text, let split = workspace.knownName(at: text, for: id) {
                    command.text = split.name
                    queue = parser.parse(split.rest) + queue
                }
                outcomes += workspace.run(command, state: &state)
            } else {
                pending.append(command)
            }
        }
        flush()
        workspace.history.record(state, label: name())
        return outcomes
    }
}
