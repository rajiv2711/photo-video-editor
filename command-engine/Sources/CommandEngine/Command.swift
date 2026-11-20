import Foundation

/// The one command format every parser produces (rules today, a model later) and the applier
/// consumes. It is plain JSON so parsers in any language can be scored against the same tests.
///
///     {"op":"nudge","control":"contrast","steps":3}   "contrast more more more"
///     {"op":"set","control":"exposure","value":0.5}   "exposure 0.5"
///     {"op":"add","control":"contrast","value":20}    "contrast up by 20"
///     {"op":"nudge","steps":1}                        "more"  (no control = the focused one)
///     {"op":"set","control":"hdr","value":1}          "hdr on" (toggles are 0/1)
///     {"op":"run","control":"auto"}                   "auto"  (an action control)
///     {"op":"unknown","word":"vignette"}              anything that isn't a control
public struct Command: Codable, Equatable, CustomStringConvertible {
    public enum Op: String, Codable {
        case nudge, add, set, reset, max, min, select, run
        case resetAll = "reset_all"
        case ambiguous, unknown
    }

    public var op: Op
    /// Control id from controls.json; nil means "the focused control".
    public var control: String?
    public var steps: Int?
    public var value: Double?
    public var word: String?
    public var candidates: [String]?

    public init(op: Op, control: String? = nil, steps: Int? = nil, value: Double? = nil, word: String? = nil, candidates: [String]? = nil) {
        self.op = op
        self.control = control
        self.steps = steps
        self.value = value
        self.word = word
        self.candidates = candidates
    }

    public static func nudge(_ control: String?, _ steps: Int) -> Command { Command(op: .nudge, control: control, steps: steps) }
    public static func add(_ control: String?, _ value: Double) -> Command { Command(op: .add, control: control, value: value) }
    public static func set(_ control: String?, _ value: Double) -> Command { Command(op: .set, control: control, value: value) }
    public static func reset(_ control: String?) -> Command { Command(op: .reset, control: control) }
    public static func max(_ control: String?) -> Command { Command(op: .max, control: control) }
    public static func min(_ control: String?) -> Command { Command(op: .min, control: control) }
    public static func select(_ control: String) -> Command { Command(op: .select, control: control) }
    public static func run(_ control: String) -> Command { Command(op: .run, control: control) }
    public static let resetAll = Command(op: .resetAll)
    public static func ambiguous(_ word: String, _ candidates: [String]) -> Command { Command(op: .ambiguous, word: word, candidates: candidates) }
    public static func unknown(_ word: String) -> Command { Command(op: .unknown, word: word) }

    /// Compact JSON with sorted keys, e.g. {"control":"contrast","op":"nudge","steps":3}.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public var description: String { json }
}
