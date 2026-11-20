import CoreImage
import CommandEngine
import Photos
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
    /// A picker tool waiting for a tap on the photo (its control id, e.g. "wbPicker").
    @Published private(set) var armedPicker: String?

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
        installActions()
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
        installActions()
        focusedControlID = nil
        feedback = nil
        armedPicker = nil
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

    /// Action controls look at the photo: Auto reads the unedited preview's brightness histogram
    /// and sets the light sliders (AutoTone in CommandEngine), so its result stays editable.
    private func installActions() {
        let source = previewSource
        let context = renderer.context
        interpreter.actionHandler = { id in
            guard id == "auto" else { return [] }
            let histogram = ImageStats.lumaHistogram(of: source, extent: source.extent, context: context)
            return AutoTone.commands(lumaHistogram: histogram)
        }
    }

    /// A button for an action control (e.g. Auto) was tapped.
    func runAction(_ control: Control) {
        let outcomes = interpreter.apply([.run(control.id)], state: &state)
        focusedControlID = interpreter.lastControlID
        feedback = describe(outcomes)
        armPickers(outcomes)
        render()
    }

    // MARK: - Pickers (tap the photo)

    /// Picker tools and what they ask the user to tap.
    static let pickers: [String: String] = [
        "wbPicker": "Tap something on the photo that should be neutral grey.",
    ]

    /// A picker that ran (by button, voice or typing) now waits for a tap on the photo.
    private func armPickers(_ outcomes: [CommandInterpreter.Outcome]) {
        for case .ran(let id) in outcomes {
            if let hint = Self.pickers[id] {
                armedPicker = id
                feedback = Feedback(text: hint)
            }
        }
    }

    /// The photo was tapped while a picker waited: `x`, `y` from the top-left corner, 0…1.
    func tap(atX x: Double, y: Double) {
        guard let picker = armedPicker else { return }
        armedPicker = nil
        switch picker {
        case "wbPicker":
            // The colour the white balance step sees there (a small square), made neutral.
            let image = renderer.whiteBalanceInput(previewSource, value: currentValue)
            let color = ImageStats.averageColor(of: image, in: Self.spot(x, y, in: image.extent), context: renderer.context)
            let found = WhiteBalance.neutralize(color)
            let outcomes = interpreter.apply([
                .set("whiteBalance", 0),
                .set("temperature", found.temperature.rounded()),
                .set("tint", found.tint.rounded()),
            ], state: &state)
            focusedControlID = interpreter.lastControlID
            feedback = describe(outcomes)
        default:
            break
        }
        render()
    }

    /// A small square (1 % of the long side) around a point given from the top-left, 0…1.
    private static func spot(_ x: Double, _ y: Double, in extent: CGRect) -> CGRect {
        let side = max(3, 0.01 * max(extent.width, extent.height))
        let cx = extent.minX + CGFloat(min(max(x, 0), 1)) * extent.width
        let cy = extent.minY + CGFloat(1 - min(max(y, 0), 1)) * extent.height
        return CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side).intersection(extent)
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
        armPickers(outcomes)
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
        installActions()
        render()
    }

    /// Renders the full-resolution photo and saves it to the photo library.
    /// With HDR on it saves a 10-bit HEIF that keeps the brighter-than-white levels.
    func save() {
        let edited = renderer.apply(to: original, value: currentValue)
        if isHDR {
            saveHDR(edited)
            return
        }
        guard let image = renderer.uiImage(edited) else {
            feedback = Feedback(text: "Couldn't render the photo.", isProblem: true)
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        feedback = Feedback(text: "Saved to Photos.")
    }

    private func saveHDR(_ edited: CIImage) {
        guard let data = renderer.hdrHEIF(edited) else {
            feedback = Feedback(text: "Couldn't render the HDR photo.", isProblem: true)
            return
        }
        // The model lives as long as the app, so these closures may hold it.
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self.feedback = Feedback(text: "Photo library access is off.", isProblem: true)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { ok, _ in
                Task { @MainActor in
                    self.feedback = Feedback(text: ok ? "Saved HDR photo to Photos." : "Couldn't save to Photos.", isProblem: !ok)
                }
            })
        }
    }

    /// Whether the HDR toggle is on (preview and saving keep levels above SDR white).
    var isHDR: Bool {
        registry.control(id: "hdr").map { state.value(of: $0) != 0 } ?? false
    }

    /// The preview photo with the current edits (not yet turned into pixels).
    func editedPreview() -> CIImage {
        renderer.apply(to: previewSource, value: currentValue)
    }

    /// Looks up a control's current value by id; nil when controls.json has no such control.
    private var currentValue: (String) -> Double? {
        { [state, registry] id in
            registry.control(id: id).map { state.value(of: $0) }
        }
    }

    private func render() {
        preview = renderer.uiImage(editedPreview(), hdr: isHDR)
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
            case .ran(let id):
                parts.append(registry.control(id: id)?.label ?? id)
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
        let step = control?.step ?? 1
        let decimals = step < 0.1 ? 2 : step < 1 ? 1 : 0
        return String(format: "%.\(decimals)f", value)
    }
}
