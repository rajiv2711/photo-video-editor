import CoreImage
import EditorCore
import SwiftUI
import UIKit

/// Holds the photo, the slider values and the command interpreter. Sliders and typed commands
/// both change the same `EditState`, so they always agree.
@MainActor
final class EditorModel: ObservableObject {
    struct Feedback: Equatable {
        var text: String
        var choices: [Control] = []
        var isProblem = false
    }

    let registry: ControlRegistry
    @Published private(set) var state = EditState()
    @Published private(set) var preview: UIImage?
    @Published private(set) var feedback: Feedback?
    @Published private(set) var focusedControlID: String?

    private var interpreter: CommandInterpreter
    private var original: CIImage
    private var previewSource: CIImage
    private let renderer = PhotoRenderer()

    init() {
        let registry = (try? ControlRegistry.bundled()) ?? ControlRegistry(controls: [])
        self.registry = registry
        self.interpreter = CommandInterpreter(registry: registry)
        let sample = PhotoRenderer.sample()
        self.original = sample
        self.previewSource = PhotoRenderer.downscaled(sample, maxSide: 2048)
        render()

        // Launch argument used by the cloud build to screenshot a command's effect.
        if let demo = UserDefaults.standard.string(forKey: "demoCommand") {
            run(demo)
        }
    }

    func value(of control: Control) -> Double {
        state.value(of: control)
    }

    func setFromSlider(_ control: Control, to value: Double) {
        state.set(control, to: value)
        focus(control)
        render()
    }

    func reset(_ control: Control) {
        setFromSlider(control, to: control.defaultValue)
    }

    func focus(_ control: Control) {
        interpreter.focus(controlID: control.id)
        focusedControlID = control.id
    }

    func choose(_ control: Control) {
        focus(control)
        feedback = Feedback(text: "\(control.label) selected. Say “more” or “less”.")
    }

    func run(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let outcomes = interpreter.interpret(trimmed, state: &state)
        focusedControlID = interpreter.lastControlID
        feedback = describe(outcomes)
        render()
    }

    func load(_ data: Data) {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            feedback = Feedback(text: "That file couldn't be opened as a photo.", isProblem: true)
            return
        }
        original = image
        previewSource = PhotoRenderer.downscaled(image, maxSide: 2048)
        render()
    }

    /// Renders the full-resolution photo and saves it to the photo library.
    func save() {
        let edited = renderer.apply(to: original) { [state, registry] id in
            registry.control(id: id).map { state.value(of: $0) } ?? 0
        }
        guard let image = renderer.uiImage(edited) else {
            feedback = Feedback(text: "Couldn't render the photo.", isProblem: true)
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        feedback = Feedback(text: "Saved to Photos.")
    }

    private func render() {
        let edited = renderer.apply(to: previewSource) { [state, registry] id in
            registry.control(id: id).map { state.value(of: $0) } ?? 0
        }
        preview = renderer.uiImage(edited)
    }

    private func describe(_ outcomes: [CommandInterpreter.Outcome]) -> Feedback {
        var parts: [String] = []
        var choices: [Control] = []
        var problem = false
        for outcome in outcomes {
            switch outcome {
            case .changed(let id, let from, let to):
                let control = registry.control(id: id)
                parts.append("\(control?.label ?? id) \(Self.format(from, control)) → \(Self.format(to, control))")
            case .unchanged(let id, let value):
                let control = registry.control(id: id)
                parts.append("\(control?.label ?? id) stays at \(Self.format(value, control))")
            case .ambiguous(let word, let ids):
                parts.append("“\(word)” could be:")
                choices += ids.compactMap { registry.control(id: $0) }
            case .unknown(let word):
                parts.append("No control called “\(word)”")
                problem = true
            case .needsControl:
                parts.append("Name a control first, e.g. “contrast more”")
                problem = true
            }
        }
        if parts.isEmpty { parts = ["Nothing to do"] }
        return Feedback(text: parts.joined(separator: " · "), choices: choices, isProblem: problem)
    }

    nonisolated static func format(_ value: Double, _ control: Control?) -> String {
        let decimals = (control?.step ?? 1) < 1 ? 1 : 0
        return String(format: "%.\(decimals)f", value)
    }
}
