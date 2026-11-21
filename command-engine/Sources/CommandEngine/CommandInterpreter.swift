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
        return run(commands, state: &state)
    }

    /// Applies commands that didn't come from text, e.g. a button press: `[.run("auto")]`.
    public mutating func apply(_ commands: [Command], state: inout EditState) -> [Outcome] {
        lastCommands = commands
        return run(commands, state: &state)
    }

    /// Runs the commands in order: workspace actions (presets, …) by the workspace, the rest by the
    /// applier, a run of them at a time.
    private mutating func run(_ commands: [Command], state: inout EditState) -> [Outcome] {
        var outcomes: [Outcome] = []
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
        return outcomes
    }
}
