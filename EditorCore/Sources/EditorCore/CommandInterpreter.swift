import Foundation

/// Turns literal, name-first commands into slider changes:
///
///     "contrast more more more"   → Contrast 0 → 15
///     "contrast 20"               → Contrast set to 20
///     "contrast up by 20"         → Contrast +20
///     "more"                      → repeats on the last control named (or touched)
///     "saturation less exposure more"
///     "contrast reset" · "reset all"
///
/// It deliberately does not guess intent ("make it warmer"): users name the control.
public struct CommandInterpreter {
    public enum Outcome: Equatable {
        case changed(controlID: String, from: Double, to: Double)
        /// The control was named or nudged but its value did not move (e.g. already at max).
        case unchanged(controlID: String, value: Double)
        /// A word matched several controls equally well; the UI should offer them as choices.
        case ambiguous(word: String, candidateIDs: [String])
        case unknown(word: String)
        /// "more" or "less" with no control named yet.
        case needsControl
    }

    public let registry: ControlRegistry
    public private(set) var lastControlID: String?
    private let matcher: NameMatcher

    public init(registry: ControlRegistry) {
        self.registry = registry
        self.matcher = NameMatcher(registry: registry)
    }

    /// Remember a control the user picked by touch, so a following "more" applies to it.
    public mutating func focus(controlID: String) {
        lastControlID = controlID
    }

    public mutating func interpret(_ text: String, state: inout EditState) -> [Outcome] {
        var outcomes: [Outcome] = []
        var clause: Clause?
        // After an unrecognised name, ignore "more"/"less" until a real control is named,
        // so they never land on the wrong slider.
        var blocked = false
        var tokens = Self.tokenize(text)[...]

        func finish() {
            if let c = clause { outcomes.append(c.apply(to: &state)) }
            clause = nil
        }

        func begin(_ control: Control) {
            finish()
            clause = Clause(control: control, start: state.value(of: control))
            lastControlID = control.id
            blocked = false
        }

        func add(_ action: Clause.Action) {
            if blocked { return }
            if clause == nil, let id = lastControlID, let control = registry.control(id: id) {
                clause = Clause(control: control, start: state.value(of: control))
            }
            guard clause != nil else {
                if outcomes.last != .needsControl { outcomes.append(.needsControl) }
                return
            }
            clause?.actions.append(action)
        }

        func reject(_ outcome: Outcome) {
            // A stray word right after a name ("contrast a tad more") is just filler.
            if let c = clause, c.actions.isEmpty { return }
            finish()
            outcomes.append(outcome)
            blocked = true
        }

        while let token = tokens.popFirst() {
            if Self.fillers.contains(token) { continue }

            if token == "reset" || token == "default" {
                if let next = tokens.first, next == "all" || next == "everything" {
                    tokens.removeFirst()
                    finish()
                    outcomes += resetAll(&state)
                } else {
                    add(.reset)
                }
                continue
            }

            if let sign = Self.direction(of: token) {
                // "minus 20" is a negative number, not "less".
                if token == "minus", let next = tokens.first, let n = Self.number(next) {
                    tokens.removeFirst()
                    add(.set(-abs(n)))
                } else {
                    add(.nudge(sign))
                }
                continue
            }

            switch token {
            case "max", "maximum", "full": add(.toMax); continue
            case "min", "minimum": add(.toMin); continue
            default: break
            }

            if let n = Self.number(token) {
                // "up 20" / "more by 20" is relative; a bare "20" is absolute.
                if case .nudge(let sign)? = clause?.actions.last {
                    clause?.actions.removeLast()
                    add(.add(Double(sign) * abs(n)))
                } else {
                    add(.set(n))
                }
                continue
            }

            // Anything else should be a control name, possibly two words ("white balance").
            if let next = tokens.first, let control = matcher.exact(token + " " + next) {
                tokens.removeFirst()
                begin(control)
                continue
            }
            switch matcher.match(token) {
            case .found(let control):
                begin(control)
            case .ambiguous(let candidates):
                reject(.ambiguous(word: token, candidateIDs: candidates.map(\.id)))
            case .none:
                reject(.unknown(word: token))
            }
        }
        finish()
        return outcomes
    }

    private func resetAll(_ state: inout EditState) -> [Outcome] {
        registry.controls.compactMap { control in
            let from = state.value(of: control)
            guard from != control.defaultValue else { return nil }
            let to = state.set(control, to: control.defaultValue)
            return .changed(controlID: control.id, from: from, to: to)
        }
    }

    // MARK: - Parsing helpers

    static let fillers: Set<String> = [
        "a", "an", "the", "it", "its", "bit", "little", "some", "please", "and", "then",
        "make", "set", "to", "by", "of", "much", "lot", "slightly", "again", "now", "go",
    ]

    static func direction(of token: String) -> Int? {
        switch token {
        case "more", "up", "increase", "higher", "plus", "raise", "add", "boost", "+": return 1
        case "less", "down", "decrease", "lower", "reduce", "minus", "drop", "-": return -1
        default: return nil
        }
    }

    static func number(_ token: String) -> Double? {
        if token == "zero" { return 0 }
        return Double(token.replacingOccurrences(of: "%", with: ""))
    }

    /// Lower-cases and splits on spaces and punctuation, keeping decimals like "0.5" whole.
    static func tokenize(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",!?;:").union(.whitespacesAndNewlines)
        return text.lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }
}

/// One control plus the actions said about it, applied in order.
private struct Clause {
    enum Action {
        case nudge(Int)
        case add(Double)
        case set(Double)
        case reset
        case toMax
        case toMin
    }

    let control: Control
    let start: Double
    var actions: [Action] = []

    func apply(to state: inout EditState) -> CommandInterpreter.Outcome {
        var value = start
        for action in actions {
            switch action {
            case .nudge(let sign): value += Double(sign) * control.step
            case .add(let amount): value += amount
            case .set(let target): value = target
            case .reset: value = control.defaultValue
            case .toMax: value = control.max
            case .toMin: value = control.min
            }
            value = control.clamp(value)
        }
        let stored = state.set(control, to: value)
        if stored == start {
            return .unchanged(controlID: control.id, value: stored)
        }
        return .changed(controlID: control.id, from: start, to: stored)
    }
}
