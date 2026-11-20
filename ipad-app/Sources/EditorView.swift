import CommandEngine
import PhotosUI
import SwiftUI

struct EditorView: View {
    @StateObject private var model = EditorModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var command = ""
    @State private var showSettings = false
    @FocusState private var commandFocused: Bool
    /// Open panels ("light") and sections ("light/Levels").
    @State private var expanded: Set<String> = ["light", "color"]

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

    /// The control panels (Light, Color, …), grouped as in controls.json.
    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.registry.groups, id: \.self) { group in
                    GroupPanel(model: model, group: group, expanded: $expanded)
                }
                Text("Double-tap a name to reset it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(width: 320)
        .background(.regularMaterial)
        .onChange(of: model.focusedControlID) { _, id in
            // Open the panel and section of a control named by voice or typing.
            guard let id, let control = model.registry.control(id: id) else { return }
            expanded.insert(control.group)
            if let section = control.section { expanded.insert(control.group + "/" + section) }
        }
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

/// One panel (Light, Color, …): its plain controls first, then each section as a fold-out.
private struct GroupPanel: View {
    @ObservedObject var model: EditorModel
    let group: String
    @Binding var expanded: Set<String>

    var body: some View {
        let controls = model.registry.controls(inGroup: group)
        DisclosureGroup(isExpanded: isOpen(group)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controls.filter { $0.section == nil }) { control in
                    ControlRow(model: model, control: control)
                }
                ForEach(sections(of: controls), id: \.self) { section in
                    DisclosureGroup(isExpanded: isOpen(group + "/" + section)) {
                        SectionBody(model: model, controls: controls.filter { $0.section == section })
                    } label: {
                        Text(section).font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text(group.prefix(1).uppercased() + group.dropFirst()).font(.headline)
        }
    }

    private func isOpen(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { open in
                if open { expanded.insert(key) } else { expanded.remove(key) }
            }
        )
    }

    private func sections(of controls: [Control]) -> [String] {
        var out: [String] = []
        for control in controls {
            if let section = control.section, !out.contains(section) { out.append(section) }
        }
        return out
    }
}

/// The controls of one section, e.g. "Levels".
private struct SectionBody: View {
    @ObservedObject var model: EditorModel
    let controls: [Control]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(controls) { control in
                ControlRow(model: model, control: control)
            }
        }
    }
}

/// The simplest working control for each kind: slider, switch, picker or button.
private struct ControlRow: View {
    @ObservedObject var model: EditorModel
    let control: Control

    var body: some View {
        switch control.kind {
        case .toggle:
            Toggle(control.label, isOn: Binding(
                get: { model.value(of: control) != 0 },
                set: { model.setFromSlider(control, to: $0 ? 1 : 0) }
            ))
            .padding(10)
        case .action:
            Button(control.label) { model.runAction(control) }
                .buttonStyle(.bordered)
                .padding(.horizontal, 10)
        case .choice:
            Picker(control.label, selection: Binding(
                get: { Int(model.value(of: control)) },
                set: { model.setFromSlider(control, to: Double($0)) }
            )) {
                ForEach(Array(control.options.enumerated()), id: \.offset) { item in
                    Text(item.element.label).tag(item.offset)
                }
            }
            .padding(.horizontal, 10)
        case .slider, .curvePoint:
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
