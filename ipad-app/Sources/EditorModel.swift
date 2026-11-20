import CoreImage
import CommandEngine
import SwiftUI
import UIKit

/// Holds the photo, the slider values and the command interpreter. Sliders, typed commands and
/// spoken commands all change the same `EditState`, so they always agree.
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
    @Published private(set) var voiceState: VoiceState = .idle

    enum VoiceState: Equatable {
        case idle, listening, transcribing
    }

    private var interpreter: CommandInterpreter
    private var original: CIImage
    private var previewSource: CIImage
    private let previewSide: CGFloat
    let renderer = PhotoRenderer()
    private let recorder = AudioRecorder()

    /// `image` replaces the bundled test photo (the render gallery passes a small copy);
    /// `previewSide` is the long side of the live preview.
    init(image: CIImage? = nil, previewSide: CGFloat = 2048) {
        let registry = (try? ControlRegistry.bundled()) ?? ControlRegistry(controls: [])
        self.registry = registry
        self.interpreter = CommandInterpreter(registry: registry)
        // Default picture: the committed test photo, or a generated gradient if it's missing.
        let start: CIImage
        if let image {
            start = image
        } else if let url = Bundle.main.url(forResource: "test", withExtension: "jpg"),
                  let photo = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            start = photo
        } else {
            start = PhotoRenderer.sample()
        }
        self.original = start
        self.previewSide = previewSide
        self.previewSource = PhotoRenderer.downscaled(start, maxSide: previewSide)
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

    /// Back to the untouched photo: every control at its default, nothing focused, no feedback.
    func startOver() {
        state = EditState()
        interpreter = CommandInterpreter(registry: registry)
        focusedControlID = nil
        feedback = nil
        render()
    }

    /// Controls that are not at their default, by id (for the render gallery's manifest).
    func changedValues() -> [String: Double] {
        var out: [String: Double] = [:]
        for control in registry.controls where !state.isDefault(control) {
            out[control.id] = state.value(of: control)
        }
        return out
    }

    func focus(_ control: Control) {
        interpreter.focus(controlID: control.id)
        focusedControlID = control.id
    }

    func choose(_ control: Control) {
        focus(control)
        feedback = Feedback(text: "\(control.label) selected. Say “more” or “less”.")
    }

    func run(_ text: String, heard: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let outcomes = interpreter.interpret(trimmed, state: &state)
        focusedControlID = interpreter.lastControlID
        var result = describe(outcomes)
        if heard { result.text = "Heard “\(trimmed)” · " + result.text }
        feedback = result
        render()
    }

    // MARK: - Voice (recorded on the iPad, transcribed by the laptop voice server)

    func toggleListening() {
        switch voiceState {
        case .idle: Task { await startListening() }
        case .listening: Task { await finishListening() }
        case .transcribing: break
        }
    }

    private func startListening() async {
        guard VoiceServerClient.isConfigured else {
            feedback = Feedback(text: VoiceServerClient.ClientError.notConfigured.localizedDescription, isProblem: true)
            return
        }
        do {
            try await recorder.start()
            voiceState = .listening
            feedback = Feedback(text: "Listening… tap the mic again when you're done.")
        } catch {
            feedback = Feedback(text: error.localizedDescription, isProblem: true)
        }
    }

    private func finishListening() async {
        let audio: Data
        do {
            audio = try recorder.stop()
        } catch {
            voiceState = .idle
            feedback = Feedback(text: error.localizedDescription, isProblem: true)
            return
        }
        voiceState = .transcribing
        feedback = Feedback(text: "Transcribing…")
        do {
            let result = try await VoiceServerClient.transcribe(wav: audio)
            voiceState = .idle
            if result.text.isEmpty {
                feedback = Feedback(text: "Didn't catch that. Try again.", isProblem: true)
            } else {
                run(result.text, heard: true)
            }
        } catch {
            voiceState = .idle
            feedback = Feedback(text: error.localizedDescription, isProblem: true)
        }
    }

    func load(_ data: Data) {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            feedback = Feedback(text: "That file couldn't be opened as a photo.", isProblem: true)
            return
        }
        original = image
        previewSource = PhotoRenderer.downscaled(image, maxSide: previewSide)
        render()
    }

    /// Renders the full-resolution photo and saves it to the photo library.
    func save() {
        let edited = renderer.apply(to: original, value: currentValue)
        guard let image = renderer.uiImage(edited) else {
            feedback = Feedback(text: "Couldn't render the photo.", isProblem: true)
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        feedback = Feedback(text: "Saved to Photos.")
    }

    /// The preview photo with the current edits (not yet turned into pixels).
    func editedPreview() -> CIImage {
        renderer.apply(to: previewSource, value: currentValue)
    }

    /// Looks up a control's current value by id; unknown ids read as 0.
    private var currentValue: (String) -> Double {
        { [state, registry] id in
            registry.control(id: id).map { state.value(of: $0) } ?? 0
        }
    }

    private func render() {
        preview = renderer.uiImage(editedPreview())
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
