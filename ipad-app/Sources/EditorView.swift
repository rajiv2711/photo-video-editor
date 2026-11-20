import CommandEngine
import PhotosUI
import SwiftUI

struct EditorView: View {
    @StateObject private var model = EditorModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var command = ""
    @State private var showSettings = false
    @FocusState private var commandFocused: Bool

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                canvas
                panel
            }
            .safeAreaInset(edge: .bottom) { commandBar }
            .navigationTitle("Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Open Photo", systemImage: "photo.on.rectangle")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button("Reset All") { model.run("reset all") }
                    Button { model.save() } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { @MainActor in
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        model.load(data)
                    }
                }
            }
        }
    }

    private var canvas: some View {
        ZStack {
            Color.black
            if let image = model.preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            }
        }
    }

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Adjust")
                    .font(.headline)
                ForEach(model.registry.controls) { control in
                    SliderRow(
                        control: control,
                        value: Binding(
                            get: { model.value(of: control) },
                            set: { model.setFromSlider(control, to: $0) }
                        ),
                        isFocused: model.focusedControlID == control.id,
                        onReset: { model.reset(control) }
                    )
                }
                Text("Double-tap a name to reset it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(width: 320)
        .background(.regularMaterial)
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let feedback = model.feedback {
                HStack(spacing: 8) {
                    Image(systemName: feedback.isProblem ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(feedback.isProblem ? .orange : .green)
                    Text(feedback.text)
                    ForEach(feedback.choices) { control in
                        Button(control.label) { model.choose(control) }
                            .buttonStyle(.bordered)
                    }
                }
                .font(.callout)
            }
            HStack(spacing: 10) {
                micButton
                TextField("Tap the mic, or type: “contrast more more”, “exposure 0.5”, “reset all”", text: $command)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($commandFocused)
                    .onSubmit(submit)
                Button("Run", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding()
    }

    private var micButton: some View {
        let listening = model.voiceState == .listening
        return Button { model.toggleListening() } label: {
            if model.voiceState == .transcribing {
                ProgressView().frame(width: 32, height: 32)
            } else {
                Image(systemName: listening ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(listening ? Color.red : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.voiceState == .transcribing)
        .accessibilityLabel(listening ? "Stop listening" : "Speak a command")
    }

    private func submit() {
        model.run(command)
        command = ""
        commandFocused = true
    }
}

private struct SliderRow: View {
    let control: Control
    @Binding var value: Double
    let isFocused: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(control.label)
                    .fontWeight(isFocused ? .semibold : .regular)
                    .onTapGesture(count: 2, perform: onReset)
                Spacer()
                Text(EditorModel.format(value, control))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: control.min...control.max)
        }
        .padding(10)
        .background(
            isFocused ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}
