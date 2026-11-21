import CommandEngine
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @StateObject private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickerItem: PhotosPickerItem?
    /// Photos picked with Import Photos (the Library panel's button, or said).
    @State private var importItems: [PhotosPickerItem] = []
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
                    // The original file (.current), so a Portrait photo keeps its depth map; it joins the library.
                    PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                        Label("Open Photo", systemImage: "photo.on.rectangle")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    // Held down: the photo before its edit.
                    Image(systemName: "rectangle.lefthalf.filled")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Hold to see the photo before its edit")
                        .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}, onPressingChanged: { model.holdBefore($0) })
                    Button { model.apply([.run("undo")]) } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!model.canUndo)
                    Button { model.apply([.run("redo")]) } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!model.canRedo)
                    Button("Reset All") { model.run("reset all") }
                    Button { model.save() } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                importPicked([item])
            }
            // Import Photos, Import Files, Import From Camera (said or tapped in the Library panel).
            .photosPicker(isPresented: importer("photos"), selection: $importItems, selectionBehavior: .ordered, matching: .images,
                          preferredItemEncoding: .current, photoLibrary: .shared())
            .onChange(of: importItems) { _, picked in
                importPicked(picked)
                importItems = []
            }
            .fileImporter(isPresented: importer("files"), allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.importFiles(urls) }
            }
            .sheet(isPresented: importer("camera")) {
                CameraImportView(importer: model.cameras) { urls in model.importFiles(urls) }
            }
            .sheet(isPresented: $model.showsMap) { LibraryMapView(model: model) }
            .fullScreenCover(isPresented: $model.showsCamera) { ProCameraView(model: model, camera: model.proCamera) }
            .onChange(of: scenePhase) { _, phase in
                // The edit of the photo being edited is kept with it in the library.
                if phase != .active { model.saveLibrary() }
            }
        }
    }

    /// Whether the picker an import asked for is showing.
    private func importer(_ kind: String) -> Binding<Bool> {
        Binding(get: { model.importer == kind }, set: { if !$0, model.importer == kind { model.importer = nil } })
    }

    /// Photos picked in Photos: they join the library (as references to Photos when the app may read the
    /// library, else as copies) and the first one opens.
    private func importPicked(_ picked: [PhotosPickerItem]) {
        guard !picked.isEmpty else { return }
        Task { @MainActor in
            let reference = await LibraryStore.mayReferenceAssets()
            var items: [LibraryImport] = []
            for item in picked {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let asset = reference ? item.itemIdentifier : nil
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let name = asset.flatMap { LibraryStore.assetName($0) } ?? "Photo.\(ext)"
                items.append(LibraryImport(data: data, name: name, asset: asset))
            }
            model.importPictures(items)
            // A Live Photo: its video for the Live Photo effects (Merge panel).
            if picked.count == 1, let live = try? await picked[0].loadTransferable(type: PHLivePhoto.self) {
                await model.openLive(live)
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
                        // Zoomed in past the preview's own pixels: the part shown, rendered from the full-size photo.
                        GeometryReader { geo in
                            if let loupe = model.loupe {
                                Image(uiImage: loupe.image)
                                    .resizable()
                                    .frame(width: CGFloat(loupe.rect.width) * geo.size.width, height: CGFloat(loupe.rect.height) * geo.size.height)
                                    .position(x: CGFloat(loupe.rect.x + loupe.rect.width / 2) * geo.size.width,
                                              y: CGFloat(loupe.rect.y + loupe.rect.height / 2) * geo.size.height)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .overlay {
                        if model.isComparing {
                            // Before / after: nothing to touch.
                            EmptyView()
                        } else if model.armedPicker != nil {
                            // A picker tool (e.g. white balance) waits for a tap on the photo.
                            GeometryReader { geo in
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { location in
                                        model.tap(atX: location.x / geo.size.width, y: location.y / geo.size.height)
                                    }
                            }
                            .border(Color.accentColor, width: 2)
                        } else if model.targetedMode != nil {
                            // Targeted adjustment: drag up or down on a tone or colour.
                            TargetedCanvas(model: model)
                        } else if let tool = model.geometryTool {
                            // The Geometry panel's tool (the crop box, …) takes the touches.
                            GeometryCanvas(model: model, tool: tool)
                        } else if let tool = model.retouchTool {
                            // The retouch tool in use paints or taps on the photo.
                            RetouchCanvasView(model: model, tool: tool)
                        } else if let tool = model.canvasTool {
                            // The selected mask part is drawn on the photo (brush strokes, shapes, taps).
                            MaskCanvas(model: model, tool: tool)
                        } else if let tool = model.layerCanvasTool {
                            // The selected layer is moved (or drawn on) on the picture.
                            LayerCanvas(model: model, tool: tool)
                        }
                    }
                    .modifier(ZoomPan(model: model))
                    .padding(24)
            }
            // The View panel's scopes, over the top-right corner.
            if let scopes = model.scopes {
                ScopesView(scopes: scopes)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    /// The control panels (Light, Color, …), grouped as in controls.json.
    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // The library first: where photos come from.
                LibraryPanel(model: model, expanded: $expanded)
                ForEach(model.registry.groups, id: \.self) { group in
                    if group == "library" {
                        EmptyView()  // shown above
                    } else if group == "masks" {
                        MasksPanel(model: model, expanded: $expanded)
                    } else if group == "retouch", model.state.selectedMask == nil, !model.adjustmentLayerSelected {
                        RetouchPanel(model: model, expanded: $expanded)
                    } else if group == "geometry", model.state.selectedMask == nil, !model.adjustmentLayerSelected {
                        GeometryPanel(model: model, expanded: $expanded)
                    } else if group == "merge", model.state.selectedMask == nil, !model.adjustmentLayerSelected {
                        MergePanel(model: model, expanded: $expanded)
                    } else if group == "layers", model.state.selectedMask == nil {
                        LayersPanel(model: model, expanded: $expanded)
                    } else if group == "presets", model.state.selectedMask == nil, !model.adjustmentLayerSelected {
                        PresetsPanel(model: model, expanded: $expanded)
                    } else if group == "history" {
                        HistoryPanel(model: model, expanded: $expanded)
                    } else if model.state.selectedMask == nil, !model.adjustmentLayerSelected {
                        // While a mask or an adjustment layer is selected only its panel shows: its sliders are local.
                        GroupPanel(model: model, group: group, expanded: $expanded)
                    }
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
        .onChange(of: model.state.selectedMask) { _, mask in
            if mask != nil { expanded.insert("masks") }
        }
        .onChange(of: model.state.retouchTool) { _, tool in
            if tool != nil { expanded.insert("retouch") }
        }
        .onChange(of: model.geometryTool) { _, tool in
            if tool != nil { expanded.insert("geometry") }
        }
        .onChange(of: model.state.selectedLayer) { _, layer in
            if layer != nil { expanded.insert("layers") }
        }
        .onChange(of: model.revealedPanel) { _, panel in
            // "history", "presets": a command asked to see a panel ("library/Info": a section of one).
            if let panel {
                expanded.insert(panel)
                if let slash = panel.firstIndex(of: "/") { expanded.insert(String(panel[..<slash])) }
            }
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
            PanelTitle(model: model, title: group.prefix(1).uppercased() + group.dropFirst(), group: group)
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
        } else if let tabs = TabbedSection.tabs[controls.first?.section ?? ""] {
            TabbedSection(model: model, controls: controls, byFirstWord: tabs.byFirstWord, segmented: tabs.segmented)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controls) { control in
                    ControlRow(model: model, control: control)
                }
            }
        }
    }
}

/// A section with many sliders, shown one group at a time: Color mixer by Hue / Saturation /
/// Luminance, Channel mixer by output channel, Selective color by colour family. The group comes
/// from the label's first or last word ("Reds Cyan" → Reds); naming a slider by voice opens its group.
private struct TabbedSection: View {
    @ObservedObject var model: EditorModel
    let controls: [Control]
    let byFirstWord: Bool
    let segmented: Bool
    @State private var tab = ""

    /// Sections shown this way, and how their sliders are grouped.
    static let tabs: [String: (byFirstWord: Bool, segmented: Bool)] = [
        "Color mixer": (false, true),
        "Channel mixer": (true, true),
        "Selective color": (true, false),
    ]

    private func group(of control: Control) -> String {
        let words = control.label.split(separator: " ")
        return String((byFirstWord ? words.first : words.last) ?? "")
    }

    private var groups: [String] {
        var out: [String] = []
        for control in controls where !out.contains(group(of: control)) { out.append(group(of: control)) }
        return out
    }

    private var current: String { tab.isEmpty ? (groups.first ?? "") : tab }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Group", selection: Binding(get: { current }, set: { tab = $0 })) {
                ForEach(groups, id: \.self) { Text($0).tag($0) }
            }
            .modifier(PickerLook(segmented: segmented))
            .padding(.horizontal, 10)
            ForEach(controls.filter { group(of: $0) == current }) { control in
                ControlRow(model: model, control: control)
            }
        }
        .onAppear { follow(model.focusedControlID) }
        .onChange(of: model.focusedControlID) { _, id in follow(id) }
    }

    /// "blues cyan 20" switches to the Blues group.
    private func follow(_ id: String?) {
        if let control = controls.first(where: { $0.id == id }) { tab = group(of: control) }
    }
}

