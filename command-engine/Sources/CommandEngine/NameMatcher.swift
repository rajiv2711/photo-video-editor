import Foundation

/// Finds the control a spoken or typed word refers to, tolerating small mistakes
/// ("contrst", "satur"), synonyms ("vividness" → Saturation) and plurals ("colours" → "colour").
/// A word that fits several controls equally ("colour": Vibrance or Saturation) is ambiguous.
/// Masks-panel names are only tried when no other control is close: they reuse words of the other
/// panels ("color range", "luminance range"), and a near-miss should keep meaning what it meant.
public struct NameMatcher {
    public enum Match: Equatable {
        case found(Control)
        case ambiguous([Control])
        case none
    }

    public let registry: ControlRegistry

    public init(registry: ControlRegistry) {
        self.registry = registry
    }

    /// The one control whose name or synonym is exactly this phrase, if any.
    public func exact(_ phrase: String) -> Control? {
        let phrase = phrase.lowercased()
        let hits = registry.controls.filter { $0.names.contains(phrase) }
        return hits.count == 1 ? hits[0] : nil
    }

    public func match(_ phrase: String) -> Match {
        let phrase = phrase.lowercased()
        guard !phrase.isEmpty else { return .none }

        // Exact name or synonym wins outright.
        let exact = registry.controls.filter { $0.names.contains(phrase) }
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }

        // Otherwise score every control by its closest name; lower is better.
        var best = closest(phrase, among: registry.controls.filter { $0.group != "masks" })
        if best.isEmpty { best = closest(phrase, among: registry.controls.filter { $0.group == "masks" }) }
        switch best.count {
        case 0: return .none
        case 1: return .found(best[0])
        default: return .ambiguous(best)
        }
    }

    /// The controls whose closest name is nearest to the phrase (several when they tie). A plural of
    /// a near-name ("colours" → "colour") reads like the singular.
    private func closest(_ phrase: String, among controls: [Control]) -> [Control] {
        let found = scored(phrase, among: controls)
        if found.isEmpty, phrase.count > 4, phrase.hasSuffix("s") {
            return scored(String(phrase.dropLast()), among: controls)
        }
        return found
    }

    private func scored(_ phrase: String, among controls: [Control]) -> [Control] {
        var best: [(control: Control, score: Int)] = []
        for control in controls {
            guard let score = control.names.compactMap({ Self.score(phrase, against: $0) }).min() else { continue }
            if let current = best.first?.score {
                if score < current { best = [(control, score)] } else if score == current { best.append((control, score)) }
            } else {
                best = [(control, score)]
            }
        }
        return best.map(\.control)
    }

    /// Edit distance between a phrase and a name, or nil when they are too far apart to be a
    /// plausible slip. A prefix of four or more letters ("contr") also counts as a close match.
    static func score(_ phrase: String, against name: String) -> Int? {
        if phrase.count >= 4 && name.hasPrefix(phrase) { return 1 }
        let allowed: Int
        switch name.count {
        case ..<4: allowed = 0
        case 4...5: allowed = 1
        default: allowed = 2
        }
        let distance = levenshtein(phrase, name)
        return distance <= allowed ? distance : nil
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
