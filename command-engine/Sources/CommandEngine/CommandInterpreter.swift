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
    }

    /// Remember a control the user picked by touch, so a following "more" applies to it.
    public mutating func focus(controlID: String) {
        lastControlID = controlID
    }

    public mutating func interpret(_ text: String, state: inout EditState) -> [Outcome] {
        let commands = parser.parse(text)
        lastCommands = commands
        return applier.apply(commands, state: &state, focus: &lastControlID)
    }

    /// Applies commands that didn't come from text, e.g. a button press: `[.run("auto")]`.
    public mutating func apply(_ commands: [Command], state: inout EditState) -> [Outcome] {
        lastCommands = commands
        return applier.apply(commands, state: &state, focus: &lastControlID)
    }
}
