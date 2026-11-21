import Foundation

/// Rule-based parser: text → [Command]. Stateless: it never looks at slider values or focus,
/// so it can be scored on its own and swapped for a model-based parser later.
///
/// Name-first grammar: a control name opens a clause; the words after it act on that control.
/// Verb-first works at the start ("reset highlights", "more contrast"): words said before the
/// first name belong to it. With no name at all they act on the focused control (`control: nil`).
/// Names may be several words ("tone curve highlights", "red curve 50"); the longest one wins.
/// Toggles take "on"/"off", choices take an option name (after the name, or just before it: "auto
/// upright", "square crop"), actions run when named.
/// Masks: an action may take an option or a number ("linear gradient from top", "delete mask 2"),
/// and "new", "add", "subtract" or "intersect" before a mask part says how it joins the selected
/// mask ("subtract luminance range").
/// Words: an action that takes text (`Control.takesText`) gets everything said after its name, as
/// typed ("new text layer Happy birthday"), or only what is inside quotes right after it, the rest
/// being read as usual ("new text layer “Hi” text size 80").
public struct CommandParser {
    public let registry: ControlRegistry
    private let matcher: NameMatcher

    public init(registry: ControlRegistry) {
        self.registry = registry
        self.matcher = NameMatcher(registry: registry)
    }

    public func parse(_ text: String) -> [Command] {
        if let found = freeText(in: text) {
            return parse(found.before) + [.run(found.control.id, text: found.words)] + parse(found.after)
        }
        return parseWords(text)
    }

    /// The first name of an action that takes words, and its words: everything after the name, or
    /// what is inside quotes right after it (then `after` is the rest). Surrounding spaces and a comma
    /// or colon after the name go; so does one full stop at the end (speech adds one), and a "to"
    /// after Edit Text ("change text to Goodbye").
    func freeText(in text: String) -> (before: String, control: Control, words: String?, after: String)? {
        let tokens = Self.tokenRanges(text)
        for i in tokens.indices {
            for extra in stride(from: Swift.min(3, tokens.count - 1 - i), through: 0, by: -1) {
                guard let control = matcher.exact(tokens[i...(i + extra)].map(\.token).joined(separator: " ")) else { continue }
                // The longest name starting here wins; another control's name is not a place for words.
                guard control.takesText else { break }
                // "text font headline", "export metadata copyright only": an option of the choice just named.
                if optionFollowsName(tokens.map(\.token), at: i) { break }
                let before = String(text[..<tokens[i].range.lowerBound])
                var rest = text[tokens[i + extra].range.upperBound...].drop { $0.isWhitespace || ",:;-–—".contains($0) }
                // "change text to Goodbye": a "to" after a verb-like name isn't part of the new words.
                if control.id == "editText", rest.lowercased().hasPrefix("to "), tokens.count > i + extra + 2 {
                    rest = rest.dropFirst(3).drop { $0.isWhitespace }
                }
                var after = ""
                var words: String
                if let quote = rest.first, "\"“‘'«".contains(quote) {
                    rest = rest.dropFirst()
                    if let close = rest.firstIndex(where: { "\"”’'»".contains($0) }) {
                        words = String(rest[..<close])
                        after = String(rest[rest.index(after: close)...])
                    } else {
                        words = String(rest)
                    }
                } else {
                    words = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                    if words.hasSuffix("."), !words.hasSuffix("..") { words.removeLast() }
                }
                words = words.trimmingCharacters(in: .whitespacesAndNewlines)
                return (before, control, words.isEmpty ? nil : words, after)
            }
        }
        return nil
    }

    /// Whether the words at `i` are an option of the control named just before them (a choice, or an
    /// action with options), so that they are not another action's name.
    private func optionFollowsName(_ tokens: [String], at i: Int) -> Bool {
        for count in 1...3 where i - count >= 0 {
            guard let named = matcher.exact(tokens[(i - count)..<i].joined(separator: " ")), !named.options.isEmpty else { continue }
            for extra in 0...3 where i + extra < tokens.count {
                let phrase = tokens[i...(i + extra)].joined(separator: " ")
                if named.options.contains(where: { $0.names.contains(phrase) }) { return true }
            }
        }
        return false
    }

    /// The words of `text` as `tokenize` makes them, with where each stands in the text.
    static func tokenRanges(_ text: String) -> [(token: String, range: Range<String.Index>)] {
        let separators = CharacterSet(charactersIn: ",!?;:").union(.whitespacesAndNewlines)
        var out: [(token: String, range: Range<String.Index>)] = []
        var start: String.Index?
        var i = text.startIndex
        func close(_ end: String.Index) {
            guard let s = start else { return }
            let token = text[s..<end].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !token.isEmpty { out.append((token, s..<end)) }
            start = nil
        }
        while i < text.endIndex {
            let isSeparator = text[i].unicodeScalars.allSatisfy { separators.contains($0) }
            if isSeparator { close(i) } else if start == nil { start = i }
            i = text.index(after: i)
        }
        close(text.endIndex)
        return out
    }

