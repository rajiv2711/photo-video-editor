import Foundation

/// What happened when commands were applied; the UI turns these into feedback.
public enum CommandOutcome: Equatable {
    case changed(controlID: String, from: Double, to: Double)
    /// The control was named or nudged but its value did not move (e.g. already at max).
    case unchanged(controlID: String, value: Double)
    /// A word matched several controls equally well; the UI should offer them as choices.
    case ambiguous(word: String, candidateIDs: [String])
    case unknown(word: String)
    /// "more" or "less" with no control named or focused.
    case needsControl
}

/// Applies commands to slider values: [Command] → new EditState + outcomes.
/// Consecutive commands on the same control report as one change ("contrast 20 more" → 0 → 25).
public struct CommandApplier {
    public let registry: ControlRegistry

    public init(registry: ControlRegistry) {
        self.registry = registry
    }

    public func apply(_ commands: [Command], state: inout EditState, focus: inout String?) -> [CommandOutcome] {
        var outcomes: [CommandOutcome] = []
        var run: (control: Control, start: Double)?

        func flush() {
            guard let r = run else { return }
            let end = state.value(of: r.control)
            outcomes.append(end == r.start
                ? .unchanged(controlID: r.control.id, value: end)
                : .changed(controlID: r.control.id, from: r.start, to: end))
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
            if run?.control.id != control.id {
                flush()
                run = (control, state.value(of: control))
            }
            focus = control.id

            let current = state.value(of: control)
            switch command.op {
            case .nudge: state.set(control, to: current + Double(command.steps ?? 0) * control.step)
            case .add: state.set(control, to: current + (command.value ?? 0))
            case .set: state.set(control, to: command.value ?? current)
            case .reset: state.set(control, to: control.defaultValue)
            case .max: state.set(control, to: control.max)
            case .min: state.set(control, to: control.min)
            case .select, .resetAll, .ambiguous, .unknown: break
            }
        }
        flush()
        return outcomes
    }
}
