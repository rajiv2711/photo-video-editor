import CommandEngine
import Photos
import PhotosUI
import SwiftUI
import UIKit
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
    /// What the last command did shows for a few seconds (`toastHide` hides it).
    @State private var toastShown = false
    @State private var toastHide: Task<Void, Never>?
    /// The screen is wider than tall (measured without the keyboard, so typing never turns the layout).
    @State private var landscape = false

    var body: some View {
        NavigationStack {
            Group {
                if landscape {
                    // The photo, then the panel and its rail at the right edge.
                    HStack(spacing: 0) {
                        photoArea
                        panel
                    }
                } else {
                    // The photo across the whole width, the panel below it (36 % of the height: a tall photo
                    // keeps most of its size, a wide one gets far bigger).
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            photoArea
                            panel
                                .frame(height: (geo.size.height * 0.36).rounded())
                        }
                    }
                }
            }
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { landscape = geo.size.width > geo.size.height }
                    .onChange(of: geo.size) { _, size in landscape = size.width > size.height }
            }.ignoresSafeArea(.keyboard))
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
                    // Export as the Export panel says: to Photos, to Files, or through the share sheet.
                    Menu {
                        Button { model.apply([.run("export")]) } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                        Button { model.apply([.run("saveToFiles")]) } label: { Label("Save to Files", systemImage: "folder") }
                        Button { model.apply([.run("share")]) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        Button { model.apply([.run("print")]) } label: { Label("Print…", systemImage: "printer") }
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    } primaryAction: {
                        model.apply([.run("export")])
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
            .fileExporter(isPresented: Binding(get: { model.fileToSave != nil }, set: { if !$0 { model.fileToSave = nil } }),
                          document: model.fileToSave?.document, contentType: model.fileToSave?.type ?? .jpeg,
                          defaultFilename: model.fileToSave?.name) { result in
                if case .success(let url) = result { model.saved(to: url) }
            }
            .sheet(isPresented: Binding(get: { model.shareFile != nil }, set: { if !$0 { model.shareFile = nil } })) {
                if let url = model.shareFile { ShareSheet(url: url) }
            }
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

    /// The black area with the photo in it. The photo is fitted to the area (16 points in from its edges)
    /// whenever either changes, so after a crop, a turn, a merge or another photo it has the whole room again.
    private var canvas: some View {
        ZStack {
            Color.black
            if let image = model.preview {
                GeometryReader { area in
                    let fitted = Self.fitted(image.size, in: area.size)
                    photo(image)
                        .frame(width: fitted.width, height: fitted.height)
                        .modifier(ZoomPan(model: model, size: fitted))
                        .position(x: area.size.width / 2, y: area.size.height / 2)
                }
                .padding(16)
            }
            // The View panel's scopes, over the top-right corner.
            if let scopes = model.scopes {
                ScopesView(scopes: scopes)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .background(FrameProbe { model.shownFrames.canvas = $0 })
    }

    /// The largest size of a picture's shape that fits in `room`.
    static func fitted(_ picture: CGSize, in room: CGSize) -> CGSize {
        guard picture.width > 0, picture.height > 0, room.width > 0, room.height > 0 else { return .zero }
        let scale = min(room.width / picture.width, room.height / picture.height)
        return CGSize(width: picture.width * scale, height: picture.height * scale)
    }

    /// The photo, as big as the canvas makes it, with the loupe and the tool in use over it (their
    /// touches are read as shares of this size).
    private func photo(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .allowedDynamicRange(model.isHDR ? Image.DynamicRange.high : Image.DynamicRange.standard)
            .background(FrameProbe { model.shownFrames.photo = $0 })
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
    }

    /// The photo with the command bar floating under it (never over the panel) and what a command did
    /// showing for a moment over its top.
    private var photoArea: some View {
        canvas
            .safeAreaInset(edge: .bottom) { commandBar }
            .overlay(alignment: .top) { toast }
            .background(Color.black)
    }

    /// The panel shown (one group of controls.json at a time) and the rail that picks it: a column at the
    /// right edge in landscape (the panel 296 pt wide, 360 with the rail), a strip above the panel in portrait.
    private var panel: some View {
        Group {
            if landscape {
                HStack(spacing: 0) {
                    Divider()
                    panelContent
                        .frame(width: 296)
                    Divider()
                    PanelRail(model: model, vertical: true)
                        .frame(width: 64)
                }
            } else {
                VStack(spacing: 0) {
                    Divider()
                    PanelRail(model: model, vertical: false)
                        .frame(height: 50)
                    Divider()
                    panelContent
                }
            }
        }
        .background(.regularMaterial)
        .onChange(of: model.focusedControlID) { _, id in
            // Open the section of a control named by voice or typing.
            guard let id, let control = model.registry.control(id: id), let section = control.section else { return }
            expanded.insert(control.group + "/" + section)
        }
        // Selecting a mask, a layer or a tool shows its panel.
        .onChange(of: model.state.selectedMask) { _, mask in
            if mask != nil { model.shownPanel = "masks" }
        }
        .onChange(of: model.state.retouchTool) { _, tool in
            if tool != nil { model.shownPanel = "retouch" }
        }
        .onChange(of: model.geometryTool) { _, tool in
            if tool != nil { model.shownPanel = "geometry" }
        }
        .onChange(of: model.state.selectedLayer) { _, layer in
            if layer != nil { model.shownPanel = "layers" }
        }
        .onChange(of: model.revealedPanel) { _, panel in
            // "library/Info": a command asked to see a section of a panel.
            if let panel, panel.contains("/") { expanded.insert(panel) }
        }
    }

    /// The controls of the panel shown, under the editing bar (shown while a mask, layer, tool or picker
    /// takes the touches on the photo; it doesn't scroll away); a new panel starts at its top.
    private var panelContent: some View {
        VStack(spacing: 0) {
            EditingBar(model: model)
            panelScroll
        }
    }

    private var panelScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.panelAvailable(model.shownPanel) {
                    switch model.shownPanel {
                    case "library":
                        LibraryPanel(model: model, expanded: $expanded)
                        // The Camera panel's controls (Pro camera, tethered capture) are where photos come from too.
                        GroupPanel(model: model, group: "camera", expanded: $expanded)
                    case "masks": MasksPanel(model: model, expanded: $expanded)
                    case "retouch": RetouchPanel(model: model, expanded: $expanded)
                    case "geometry": GeometryPanel(model: model, expanded: $expanded)
                    case "merge": MergePanel(model: model, expanded: $expanded)
                    case "layers": LayersPanel(model: model, expanded: $expanded)
                    case "presets": PresetsPanel(model: model, expanded: $expanded)
                    case "history": HistoryPanel(model: model, expanded: $expanded)
                    case "export": ExportPanel(model: model, expanded: $expanded)
                    default: GroupPanel(model: model, group: model.shownPanel, expanded: $expanded)
                    }
                    Text("Double-tap a slider to reset it; tap its value to type one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    selectionNote
                }
            }
            .padding()
        }
        .id(model.shownPanel)
    }

    /// While a mask or an adjustment layer is selected the other panels wait: sliders change it.
    private var selectionNote: some View {
        let mask = model.state.selectedMask
        return VStack(alignment: .leading, spacing: 12) {
            PanelTitle(model: model, title: EditorModel.panelTitle(model.shownPanel), group: model.shownPanel)
            Text(mask.map { "Mask \($0 + 1) is selected: sliders change it, in the Masks panel. Done (above) goes back to the whole photo." }
                 ?? "An adjustment layer is selected: sliders change it, in the Layers panel. Done (above) goes back to the whole photo.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(mask != nil ? "Masks panel" : "Layers panel") { model.shownPanel = mask != nil ? "masks" : "layers" }
                .buttonStyle(.bordered)
        }
    }

    /// The microphone, the text field and Run, in a rounded bar over the bottom of the photo's area.
    private var commandBar: some View {
        HStack(spacing: 10) {
            micButton
            TextField("Say or type: “contrast more”, “exposure 0.5”, “light panel”", text: $command)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($commandFocused)
                .onSubmit(submit)
            Button("Run", action: submit)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .frame(maxWidth: 640)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// What the last command did (and the choices when a word fits several controls), over the top of the
    /// photo for a few seconds; tap it to hide it.
    private var toast: some View {
        VStack {
            if toastShown, let feedback = model.feedback {
                HStack(spacing: 8) {
                    Image(systemName: feedback.isProblem ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(feedback.isProblem ? .orange : .green)
                    Text(feedback.text)
                        .lineLimit(3)
                    ForEach(feedback.choices) { control in
                        Button(control.label) { model.choose(control) }
                            .buttonStyle(.bordered)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: 640)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .onTapGesture { toastShown = false }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: toastShown)
        .onChange(of: model.feedbackCount) { _, _ in showToast() }
        .onChange(of: model.voiceState) { _, _ in showToast() }
        .onAppear { showToast() }
    }

    /// Shows the toast, and hides it after 4 seconds (7 for a problem). It stays while it offers choices
    /// or the mic listens, and in the cloud build's screenshots of a command.
    private func showToast() {
        toastHide?.cancel()
        guard let feedback = model.feedback else {
            toastShown = false
            return
        }
        toastShown = true
        guard feedback.choices.isEmpty, model.voiceState == .idle,
              UserDefaults.standard.string(forKey: "demoCommand") == nil else { return }
        let seconds: Double = feedback.isProblem ? 7 : 4
        toastHide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { toastShown = false }
        }
    }

    /// The microphone: tap to speak a command, tap again when done.
    private var micButton: some View {
        let listening = model.voiceState == .listening
        return Button { model.toggleListening() } label: {
            ZStack {
                Circle().fill(listening ? Color.red : Color.accentColor)
                if model.voiceState == .transcribing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
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
        PanelGroup {
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
            PanelTitle(model: model, title: EditorModel.panelTitle(group), group: group)
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

/// The simplest working control for each kind: slider, switch, picker or button. Rows are compact: the
/// name on the left, the value or switch on the right.
struct ControlRow: View {
    @ObservedObject var model: EditorModel
    let control: Control

    var body: some View {
        switch control.kind {
        case .toggle:
            Toggle(isOn: Binding(
                get: { model.value(of: control) != 0 },
                set: { model.setFromSlider(control, to: $0 ? 1 : 0) }
            )) {
                Text(control.label).font(.subheadline)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
        case .action:
            Button(control.label) { model.runAction(control) }
                .buttonStyle(.bordered)
                .padding(.horizontal, 10)
        case .choice:
            // The name stays visible: a menu picker alone shows only the option chosen.
            HStack {
                Text(control.label).font(.subheadline)
                Spacer(minLength: 8)
                Picker(control.label, selection: Binding(
                    get: { Int(model.value(of: control)) },
                    set: { model.setFromSlider(control, to: Double($0)) }
                )) {
                    ForEach(Array(control.options.enumerated()), id: \.offset) { item in
                        Text(item.element.label).tag(item.offset)
                    }
                }
                .labelsHidden()
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
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

/// A slider in about 50 points: its name and value on one line, the slider under them. Double-tap the
/// row to reset it; tap the value to type an exact number. Dragging across the default taps lightly.
struct SliderRow: View {
    let control: Control
    @Binding var value: Double
    let isFocused: Bool
    let onReset: () -> Void
    /// The finger left the slider (one drag is one history step).
    var onEnd: () -> Void = {}
    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(control.label)
                    .fontWeight(isFocused ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    typed = EditorModel.format(value, control)
                    typing = true
                } label: {
                    Text(EditorModel.format(value, control))
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                .accessibilityLabel("Type a value for \(control.label)")
            }
            .font(.subheadline)
            Slider(value: Binding(get: { value }, set: { moved(to: $0) }), in: control.min...control.max, onEditingChanged: { editing in
                if !editing { onEnd() }
            })
            .frame(height: 26)
            .accessibilityLabel(control.label)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(
            isFocused ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
        .alert(control.label, isPresented: $typing) {
            TextField("Value", text: $typed)
                .keyboardType(.numbersAndPunctuation)
            Button("Set") { setTyped() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From \(EditorModel.format(control.min, control)) to \(EditorModel.format(control.max, control))")
        }
    }

    /// A light tap as the slider crosses its default value.
    private func moved(to new: Double) {
        let d = control.defaultValue
        if (value - d) * (new - d) < 0 || (new == d && value != d) {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        value = new
    }

    /// The number typed, kept within the slider's range ("+20", "-0,5" and "20 %" work too).
    private func setTyped() {
        let text = typed.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }
        guard let number = Double(text) else { return }
        value = min(control.max, max(control.min, number))
        onEnd()
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

/// One panel, shown on its own: its title (with the reset arrow) above its controls.
struct PanelGroup<Content: View, Label: View>: View {
    let content: Content
    let label: Label

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            content
        }
    }
}

/// The panels, an icon each (as Lightroom's tool strip): tap one to show it. Panels that wait while a
/// mask or an adjustment layer is selected are dimmed. Saying a panel's name ("light panel") works too.
struct PanelRail: View {
    @ObservedObject var model: EditorModel
    /// A column beside the panel, or a row above it.
    let vertical: Bool

    var body: some View {
        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            if vertical {
                VStack(spacing: 2) { items }.padding(.vertical, 6)
            } else {
                HStack(spacing: 1) { items }.padding(.horizontal, 6)
            }
        }
    }

    private var items: some View {
        ForEach(EditorModel.panels) { panel in
            let shown = model.shownPanel == panel.group
            let available = model.panelAvailable(panel.group)
            Button {
                model.shownPanel = panel.group
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: panel.symbol)
                        .font(.system(size: 18))
                    Text(panel.title)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: vertical ? 60 : 50, height: vertical ? 42 : 44)
                .foregroundStyle(shown ? Color.accentColor : available ? Color.primary : Color.secondary.opacity(0.5))
                .background(shown ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .accessibilityLabel(panel.title + " panel")
            .accessibilityAddTraits(shown ? .isSelected : [])
        }
    }
}

/// Zoom and pan of the photo on screen (View panel): the picture (with the tools over it, which keep
/// working) is scaled from its top-left corner and moved so the part shown fills its frame. Pinch to
/// zoom; when no tool takes the touches, drag to pan and double-tap to go between fit and 100 %.
struct ZoomPan: ViewModifier {
    @ObservedObject var model: EditorModel
    /// The picture's size on screen when it fits (the canvas works it out from its own size).
    let size: CGSize
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let m = CGFloat(model.magnification)
        let shown = model.visibleRect
        return content
            .scaleEffect(m, anchor: .topLeading)
            .offset(x: -CGFloat(shown.x) * size.width * m, y: -CGFloat(shown.y) * size.height * m)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
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
            .onAppear { fit(size) }
            .onChange(of: size) { _, new in fit(new) }
    }

    /// The model needs the fitted picture's size in pixels (zoom levels are % of the photo's own pixels).
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        model.setFit(pixels: Double(max(size.width, size.height) * displayScale))
    }
}

/// Tells where a view is on screen (points from the window's top-left) whenever it moves or changes size.
struct FrameProbe: View {
    let report: (CGRect) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { report(geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { _, frame in report(frame) }
        }
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
