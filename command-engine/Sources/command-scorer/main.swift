// Scores the rule parser against a JSONL test set and writes a JSON result file for the report.
//
//   swift run --package-path command-engine command-scorer test-data/phrases/commands.jsonl --out reports/parser/results.json
//
// Each test-set line: {"group": "...", "text": "...", "expect": [Command...], "focus": "contrast"?}
// "focus" is only used to compute the slider values after the command (for the visuals);
// parsing itself is stateless.
import CommandEngine
import Foundation

struct TestCase: Codable {
    let group: String
    let text: String
    let expect: [Command]
    let focus: String?
}

struct CaseResult: Codable {
    let group: String
    let text: String
    let focus: String?
    let expect: [Command]
    let actual: [Command]
    let pass: Bool
    let values: [String: Double]
    let outcomes: [String]
}

struct GroupScore: Codable {
    let name: String
    let passed: Int
    let total: Int
}

struct Report: Codable {
    let parser: String
    let testSet: String
    let passed: Int
    let total: Int
    let groups: [GroupScore]
    let controls: [Control]
    let cases: [CaseResult]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var outPath: String?
if let i = args.firstIndex(of: "--out") {
    guard i + 1 < args.count else { fail("--out needs a path") }
    outPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let inputPath = args.first ?? "test-data/phrases/commands.jsonl"

guard let raw = try? String(contentsOfFile: inputPath, encoding: .utf8) else { fail("Can't read \(inputPath)") }
let decoder = JSONDecoder()
var cases: [TestCase] = []
for (n, line) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
    do {
        cases.append(try decoder.decode(TestCase.self, from: Data(trimmed.utf8)))
    } catch {
        fail("\(inputPath):\(n + 1): \(error)")
    }
}

let registry: ControlRegistry
do { registry = try ControlRegistry.bundled() } catch { fail("Can't load controls.json: \(error)") }
let parser = CommandParser(registry: registry)
let applier = CommandApplier(registry: registry)

func describe(_ outcome: CommandOutcome) -> String {
    switch outcome {
    case .changed(let id, let from, let to): return "\(id) \(from) → \(to)"
    case .ran(let id): return "ran \(id)"
    case .unchanged(let id, let value): return "\(id) stays \(value)"
    case .ambiguous(let word, let ids): return "“\(word)” could be \(ids.joined(separator: "/"))"
    case .unknown(let word): return "unknown “\(word)”"
    case .needsControl: return "needs a control"
    case .changedInMask(let mask, let id, let from, let to): return "mask \(mask) \(id) \(from) → \(to)"
    case .masked(let mask, let event): return "mask \(mask): \(event)"
    case .needsMask(let id): return "\(id) needs a mask"
    }
}

var results: [CaseResult] = []
for c in cases {
    let actual = parser.parse(c.text)
    var state = EditState()
    var focus = c.focus
    let outcomes = applier.apply(actual, state: &state, focus: &focus)
    let values = Dictionary(uniqueKeysWithValues: registry.controls.map { ($0.id, state.value(of: $0)) })
    results.append(CaseResult(
        group: c.group, text: c.text, focus: c.focus, expect: c.expect, actual: actual,
        pass: actual == c.expect, values: values, outcomes: outcomes.map(describe)
    ))
}

var order: [String] = []
for r in results where !order.contains(r.group) { order.append(r.group) }
let groups = order.map { name in
    let rs = results.filter { $0.group == name }
    return GroupScore(name: name, passed: rs.filter(\.pass).count, total: rs.count)
}
let passed = results.filter(\.pass).count

// Console summary
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }
print("Rule parser · \(inputPath)")
for g in groups {
    print("  \(g.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(g.passed)/\(g.total)  \(pct(g.passed, g.total))")
}
print("  \("TOTAL".padding(toLength: 14, withPad: " ", startingAt: 0)) \(passed)/\(results.count)  \(pct(passed, results.count))")
let failures = results.filter { !$0.pass }
if !failures.isEmpty {
    print("\nFailures:")
    for f in failures {
        print("  [\(f.group)] \"\(f.text)\"")
        print("      expected \(f.expect.map(\.json).joined(separator: " "))")
        print("      got      \(f.actual.map(\.json).joined(separator: " "))")
    }
}

if let outPath {
    let report = Report(parser: "rules", testSet: inputPath, passed: passed, total: results.count,
                        groups: groups, controls: registry.controls, cases: results)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        let url = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: url)
        print("\nWrote \(outPath)")
    } catch {
        fail("Can't write \(outPath): \(error)")
    }
}