/// Segmented for a few groups, a menu for many.
private struct PickerLook: ViewModifier {
    let segmented: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if segmented {
            content.pickerStyle(.segmented)
        } else {
            content.pickerStyle(.menu)
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
struct ControlRow: View {
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
                onReset: { model.reset(control) },
                onEnd: { model.endSliderDrag() }
            )
        }
    }
}

struct SliderRow: View {
    let control: Control
    @Binding var value: Double
    let isFocused: Bool
    let onReset: () -> Void
    /// The finger left the slider (one drag is one history step).
    var onEnd: () -> Void = {}

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
            Slider(value: $value, in: control.min...control.max, onEditingChanged: { editing in
                if !editing { onEnd() }
            })
        }
        .padding(10)
        .background(
            isFocused ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}

/// A panel's title, with a button that resets the whole panel ("reset light panel") when it can be.
struct PanelTitle: View {
    @ObservedObject var model: EditorModel
    let title: String
    let group: String

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let reset = model.registry.control(id: "resetPanel"), let i = reset.options.firstIndex(where: { $0.id == group }) {
                Button {
                    model.apply([.run(reset.id, value: Double(i))])
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset the \(title) panel")
            }
        }
    }
}

/// Zoom and pan of the photo on screen (View panel): the picture (with the tools over it, which keep
/// working) is scaled from its top-left corner and moved so the part shown fills its frame. Pinch to
/// zoom; when no tool takes the touches, drag to pan and double-tap to go between fit and 100 %.
struct ZoomPan: ViewModifier {
    @ObservedObject var model: EditorModel
    @State private var size: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let m = CGFloat(model.magnification)
        let shown = model.visibleRect
        return content
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { measured(geo.size) }
                    .onChange(of: geo.size) { _, new in measured(new) }
            })
            .scaleEffect(m, anchor: .topLeading)
            .offset(x: -CGFloat(shown.x) * size.width * m, y: -CGFloat(shown.y) * size.height * m)
            .frame(width: size.width > 0 ? size.width : nil, height: size.height > 0 ? size.height : nil, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(MagnifyGesture()
                .onChanged { model.pinch(Double($0.magnification)) }
                .onEnded { _ in model.endPinch() })
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { model.pan(by: $0.translation, in: size) }
                .onEnded { _ in model.endPan() }, including: model.canPan ? .all : .none)
            .simultaneousGesture(SpatialTapGesture(count: 2)
                .onEnded { tap in
                    guard size.width > 0, size.height > 0 else { return }
                    model.toggleLoupe(at: MaskPoint(Double(tap.location.x / size.width), Double(tap.location.y / size.height)))
                }, including: model.touchesFree ? .all : .none)
    }

    /// The picture's frame when it fits: the model needs its size in pixels.
    private func measured(_ new: CGSize) {
        size = new
        model.setFit(pixels: Double(max(new.width, new.height) * displayScale))
    }
}

/// Targeted adjustment: a drag up or down on the photo changes the controls acting on the tone or
/// colour where it began (the View panel's Targeted Adjustment mode).
struct TargetedCanvas: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        model.draw([MaskCanvas.unit(drag.startLocation, in: geo.size), MaskCanvas.unit(drag.location, in: geo.size)], finished: false)
                    }
                    .onEnded { drag in
                        model.draw([MaskCanvas.unit(drag.startLocation, in: geo.size), MaskCanvas.unit(drag.location, in: geo.size)])
                    })
        }
        .border(Color.accentColor.opacity(0.6), width: 2)
    }
}
