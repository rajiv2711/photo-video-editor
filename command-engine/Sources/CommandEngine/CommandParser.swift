import Foundation

/// Rule-based parser: text → [Command]. Stateless: it never looks at slider values or focus,
/// so it can be scored on its own and swapped for a model-based parser later.
///
/// Name-first grammar: a control name opens a clause; the words after it act on that control.
/// Actions said before any name act on the focused control (`control: nil`).
public struct CommandParser {
    public let registry: ControlRegistry
    private let matcher: NameMatcher

    public init(registry: ControlRegistry) {
        self.registry = registry
        self.matcher = NameMatcher(registry: registry)
    }

    public func parse(_ text: String) -> [Command] {
        var commands: [Command] = []
        var clause: Clause?
        // After an unrecognised name, ignore actions until a real control is named,
        // so they never land on the wrong slider.
        var blocked = false
        var tokens = Self.tokenize(text)[...]

        func finish() {
            if let c = clause { commands += c.commands() }
            clause = nil
        }

        func begin(_ control: Control) {
            finish()
            clause = Clause(control: control.id, named: true)
            blocked = false
        }

        func act(_ action: Clause.Action) {
            if blocked { return }
            if clause == nil { clause = Clause(control: nil, named: false) }
            clause?.actions.append(action)
        }

        func reject(_ command: Command) {
            // A stray word right after a name ("contrast a tad more") is just filler.
            if let c = clause, c.named, c.actions.isEmpty { return }
            finish()
            commands.append(command)
            blocked = true
        }

        while let token = tokens.popFirst() {
            if Self.fillers.contains(token) { continue }

            if token == "reset" || token == "default" {
                if let next = tokens.first, next == "all" || next == "everything" {
                    tokens.removeFirst()
                    finish()
                    commands.append(.resetAll)
                } else {
                    act(.reset)
                }
                continue
            }

            if let sign = Self.direction(of: token) {
                // "minus 20" is a negative number, not "less".
                if token == "minus", let next = tokens.first, let n = Self.number(next) {
                    tokens.removeFirst()
                    act(.set(-abs(n)))
                } else {
                    act(.nudge(sign))
                }
                continue
            }

            switch token {
            case "max", "maximum", "full": act(.toMax); continue
            case "min", "minimum": act(.toMin); continue
            default: break
            }

            if let n = Self.number(token) {
                // "up 20" / "more by 20" is relative; a bare "20" is absolute.
                if !blocked, case .nudge(let sign)? = clause?.actions.last {
                    clause?.actions.removeLast()
                    act(.add(Double(sign) * abs(n)))
                } else {
                    act(.set(n))
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
                reject(.ambiguous(token, candidates.map(\.id)))
            case .none:
                reject(.unknown(token))
            }
        }
        finish()
        return commands
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

/// One control (or the focused one) plus the actions said about it.
private struct Clause {
    enum Action {
        case nudge(Int)
        case add(Double)
        case set(Double)
        case reset
        case toMax
        case toMin
    }

    let control: String?
    let named: Bool
    var actions: [Action] = []

    /// Consecutive nudges merge into one ("more more less" → steps 1).
    func commands() -> [Command] {
        if actions.isEmpty {
            return named ? [.select(control!)] : []
        }
        var out: [Command] = []
        var pendingSteps: Int?
        func flush() {
            if let s = pendingSteps { out.append(.nudge(control, s)) }
            pendingSteps = nil
        }
        for action in actions {
            switch action {
            case .nudge(let sign): pendingSteps = (pendingSteps ?? 0) + sign
            case .add(let v): flush(); out.append(.add(control, v))
            case .set(let v): flush(); out.append(.set(control, v))
            case .reset: flush(); out.append(.reset(control))
            case .toMax: flush(); out.append(.max(control))
            case .toMin: flush(); out.append(.min(control))
            }
        }
        flush()
        return out
    }
}
