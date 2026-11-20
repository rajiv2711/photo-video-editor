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
                    .allowedDynamicRange(model.isHDR ? Image.DynamicRange.high : Image.DynamicRange.standard)
                    .scaledToFit()
                    .overlay {
                        // A picker tool (e.g. white balance) waits for a tap on the photo.
                        if model.armedPicker != nil {
                            GeometryReader { geo in
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { location in
                                        model.tap(atX: location.x / geo.size.width, y: location.y / geo.size.height)
                                    }
                            }
                            .border(Color.accentColor, width: 2)
                        }
                    }
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

/// The controls of one section, e.g. "Levels"; curve points get the curve editor.
private struct SectionBody: View {
    @ObservedObject var model: EditorModel
    let controls: [Control]

    var body: some View {
        if controls.allSatisfy({ $0.kind == .curvePoint }) {
            CurveEditor(model: model, controls: controls)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controls) { control in
                    ControlRow(model: model, control: control)
                }
            }
        }
    }
}

/// Point curve editor: one curve per channel through five points at fixed inputs (0, 25, 50, 75,
/// 100 %). Drag up or down anywhere above a point to move it. The curve is drawn with the same
/// spline the renderer uses (ToneCurve.spline).
private struct CurveEditor: View {
    @ObservedObject var model: EditorModel
    let controls: [Control]
    @State private var channel = "rgb"

    private var channels: [String] {
        var out: [String] = []
        for control in controls {
            if let c = control.channel, !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// The current channel's points, left to right.
    private var points: [Control] {
        controls.filter { $0.channel == channel }.sorted { ($0.x ?? 0) < ($1.x ?? 0) }
    }

    private var color: Color {
        switch channel {
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        default: return .white
        }
    }

    private static func title(_ channel: String) -> String {
        channel == "rgb" ? "RGB" : channel.capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Channel", selection: $channel) {
                ForEach(channels, id: \.self) { c in
                    Text(Self.title(c)).tag(c)
                }
            }
            .pickerStyle(.segmented)
            GeometryReader { geo in
                canvas(size: geo.size)
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            Button("Reset \(Self.title(channel)) curve") {
                for point in points { model.reset(point) }
            }
            .font(.footnote)
        }
        .padding(.horizontal, 10)
        .onAppear { showFocusedChannel(model.focusedControlID) }
        .onChange(of: model.focusedControlID) { _, id in showFocusedChannel(id) }
    }

    /// "red curve 75 up" switches the editor to the Red channel.
    private func showFocusedChannel(_ id: String?) {
        if let c = controls.first(where: { $0.id == id })?.channel { channel = c }
    }

    private func canvas(size: CGSize) -> some View {
        let pts = points
        let xs = pts.map { ($0.x ?? 0) / 100 }
        let ys = pts.map { model.value(of: $0) / 100 }
        func spot(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: CGFloat(x) * size.width, y: CGFloat(1 - y) * size.height)
        }
        return ZStack {
            Path { path in
                for i in 1...3 {
                    let f = Double(i) / 4
                    path.move(to: spot(f, 0))
                    path.addLine(to: spot(f, 1))
                    path.move(to: spot(0, f))
                    path.addLine(to: spot(1, f))
                }
            }
            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            Path { path in
                for i in 0...64 {
                    let x = Double(i) / 64
                    let y = xs.count > 1 ? ToneCurve.spline(xs: xs, ys: ys, at: x) : x
                    if i == 0 { path.move(to: spot(x, y)) } else { path.addLine(to: spot(x, y)) }
                }
            }
            .stroke(color, lineWidth: 2)
            ForEach(pts) { point in
                Circle()
                    .fill(model.focusedControlID == point.id ? Color.accentColor : color)
                    .frame(width: 14, height: 14)
                    .position(spot((point.x ?? 0) / 100, model.value(of: point) / 100))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { drag in
                guard !pts.isEmpty, size.width > 0, size.height > 0 else { return }
                // The point nearest to where the finger went down follows its height.
                let start = Double(drag.startLocation.x / size.width) * 100
                guard let nearest = pts.min(by: { abs(($0.x ?? 0) - start) < abs(($1.x ?? 0) - start) }) else { return }
                let level = Double(1 - drag.location.y / size.height) * 100
                model.setFromSlider(nearest, to: min(100, max(0, level)))
            }
        )
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