    /// Parses words with no free text in them.
    private func parseWords(_ text: String) -> [Command] {
        var commands: [Command] = []
        var clause: Clause?
        // After an unrecognised name, ignore actions until a real control is named,
        // so they never land on the wrong slider.
        var blocked = false
        // "turn off hdr": an on/off said before the toggle's name.
        var pendingSwitch: Bool?
        var tokens = Self.tokenize(text)[...]

        func finish() {
            if let c = clause { commands += c.commands() }
            clause = nil
        }

        func begin(_ control: Control, mode: String? = nil) {
            // Verb first: actions said before the very first name belong to it.
            var carried: [Clause.Action] = []
            if let c = clause, !c.named, commands.isEmpty {
                carried = c.actions
                clause = nil
            }
            if control.kind == .toggle, let on = pendingSwitch { carried.append(.set(on ? 1 : 0)) }
            pendingSwitch = nil
            finish()
            clause = Clause(control: control.id, kind: control.kind, named: true, actions: carried, mode: mode)
            blocked = false
        }

        func act(_ action: Clause.Action) {
            if blocked { return }
            if clause == nil { clause = Clause(control: nil, kind: .slider, named: false) }
            clause?.actions.append(action)
        }

        /// The control the current clause names, if any.
        func named() -> Control? {
            clause.flatMap { $0.control }.flatMap { registry.control(id: $0) }
        }

        func reject(_ command: Command) {
            // A stray word right after a name ("contrast a tad more") is just filler.
            if let c = clause, c.named, c.actions.isEmpty { return }
            // "add a vignette": the leading verb was meant for the unknown name, not the focused control.
            if let c = clause, !c.named, commands.isEmpty { clause = nil }
            finish()
            commands.append(command)
            blocked = true
        }

        while let token = tokens.popFirst() {
            if Self.fillers.contains(token) { continue }
            // "aperture f 5.6": an f-number said as "f" then the number.
            if token == "f", let next = tokens.first, Self.number(next) != nil { continue }

            // A choice's option ("white balance cloudy") comes before every other reading:
            // option names may also be words like "auto". Actions may have options too
            // ("radial gradient center").
            if let control = named(), control.kind == .choice, let picked = option(of: control, token, tokens) {
                tokens.removeFirst(picked.extra)
                act(.set(Double(picked.index)))
                continue
            }
            if let control = named(), control.kind == .action, !control.options.isEmpty, clause?.hasOption == false,
               let picked = option(of: control, token, tokens) {
                tokens.removeFirst(picked.extra)
                act(.option(picked.index))
                continue
            }

            // "auto upright", "square crop": a choice's option said just before the choice's name
            // (unless the words make a name of their own: "patch tool").
            if longestName(token, tokens) == nil, let found = optionFirst(token, tokens) {
                tokens.removeFirst(found.used)
                begin(found.control)
                act(.set(Double(found.index)))
                continue
            }

            // "drop shadow", "hide layer", "add rectangle": a name that starts with a word that is
            // otherwise a mask mode, an on/off or a direction is that name.
            if Self.maskMode(token) != nil || Self.switchWord(token) != nil || Self.direction(of: token) != nil,
               let found = longestName(token, tokens) {
                tokens.removeFirst(found.extra)
                begin(found.control)
                continue
            }

            // "subtract luminance range": how a new mask part joins the selected mask.
            if let mode = Self.maskMode(token), let found = maskPart(after: tokens) {
                tokens.removeFirst(found.used)
                begin(found.control, mode: mode)
                continue
            }

            // "on"/"off" switch a toggle ("hdr on"); "off" also turns off a slider that naming turns on
            // ("stroke off", "zoom blur off"); anywhere else they are filler.
            if let on = Self.switchWord(token) {
                if named()?.kind == .toggle {
                    act(.set(on ? 1 : 0))
                } else if !on, let control = named(), control.kind == .slider, control.on != nil {
                    act(.set(control.defaultValue))
                } else {
                    pendingSwitch = on
                }
                continue
            }

            if token == "reset" || token == "default" {
                // "reset crop": a name that starts with the word (unless the words after it make a
                // longer name on their own: "reset crop left" resets Crop Left).
                if let found = longestName(token, tokens),
                   (tokens.first.flatMap { longestName($0, tokens.dropFirst()) }?.extra ?? -1) + 1 <= found.extra {
                    tokens.removeFirst(found.extra)
                    begin(found.control)
                    continue
                }
                // "reset light panel", "reset the effects": a whole panel.
                if let found = panelReset(after: tokens) {
                    tokens.removeFirst(found.used)
                    finish()
                    commands.append(.run(found.control, value: Double(found.index)))
                    continue
                }
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
                if token == "minus", let next = tokens.first, Self.number(next) != nil {
                    tokens.removeFirst()
                    act(.set(-abs(Self.number(next, then: &tokens) ?? 0)))
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

            if let n = Self.number(token, then: &tokens) {
                // "up 20" / "more by 20" is relative; a bare "20" is absolute.
                if !blocked, case .nudge(let sign)? = clause?.actions.last {
                    clause?.actions.removeLast()
                    act(.add(Double(sign) * abs(n)))
                } else {
                    act(.set(n))
                }
                continue
            }

            // Anything else should be a control name, possibly several words ("tone curve highlights").
            if let found = longestName(token, tokens) {
                tokens.removeFirst(found.extra)
                begin(found.control)
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

    /// The control named by `first` plus one to three following words, longest name first.
    /// ("red curve 50" beats "red"; single words go through the fuzzy matcher instead.)
    private func longestName(_ first: String, _ rest: ArraySlice<String>) -> (control: Control, extra: Int)? {
        let words = rest.prefix(3).map { $0.replacingOccurrences(of: "%", with: "") }
        for extra in stride(from: words.count, through: 1, by: -1) {
            if let control = matcher.exact(([first] + words.prefix(extra)).joined(separator: " ")) {
                return (control, extra)
            }
        }
        return nil
    }

    /// A choice control whose option is `first` (plus up to two more words), followed at once by one
    /// of the control's own names (exact): the control, the option's index and the tokens used after `first`.
    private func optionFirst(_ first: String, _ rest: ArraySlice<String>) -> (control: Control, index: Int, used: Int)? {
        let words = Array(rest.prefix(5))
        for control in registry.controls where control.kind == .choice {
            for (index, option) in control.options.enumerated() {
                for name in option.names {
                    let parts = name.split(separator: " ").map(String.init)
                    guard parts.first == first, parts.count - 1 <= words.count, Array(words.prefix(parts.count - 1)) == Array(parts.dropFirst()) else {
                        continue
                    }
                    let after = Array(words.dropFirst(parts.count - 1))
                    for count in stride(from: Swift.min(3, after.count), through: 1, by: -1)
                    where control.names.contains(after.prefix(count).joined(separator: " ")) {
                        return (control, index, parts.count - 1 + count)
                    }
                }
            }
        }
        return nil
    }

    /// A mask part's name right after a mode word, skipping "a", "an", "the" ("add a radial gradient"):
    /// the control and how many tokens it used.
    private func maskPart(after rest: ArraySlice<String>) -> (control: Control, used: Int)? {
        var skipped = 0
        var words = rest
        while let w = words.first, Self.fillers.contains(w) {
            words.removeFirst()
            skipped += 1
        }
        guard let first = words.popFirst() else { return nil }
        let found: (control: Control, extra: Int)?
        if let long = longestName(first, words) {
            found = long
        } else if case .found(let control) = matcher.match(first) {
            found = (control, 0)
        } else {
            found = nil
        }
        guard let found, found.control.kind == .action, found.control.component != nil else { return nil }
        return (found.control, skipped + 1 + found.extra)
    }

    /// A panel named after "reset" (skipping "the"): one of Reset Panel's options, then "panel" (or
    /// "settings"), which may be left out when the panel's word is no control's own name ("reset effects",
    /// but "reset light panel": "light" alone is the Lights curve). The option's index and the tokens used.
    private func panelReset(after rest: ArraySlice<String>) -> (control: String, index: Int, used: Int)? {
        guard let control = registry.control(id: "resetPanel") else { return nil }
        var words = Array(rest)
        var skipped = 0
        while words.first == "the" {
            words.removeFirst()
            skipped += 1
        }
        for count in stride(from: Swift.min(2, words.count), through: 1, by: -1) {
            let phrase = words.prefix(count).joined(separator: " ")
            guard let index = control.options.firstIndex(where: { $0.names.contains(phrase) }) else { continue }
            if let next = words.dropFirst(count).first, ["panel", "settings", "tab"].contains(next) {
                return (control.id, index, skipped + count + 1)
            }
            guard !registry.controls.contains(where: { $0.names.contains(phrase) }),
                  longestName(words[0], ArraySlice(words.dropFirst())) == nil else { return nil }
            return (control.id, index, skipped + count)
        }
        return nil
    }

    /// "new", "add", "subtract", "intersect" before a mask part.
    static func maskMode(_ token: String) -> String? {
        switch token {
        case "new", "create": return "new"
        case "add", "plus": return "add"
        case "subtract": return "subtract"
        case "intersect", "intersection": return "intersect"
        default: return nil
        }
    }

    /// The option of a choice control named by `first` (plus up to three more words), as its index
    /// and the number of extra words used. Near-miss single words count when only one option is close.
    private func option(of control: Control, _ first: String, _ rest: ArraySlice<String>) -> (index: Int, extra: Int)? {
        let words = Array(rest.prefix(3))
        for extra in stride(from: words.count, through: 0, by: -1) {
            let phrase = ([first] + words.prefix(extra)).joined(separator: " ")
            if let index = control.options.firstIndex(where: { $0.names.contains(phrase) }) {
                return (index, extra)
            }
        }
        // Number words for options named by digits: "zoom two hundred" = "zoom 200", "bits eight" = "bits 8".
        var after = rest
        if Self.numberWords[first] != nil, let n = Self.number(first, then: &after) {
            let digits = String(Int(n))
            let used = rest.count - after.count
            let more = Array(after.prefix(2))
            for extra in stride(from: more.count, through: 0, by: -1) {
                let phrase = ([digits] + more.prefix(extra)).joined(separator: " ")
                if let index = control.options.firstIndex(where: { $0.names.contains(phrase) }) {
                    return (index, used + extra)
                }
            }
        }
        let close = control.options.indices.filter { i in
            control.options[i].names.contains { NameMatcher.score(first, against: $0) != nil }
        }
        return close.count == 1 ? (close[0], 0) : nil
    }

    static let fillers: Set<String> = [
        "a", "an", "the", "it", "its", "bit", "little", "some", "please", "and", "then",
        "make", "set", "to", "by", "of", "much", "lot", "slightly", "again", "now", "go",
        "turn", "switch", "from",
        // Units after a number ("long edge 2000 pixels", "resize 50 percent", "straighten 3 degrees").
        "pixels", "px", "percent", "degrees",
    ]

    /// true for "on", false for "off", nil for any other word.
    static func switchWord(_ token: String) -> Bool? {
        switch token {
        case "on", "enable", "enabled", "show": return true
        case "off", "disable", "disabled", "hide": return false
        default: return nil
        }
    }

    static func direction(of token: String) -> Int? {
        switch token {
        case "more", "up", "increase", "higher", "plus", "raise", "add", "boost", "+", "in": return 1
        case "less", "down", "decrease", "lower", "reduce", "minus", "drop", "-", "out": return -1
        default: return nil
        }
    }

    /// Number words, as speech recognition writes small numbers ("exposure one", "contrast twenty").
    static let numberWords: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
    ]

    /// A number from `token`, also taking the next word when two number words make one number
    /// ("twenty five" = 25, "two hundred" = 200).
    static func number(_ token: String, then rest: inout ArraySlice<String>) -> Double? {
        guard var n = number(token) else { return nil }
        if numberWords[token] != nil, let next = rest.first, let more = numberWords[next] {
            if n >= 20, n <= 90, more >= 1, more <= 9 {
                n += more
                rest.removeFirst()
            } else if more == 100, n >= 1, n <= 9 {
                n *= 100
                rest.removeFirst()
            }
        }
        return n
    }

    static func number(_ token: String) -> Double? {
        if let n = numberWords[token] { return n }
        // f-numbers: "f2.8", "f/4".
        if token.hasPrefix("f") {
            let rest = token.hasPrefix("f/") ? token.dropFirst(2) : token.dropFirst()
            guard let first = rest.first, first.isNumber else { return nil }
            return Double(rest)
        }
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
        /// An action's option, by index ("linear gradient from top").
        case option(Int)
    }

    let control: String?
    let kind: Control.Kind
    let named: Bool
    var actions: [Action] = []
    /// Mask parts: "new", "add", "subtract" or "intersect".
    var mode: String?

    /// Whether an option was already said (an action takes one).
    var hasOption: Bool {
        actions.contains { if case .option = $0 { return true } else { return false } }
    }

    /// Consecutive nudges merge into one ("more more less" → steps 1).
    /// A named action always just runs, with its option or a number if one was said;
    /// a bare toggle name turns it on; a bare name selects.
    func commands() -> [Command] {
        if kind == .action, let control {
            var value: Double?
            for case .option(let i) in actions where value == nil { value = Double(i) }
            for case .set(let v) in actions where value == nil { value = v }
            return [value == nil && mode == nil ? .run(control) : .run(control, value: value, mode: mode)]
        }
        if actions.isEmpty {
            guard named, let control else { return [] }
            return kind == .toggle ? [.set(control, 1)] : [.select(control)]
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
            case .option: break
            }
        }
        flush()
        return out
    }
}
