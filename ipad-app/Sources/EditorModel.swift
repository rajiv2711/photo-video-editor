import CoreImage
import CommandEngine
import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    /// The Geometry panel's touch tool in use ("crop", …; see GeometryTools), or nil.
    @Published private(set) var geometryTool: String?
    /// The geometry of the shown preview: touches on it map back to the photo through it.
    @Published private(set) var previewPlan: GeometryPlan?
    /// What touches do to the selected layer: "move" (drag it), … (see `layerCanvasTool`).
    @Published private(set) var layerMode = "move"
    /// A panel a command asked to see ("history" alone opens the History panel).
    @Published private(set) var revealedPanel: String?
    /// The panel shown, one at a time ("light", "masks", …: a group of controls.json, or "library", which
    /// also holds the Camera panel's controls). The rail, a panel's name ("light panel") and what a command
    /// selects or names choose it.
    @Published var shownPanel = "light"
    /// The scopes of the preview as shown (View panel), while one is on.
    @Published private(set) var scopes: ScopeReadings?
    /// Colour samplers: points on the shown picture (0…1 from the top-left), oldest first.
    @Published private(set) var samplers: [MaskPoint] = []
    /// An import asked for by name or button ("photos", "files", "camera"): the view shows its picker.
    @Published var importer: String?
    /// The library's map is showing (Map).
    @Published var showsMap = false
    /// Cameras and SD cards connected (Import From Camera, Tethered Capture).
    let cameras = CameraImporter()
    /// The iPad's own camera with manual settings (Pro Camera).
    let proCamera = ProCamera()
    /// The Pro camera is showing.
    @Published var showsCamera = false
    /// Photos asked for ("take photo"): the camera screen takes one each time this grows.
    @Published private(set) var cameraShots = 0

    /// What the View panel's scopes show.
    struct ScopeReadings: Equatable {
        /// Histogram: per channel and luma, bar heights 0…1 (nil while it is off).
        var histogram: (red: [Double], green: [Double], blue: [Double], luma: [Double])?
        /// Clipping warning: the shares of pixels with lost highlights and shadows (nil while it is off).
        var clipping: (highlights: Double, shadows: Double)?
        /// Vectorscope: cell brightness 0…1, `size` × `size`, row by row from the top (nil while it is off).
        var vectorscope: (size: Int, cells: [Double])?
        /// Colour samplers' readouts, one line each ("R 120 G 80 B 60 · L 40 a 12 b 20").
        var samples: [String] = []

        static func == (a: ScopeReadings, b: ScopeReadings) -> Bool {
            a.histogram?.luma == b.histogram?.luma && a.histogram?.red == b.histogram?.red
                && a.histogram?.green == b.histogram?.green && a.histogram?.blue == b.histogram?.blue
                && a.clipping?.highlights == b.clipping?.highlights && a.clipping?.shadows == b.clipping?.shadows
                && a.vectorscope?.cells == b.vectorscope?.cells && a.samples == b.samples
        }
    }

    enum VoiceState: Equatable {
        case idle, listening, transcribing
    }

    private var interpreter: CommandInterpreter
    private var original: CIImage
    /// The photo as opened (a merge replaces the photo being edited; start over goes back to it).
    private var opened: CIImage
    private var previewSource: CIImage
    private let previewSide: CGFloat
    let renderer = PhotoRenderer()
    /// The View panel's overlays (before / after, …), on the preview only.
    private lazy var viewRenderer = ViewRenderer(context: renderer.context)
    /// Work out retouch steps before showing the preview (the render gallery), instead of in the background.
    var waitsForRetouch = false
    /// Turn each render into the on-screen picture (the render gallery only saves the last one).
    var showsPreview = true
    /// Keep the user's presets in a file and across "start over" (the render gallery starts each case afresh).
    var keepsPresets = true
    /// The presets as last written to the file.
    private var savedPresets: [Preset] = []
    /// The user's export presets as last written to their file.
    private var savedExportPresets: [Preset] = []
    /// The history step the next render records for a touch edit (a slider, a stroke…) and its key (a
    /// drag's renders merge into one step; `historySeal` ends it). Nil: what changed belongs to the
    /// step the last command made (the interpreter records those).
    private var historyLabel: String?
    private var historyKey: String?
    private var historySeal = false
    private let recorder = AudioRecorder()
    /// The library's files (Documents/Library; the render gallery gives each editor a folder of its own).
    let libraryStore: LibraryStore
    /// Keep the library in its file and across "start over" (the render gallery starts each case with an empty one).
    var keepsLibrary = true
    /// Exports go to Photos, Files or the share sheet (the render gallery only notes what it would save).
    var exportsFiles = true
    /// The name of the last file exported (the render gallery's manifest).
    private var lastExported = ""
    /// Save To Files: the file the Files app's save dialog shows (nil: none).
    @Published var fileToSave: (document: ExportDocument, type: UTType, name: String)?
    /// Share: the exported file the share sheet sends (nil: none).
    @Published var shareFile: URL?

    /// `image` replaces the bundled test photo (the render gallery passes a small copy);
    /// `previewSide` is the long side of the live preview; `libraryFolder` where the library is kept.
    init(image: CIImage? = nil, previewSide: CGFloat = 2048, libraryFolder: URL? = nil) {
        let registry = (try? ControlRegistry.bundled()) ?? ControlRegistry(controls: [])
        self.registry = registry
        self.interpreter = CommandInterpreter(registry: registry)
        self.libraryStore = LibraryStore(folder: libraryFolder ?? LibraryStore.standardFolder)
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
        self.opened = start
        self.previewSide = previewSide
        self.previewSource = PhotoRenderer.downscaled(start, maxSide: previewSide)
        renderer.lens = Self.lens(of: start)
        savedPresets = Self.readPresets(Self.presetsFile)
        interpreter.workspace.presets = savedPresets
        savedExportPresets = Self.readPresets(Self.exportPresetsFile)
        interpreter.workspace.exportPresets = savedExportPresets
        interpreter.workspace.library = libraryStore.read()
        installActions()
        // The Pro camera's photos join the library and open.
        proCamera.onPhoto = { [weak self] data, ext in
            Task { @MainActor in self?.importPictures([LibraryImport(data: data, name: "Camera \(EditorModel.stamp()).\(ext)", asset: nil)]) }
        }
        // Tethered capture: each new shot joins the library and opens.
        cameras.onNewPhotos = { [weak self] urls in
            Task { @MainActor in self?.importFiles(urls) }
        }
        // Retouch steps are worked out in the background: show them when they are ready.
        renderer.retouch.onFinish = { [weak self] in
            Task { @MainActor in self?.render() }
        }
        render()
        resumeLibrary()

        // Launch argument used by the cloud build to screenshot the Library panel: a few generated
        // pictures in an empty library.
        if UserDefaults.standard.bool(forKey: "demoLibrary"), library.photos.isEmpty {
            let small = PhotoRenderer.downscaled(start, maxSide: 800)
            importPictures(["warm", "haze", "chart", "building", "portrait", "tilted", "noise", "dust"].enumerated().compactMap {
                RenderGallery.libraryImport($0.element, index: $0.offset, photo: small)
            })
        }
        // Launch argument used by the cloud build to screenshot a command's effect.
        if let demo = UserDefaults.standard.string(forKey: "demoCommand") {
            run(demo)
        }
        // Launch argument used by the cloud build to screenshot one panel ("-panel export").
        if let panel = UserDefaults.standard.string(forKey: "panel") {
            shownPanel = panel
        }
    }

    /// The value a slider shows: while a mask is selected, its own value for local sliders.
    func value(of control: Control) -> Double {
        state.current(control)
    }

    func setFromSlider(_ control: Control, to value: Double) {
        if control.id == Presets.amountID {
            // Preset Amount applies the last preset again at the new strength.
            apply([.set(control.id, value)])
            return
        }
        guard let target = state.target(for: control) else {
            feedback = describe([.needsMask(controlID: control.id)])
            return
        }
        state.set(control, to: value, at: target)
        focus(control)
        // One drag of a slider is one history step.
        historyLabel = "\(control.label) \(Self.format(state.value(of: control, at: target), control))"
        historyKey = "slider:" + control.id
        render()
    }

    /// A slider was let go: the next drag is a step of its own.
    func endSliderDrag() {
        interpreter.workspace.history.seal()
    }

    // MARK: - History

    var canUndo: Bool { interpreter.workspace.history.canUndo }
    var canRedo: Bool { interpreter.workspace.history.canRedo }
    /// The edit's steps, oldest first (step 0: the photo as opened), and the one it is at.
    var historySteps: [EditHistory.Step] { interpreter.workspace.history.steps }
    var historyPosition: Int { interpreter.workspace.history.position }
    /// Named states of this photo's edit.
    var snapshots: [Snapshot] { interpreter.workspace.snapshots }
    /// The photo's edits (virtual copies; "Original" alone when there are none) and the one being edited.
    var copyNames: [String] { interpreter.workspace.copyNames }
    var currentCopy: Int { interpreter.workspace.currentCopy }

    /// The history name of a touch on the photo with the tool in use.
    private var touchLabel: String {
        if targetedMode != nil, let control = registry.control(id: "targetedAdjustment") {
            let i = Int(state.value(of: control))
            return "Targeted " + (control.options.indices.contains(i) ? control.options[i].label : "")
        }
        if let tool = geometryTool {
            return registry.controls.first { GeometryTools.actions[$0.id] == tool }?.label ?? tool.capitalized
        }
        if let tool = retouchTool { return label(ofTool: tool) }
        if let s = state.selectedComponent { return "Mask \(s.mask + 1): " + label(ofPart: state.masks[s.mask].components[s.component].kind) }
        if let l = state.selectedLayer { return "Layer \(l + 1): " + layerName(l) }
        return "Touch"
    }

    func reset(_ control: Control) {
        setFromSlider(control, to: control.defaultValue)
    }

    /// Back to the untouched photo: every control at its default, nothing focused, no feedback.
    func startOver() {
        state = EditState()
        historyLabel = nil
        // The user's presets and copied settings outlive the edit (not in the render gallery).
        let kept = interpreter.workspace
        interpreter = CommandInterpreter(registry: registry)
        if keepsPresets {
            interpreter.workspace.presets = kept.presets
            interpreter.workspace.clipboard = kept.clipboard
            interpreter.workspace.exportPresets = kept.exportPresets
        }
        if keepsLibrary { interpreter.workspace.library = kept.library }
        installActions()
        focusedControlID = nil
        feedback = nil
        armedPicker = nil
        geometryTool = nil
        dragBase = nil
        cropDrag = nil
        quadDrag = nil
        pinDrag = nil
        layerDrag = nil
        layerMode = "move"
        layerPhotos = []
        watermarkLogo = nil
        mergePhotos = []
        lastBatch = []
        samplers = []
        zoomPercent = 0
        viewCenter = MaskPoint(0.5, 0.5)
        loupe = nil
        livePhoto = nil
        // What the last export, print and tethered shot did belongs to the old edit.
        lastExported = ""
        lastPrint = ""
        lastShot = ""
        fileToSave = nil
        shareFile = nil
        if merged != nil {
            merged = nil
            mergeJob += 1
            isMerging = false
            replacePhoto(opened, lens: Self.lens(of: opened))
        }
        render()
    }

    /// Controls that are not at their default, by id (for the render gallery's manifest); a mask's
    /// local sliders as "mask1.exposure".
    func changedValues() -> [String: Double] {
        var out: [String: Double] = [:]
        for control in registry.controls where !state.isDefault(control) {
            out[control.id] = state.value(of: control)
        }
        for (i, mask) in state.masks.enumerated() {
            for (id, value) in mask.adjustments { out["mask\(i + 1).\(id)"] = value }
            out["mask\(i + 1).parts"] = Double(mask.components.count)
        }
        if !state.retouches.isEmpty { out["retouch.steps"] = Double(state.retouches.count) }
        if !state.layers.isEmpty { out["layers"] = Double(state.layers.count) }
        return out
    }

    // MARK: - Retouch

    /// The retouch tool touches on the photo use ("remove", …), or nil.
    var retouchTool: String? {
        armedPicker == nil ? state.retouchTool : nil
    }

    /// The label of the action that picks a retouch tool ("Remove Brush" for "remove").
    func label(ofTool tool: String) -> String {
        registry.controls.first { $0.kind == .action && $0.tool == tool }?.label ?? tool
    }

    /// A stroke or tap with a retouch tool. Patch and Content-Aware Move: a stroke is the outline
    /// around the area; a drag that starts inside the selected outline sets where its texture comes
    /// from (Patch) or where the area goes (Move).
    private func retouchStroke(_ tool: String, points drawn: [MaskPoint], pressure: [Double]) {
        // After liquify strokes, other tools work on the picture as it was before liquify (it is
        // liquified last): the points go back through the liquify field.
        let points = tool != "liquify" && state.retouches.contains { $0.tool == "liquify" } ? renderer.retouch.unwarp(drawn) : drawn
        if RetouchTools.outlined.contains(tool) {
            if let s = state.selectedRetouch, state.retouches[s].tool == tool, points.count >= 2,
               let start = points.first, let end = points.last, state.retouches[s].contains(start) {
                state.retouches[s].offset = MaskPoint(end.x - start.x, end.y - start.y)
                feedback = Feedback(text: "Spot \(s + 1): " + (tool == "move" ? "moved" : "source set"))
                render()
                return
            }
            guard points.count >= 3 else { return }
        }
        addRetouch(tool, points: points, pressure: pressure)
    }

    /// A new retouch step from a stroke or tap with the tool in use, with the brush and the tool's
    /// settings as they are now.
    private func addRetouch(_ tool: String, points: [MaskPoint], pressure: [Double]) {
        guard !points.isEmpty else { return }
        func v(_ id: String) -> Double { registry.control(id: id).map { state.value(of: $0) } ?? 0 }
        var values: [String: Double] = [:]
        for id in RetouchTools.settings(for: tool) { values[id] = v(id) }
        // Pressure is kept only when the Pencil was used (fingers press fully).
        let pressed = pressure.count == points.count && pressure.contains { $0 < 0.999 } ? pressure : []
        state.addRetouch(Retouch(tool: tool, points: points, pressure: pressed, size: v("brushSize"), feather: v("brushFeather"),
                                 values: values))
        feedback = Feedback(text: "Spot \(state.retouches.count): \(label(ofTool: tool))")
        render()
    }

    // MARK: - Masks

    /// The selected mask's selected part, when it is drawn on the photo (brush strokes, shapes,
    /// taps); nil when touches on the photo do nothing.
    var canvasTool: String? {
        guard armedPicker == nil, let s = state.selectedComponent else { return nil }
        return state.masks[s.mask].components[s.component].kind
    }

    /// The label of the action that makes a mask part ("Brush Mask" for "brush").
    func label(ofPart kind: String) -> String {
        registry.controls.first { $0.kind == .action && $0.component == kind }?.label ?? kind
    }

    /// Selects a mask by its index (nil = back to the global sliders), as "mask 2" would.
    func selectMask(_ index: Int?) {
        guard let mask = registry.control(id: EditState.maskSelectorID) else { return }
        apply([.set(mask.id, Double(index.map { $0 + 1 } ?? 0))])
    }

    /// Runs commands that came from a button (a mask action, "done", …), with feedback.
    func apply(_ commands: [Command]) {
        historyLabel = nil
        let outcomes = interpreter.apply(commands, state: &state)
        focusedControlID = interpreter.lastControlID
        feedback = describe(outcomes)
        armPickers(outcomes)
        render()
    }

    /// The selected mask's selected part.
    var selectedPart: MaskComponent? {
        state.selectedComponent.map { state.masks[$0.mask].components[$0.component] }
    }

    /// The preview's width and height in pixels (gradient angles are measured on the photo).
    var photoSize: CGSize { previewSource.extent.size }

    /// The selected part as it was when the current drag began (radial drags are relative to it).
    private var dragBase: MaskComponent?

    /// A finger or Pencil drew on the photo (points from the top-left, 0…1), for the selected mask
    /// part: a brush stroke with the current brush settings, a linear gradient drawn from where the
    /// effect is full (first point) to where it ends (last point), a radial gradient moved or
    /// resized. `finished` is false while a drag is still going (the canvas sends it as it moves).
    func draw(_ shown: [MaskPoint], pressure: [Double] = [], tilt: [Double] = [], finished: Bool = true) {
        // A drag is one history step, a stroke or tap one each.
        historyLabel = touchLabel
        historyKey = "draw"
        historySeal = finished
        if let mode = targetedMode {
            targetedDraw(mode, shown, finished: finished)
            return
        }
        if let tool = geometryTool {
            geometryDraw(tool, shown, finished: finished)
            return
        }
        // Layers live on the finished picture itself: the shown points are theirs.
        if retouchTool == nil, canvasTool == nil, let tool = layerCanvasTool {
            layerDraw(tool, shown, pressure: pressure, tilt: tilt, finished: finished)
            return
        }
        // Masks and spots live on the photo itself: points on the (cropped, turned) preview map back.
        let points = shown.map(toPhoto)
        if let tool = retouchTool {
            if finished { retouchStroke(tool, points: points, pressure: pressure) }
            return
        }
        let base = dragBase ?? selectedPart
        dragBase = finished ? nil : base
        guard let tool = canvasTool, let start = points.first, let end = points.last else { return }
        switch tool {
        case "brush", "quickSelect":
            func v(_ id: String) -> Double { registry.control(id: id).map { state.value(of: $0) } ?? 0 }
            state.addStroke(MaskStroke(points: points, size: v("brushSize"), feather: v("brushFeather"), flow: v("brushFlow"),
                                       density: v("brushDensity"), erase: v("brushErase") != 0, autoMask: v("brushAutoMask") != 0))
        case "linear":
            guard start != end else { return }
            let g = MaskGeometry.linear(from: start, to: end, width: Double(photoSize.width), height: Double(photoSize.height))
            state.setComponentValues(["linearAngle": g.angle.rounded(), "linearPosition": g.position, "linearWidth": max(1, g.width)])
        case "colorRange", "magicWand":
            state.setPoint(end)
        case "lasso", "polygon":
            state.setPath(points)
        case "rectangle", "ellipse":
            guard start != end else { return }
            state.setComponentValues(["left": min(start.x, end.x), "top": min(start.y, end.y),
                                      "right": max(start.x, end.x), "bottom": max(start.y, end.y)])
        case "luminanceRange":
            // The brightness there (before other edits), ±15.
            let image = renderer.whiteBalanceInput(previewSource, value: currentValue)
            let color = ImageStats.averageColor(of: image, in: Self.spot(end.x, end.y, in: image.extent), context: renderer.context)
            let range = MaskPresets.luminanceRange(around: color.encoded.luma * 100)
            state.setComponentValues(["luminanceRangeLow": range.low, "luminanceRangeHigh": range.high])
        case "radial":
            guard start != end, let base else { return }
            state.setComponentValues(MaskGeometry.radialDrag(base.values, from: start, to: end,
                                                             width: Double(photoSize.width), height: Double(photoSize.height)))
        default:
            return
        }
        render()
    }

    func focus(_ control: Control) {
        interpreter.focus(controlID: control.id)
        focusedControlID = control.id
    }

    /// Action controls look at the photo: Auto reads the unedited preview's brightness histogram and
    /// colour and sets the light sliders, Temperature, Tint and Vibrance (AutoTone in CommandEngine),
    /// so its result stays editable; Auto Straighten sets Straighten from the photo's lines.
    private func installActions() {
        let source = previewSource
        let context = renderer.context
        let renderer = self.renderer
        interpreter.actionHandler = { id in
            switch id {
            case "auto":
                let histogram = ImageStats.lumaHistogram(of: source, extent: source.extent, context: context)
                return AutoTone.commands(lumaHistogram: histogram,
                                         averageColor: ImageStats.averageColor(of: source, context: context),
                                         meanChroma: ImageStats.meanChroma(of: source, context: context))
            case "autoStraighten":
                // The lines of the photo as last shown (LineDetector), levelled.
                guard let angle = renderer.autoStraightenAngle() else { return [] }
                return [.set("straighten", (angle * 10).rounded() / 10)]
            default:
                return []
            }
        }
    }

    /// A button for an action control (e.g. Auto) was tapped.
    func runAction(_ control: Control) {
        historyLabel = nil
        let outcomes = interpreter.apply([.run(control.id)], state: &state)
        focusedControlID = interpreter.lastControlID
        feedback = describe(outcomes)
        armPickers(outcomes)
        render()
    }

    // MARK: - Geometry (crop, …)

    /// A point on the shown preview (0…1 from the top-left) → the same point on the photo.
    func toPhoto(_ p: MaskPoint) -> MaskPoint {
        guard let plan = previewPlan, !plan.isIdentity else { return p }
        let q = plan.toSource(p)
        return MaskPoint(min(max(q.x, 0), 1), min(max(q.y, 0), 1))
    }

    /// The geometry steps the preview shows: the crop tool shows the whole frame with the crop box on it.
    var geometryStage: GeometryStage {
        switch geometryTool {
        case "crop", "straighten", "guides": return .frame
        case "perspective": return .source
        default: return .full
        }
    }

    /// The crop box as it is (after aspect and constrain), as shares of the frame, for the crop tool.
    var cropBox: (x0: Double, y0: Double, x1: Double, y1: Double) {
        fullPlan(previewSource.extent).cropBox
    }

    /// The whole geometry for a picture of this size (whatever the preview shows).
    private func fullPlan(_ extent: CGRect) -> GeometryPlan {
        renderer.geometry.plan(extent: extent, value: currentValue, edits: state.geometry, stage: .full, previewScale: previewScale)
    }

    /// The preview's size ÷ the full photo's.
    private var previewScale: Double {
        Double(max(previewSource.extent.width, previewSource.extent.height) / max(original.extent.width, original.extent.height, 1))
    }

    /// The saved photo's size and resolution, for the Geometry panel.
    var savedSizeText: String {
        let plan = fullPlan(previewSource.extent)
        let inches = String(format: "%.1f × %.1f in", plan.savedWidth / plan.resolution, plan.savedHeight / plan.resolution)
        return "Saved photo: \(Int(plan.savedWidth)) × \(Int(plan.savedHeight)) px · \(inches) at \(Int(plan.resolution)) ppi"
    }

    /// Where the photo's own coordinates lie on the shown preview (`shown`: its size on screen): the
    /// photo's size on screen and the projection from there onto the preview. Mask handles and spot
    /// outlines are drawn on the photo and projected (see SourceSpace).
    func sourceLayout(shown: CGSize) -> (size: CGSize, projection: ProjectionTransform) {
        guard let plan = previewPlan, !plan.isIdentity, plan.shapedWidth > 0, shown.width > 0 else {
            return (shown, ProjectionTransform())
        }
        // Screen points per pixel of the photo (about: the crop keeps the photo's scale).
        let k = Double(shown.width) / plan.canvasWidth * plan.shapedWidth / max(plan.crop.width, 1)
        let size = CGSize(width: CGFloat(plan.sourceWidth * k), height: CGFloat(plan.sourceHeight * k))
        let h = (Homography.scale(Double(shown.width), Double(shown.height)) * plan.shownTransform
                 * Homography.scale(1 / Double(size.width), 1 / Double(size.height))).normalized
        let m = h.m.map { CGFloat($0) }
        var p = ProjectionTransform()
        p.m11 = m[0]
        p.m21 = m[1]
        p.m31 = m[2]
        p.m12 = m[3]
        p.m22 = m[4]
        p.m32 = m[5]
        p.m13 = m[6]
        p.m23 = m[7]
        p.m33 = m[8]
        return (size, p)
    }

    /// Perspective crop's corners when the current drag began.
    private var quadDrag: [MaskPoint]?
    /// Warp: the handles when the current drag began, and the one dragged.
    private var pinDrag: (pins: [WarpPin], index: Int)?

    /// The crop handle a drag took hold of and the box when it began.
    private var cropDrag: (handle: Crop.Handle, box: (x0: Double, y0: Double, x1: Double, y1: Double))?

    /// A drag or tap with the Geometry panel's tool (points on the shown preview).
    private func geometryDraw(_ tool: String, _ points: [MaskPoint], finished: Bool) {
        guard let start = points.first, let end = points.last else { return }
        switch tool {
        case "crop":
            let plan = fullPlan(previewSource.extent)
            let base = cropDrag?.box ?? plan.cropBox
            let handle = cropDrag?.handle ?? Crop.handle(at: start, box: base)
            cropDrag = finished ? nil : (handle, base)
            guard start != end else { return }
            let settings = GeometrySettings(value: currentValue)
            let aspect = Crop.ratio(settings.aspect, original: plan.frameWidth / max(plan.frameHeight, 1))
            let box = Crop.drag(handle, box: base, from: start, to: end, aspect: aspect, width: plan.frameWidth, height: plan.frameHeight)
            for (id, value) in Crop.edges(of: box) {
                if let control = registry.control(id: id) { state.set(control, to: value) }
            }
        case "straighten":
            // A line along something that should be level or upright, measured before the turn.
            guard finished, let plan = previewPlan else { return }
            let a = plan.frameToPreStraighten(start), b = plan.frameToPreStraighten(end)
            guard (b - a).length > 4 else { return }
            apply([.set("straighten", (Straighten.angle(levelling: a, b) * 10).rounded() / 10)])
            // Then the crop box, as in Lightroom, to see what the turn leaves.
            geometryTool = "crop"
            render()
            return
        case "warp", "puppet":
            // Handles live on the picture inside the canvas; the nearest one follows the finger.
            guard let plan = previewPlan else { return }
            let a = plan.toWarpSpace(start), b = plan.toWarpSpace(end)
            if tool == "warp", state.geometry.pins.isEmpty { state.geometry.pins = Warp.lattice }
            let base = pinDrag?.pins ?? state.geometry.pins
            if let index = pinDrag?.index ?? Warp.nearest(base, to: a, width: plan.shapedWidth, height: plan.shapedHeight) {
                pinDrag = finished ? nil : (base, index)
                var pins = base
                pins[index].position = MaskPoint(min(1, max(0, base[index].position.x + b.x - a.x)),
                                                 min(1, max(0, base[index].position.y + b.y - a.y)))
                state.geometry.pins = pins
            } else if tool == "puppet", finished, hypot(b.x - a.x, b.y - a.y) < 0.01 {
                // A tap away from the pins adds one, on the picture as it shows now.
                state.geometry.pins.append(WarpPin(anchor: plan.unwarp(a), position: a))
                feedback = Feedback(text: "Pin \(state.geometry.pins.count): drag it to bend the picture")
            } else {
                pinDrag = nil
                return
            }
        case "perspective":
            // The photo shows as it is: the nearest corner follows the finger.
            let base = quadDrag ?? state.geometry.quad
            quadDrag = finished ? nil : base
            state.geometry.quad = PerspectiveCrop.drag(base, from: start, to: end)
        case "guides":
            // A guide along an edge that should be upright or level, kept on the photo itself.
            guard finished, let plan = previewPlan else { return }
            let a = plan.frameToSource(start), b = plan.frameToSource(end)
            guard hypot((b.x - a.x) * plan.sourceWidth, (b.y - a.y) * plan.sourceHeight) > 8 else { return }
            state.geometry.guides.append([a, b])
            if state.geometry.guides.count > Upright.maxGuides { state.geometry.guides.removeFirst() }
            feedback = Feedback(text: "Guide \(state.geometry.guides.count) of \(Upright.maxGuides)")
        default:
            return
        }
        render()
    }

    /// Warp handles where they show (normalized), and whether they are the 4 × 4 grid.
    var shownPins: (points: [MaskPoint], grid: Bool) {
        guard let plan = previewPlan else { return ([], false) }
        let pins = state.geometry.pins
        let grid = pins.count >= 16 && zip(pins.prefix(16), Warp.lattice).allSatisfy { $0.anchor == $1.anchor }
        return (pins.map { plan.fromWarpSpace($0.position) }, grid)
    }

    /// The guides as they show on the frame (normalized), for the guides tool.
    var shownGuides: [(MaskPoint, MaskPoint)] {
        guard let plan = previewPlan, plan.stage == .frame else { return [] }
        return plan.guidesOnFrame(state.geometry.guides)
    }

    /// A Geometry tool that ran (by button, voice or typing) takes the touches on the photo; "done"
    /// puts it away, and so does picking a mask or a retouch tool.
    private func armGeometryTools(_ outcomes: [CommandInterpreter.Outcome]) {
        for case .ran(let id) in outcomes {
            if let tool = GeometryTools.actions[id] {
                geometryTool = tool
                armedPicker = nil
                if tool == "perspective", state.geometry.quad.count != 4 {
                    // Start from the largest four-sided shape along the photo's lines, or the middle.
                    state.geometry.quad = renderer.detectedQuad() ?? PerspectiveCrop.inset
                }
            } else if id == "maskDone" {
                geometryTool = nil
            }
        }
    }

    // MARK: - Layers

    /// Pictures shown by photo layers (a layer's "photo" number is its index here): the photo as picked
    /// and a copy the preview's size.
    private(set) var layerPhotos: [(full: CIImage, preview: CIImage)] = []
    /// The selected layer's place when the current drag began.
    private var layerDrag: (x: Double, y: Double)?

    /// What touches on the picture do to the selected layer ("move"), or nil when a picker, a tool
    /// or a mask takes them, or no layer is selected.
    var layerCanvasTool: String? {
        guard armedPicker == nil, geometryTool == nil, state.retouchTool == nil, canvasTool == nil, state.selectedLayer != nil else {
            return nil
        }
        return layerMode
    }

    /// A drag on the picture with a layer selected (points on the shown picture, 0…1): moves it, or
    /// ("mask") paints its mask with the brush settings (Brush Size, Feather, Eraser…).
    private func layerDraw(_ tool: String, _ points: [MaskPoint], pressure: [Double], tilt: [Double], finished: Bool) {
        guard let l = state.selectedLayer, let start = points.first, let end = points.last else { return }
        switch tool {
        case "paint":
            // A stroke of the paint brush, its width following the Pencil's pressure and tilt.
            guard finished, let plan = previewPlan else { return }
            func v(_ id: String) -> Double { registry.control(id: id).map { state.value(of: $0) } ?? 0 }
            let w = plan.outputWidth, h = plan.outputHeight
            let pressed = pressure.count == points.count && pressure.contains { $0 < 0.999 } ? pressure : []
            let leaned = tilt.count == points.count && tilt.contains { $0 > 0.001 } ? tilt : []
            state.addPaintStroke(points.map { Vec2($0.x * w, $0.y * h) }, pressure: pressed, tilt: leaned,
                                 size: v("paintSize"), color: v("brushColor"), width: w, height: h)
        case "pen":
            // A tap: a corner; a drag: a point with a curve handle pulled out to where the finger lifts.
            guard finished, let plan = previewPlan else { return }
            let w = plan.outputWidth, h = plan.outputHeight
            let a = Vec2(start.x * w, start.y * h), b = Vec2(end.x * w, end.y * h)
            let drag = hypot(end.x - start.x, end.y - start.y) > 0.01
            state.penPoint(a, handleEnd: drag ? b : nil, width: w, height: h)
            if state.layers[l].closed {
                layerMode = "move"
                feedback = Feedback(text: "Layer \(l + 1): path closed · drag it to move it; Shape Fill colours it")
            }
        case "mask":
            guard finished else { return }
            func v(_ id: String) -> Double { registry.control(id: id).map { state.value(of: $0) } ?? 0 }
            state.addLayerMaskStroke(MaskStroke(points: points, size: v("brushSize"), feather: v("brushFeather"), flow: v("brushFlow"),
                                                density: v("brushDensity"), erase: v("brushErase") != 0))
        case "move":
            let base = layerDrag ?? (state.layers[l].value("layerX", 50), state.layers[l].value("layerY", 50))
            layerDrag = finished ? nil : base
            guard start != end else { return }
            func place(_ v: Double) -> Double { (min(100, max(0, v)) * 10).rounded() / 10 }
            state.layers[l].values["layerX"] = place(base.x + (end.x - start.x) * 100)
            state.layers[l].values["layerY"] = place(base.y + (end.y - start.y) * 100)
        default:
            return
        }
        render()
    }

    /// An adjustment layer is selected: the light, colour, effects and detail sliders change it (the
    /// Layers panel shows them; the other panels hide, as for a mask).
    var adjustmentLayerSelected: Bool {
        state.selectedLayer.map { state.layers[$0].kind == "adjustment" } ?? false
    }

    /// The eye in the layer list: shows or hides a layer.
    func toggleLayerVisible(_ index: Int) {
        guard state.layers.indices.contains(index) else { return }
        state.layers[index].values["layerVisible"] = state.layers[index].isVisible ? 0 : 1
        historyLabel = "Layer \(index + 1): " + (state.layers[index].isVisible ? "shown" : "hidden")
        render()
    }

    /// The selected pen path's points on the shown picture (0…1), while the pen draws it.
    var penPoints: [MaskPoint] {
        guard layerMode == "pen", let l = state.selectedLayer, let plan = previewPlan else { return [] }
        let w = plan.outputWidth, h = plan.outputHeight, t = state.layers[l].transform
        return state.layers[l].path.map { node -> MaskPoint in
            let p = t.toCanvas(Vec2(node.point.x, node.point.y), width: w, height: h)
            return MaskPoint(p.x / w, p.y / h)
        }
    }

    /// The selected layer's outline on the shown picture (corners, 0…1 from the top-left), for the canvas.
    var selectedLayerOutline: [MaskPoint] {
        guard let l = state.selectedLayer, let plan = previewPlan else { return [] }
        let layer = state.layers[l]
        var aspect: Double?
        if layer.kind == "photo", layerPhotos.indices.contains(Int(layer.value("photo", -1))) {
            let e = layerPhotos[Int(layer.value("photo", -1))].full.extent
            aspect = Double(e.width / max(e.height, 1))
        }
        let w = plan.outputWidth, h = plan.outputHeight
        return Layers.outline(layer, aspect: aspect, width: w, height: h).map { MaskPoint($0.x / w, $0.y / h) }
    }

    /// Layer actions that ran (by button, voice or typing): a photo placed from the photos picked; a
    /// new or reselected layer is moved by touch.
    private func armLayerTools(_ outcomes: [CommandInterpreter.Outcome]) {
        for outcome in outcomes {
            switch outcome {
            case .layered(_, .created), .layered(_, .duplicated), .changed(EditState.layerSelectorID, _, _):
                layerMode = "move"
            case .changed("watermark", _, let to) where Watermark.styles.indices.contains(Int(to)) && Watermark.styles[Int(to)] == "logo":
                useWatermarkLogo()
            case .layered(_, .masked(let part)):
                // "layer mask brush": paint the mask; a gradient or radial: back to moving the layer.
                layerMode = part == "brush" ? "mask" : "move"
            default:
                break
            }
        }
        attachLayerPhotos()
        // The pen: taps and drags on the picture add points to the selected path.
        if outcomes.contains(.ran(controlID: "penTool")) { layerMode = "pen" }
        if outcomes.contains(.ran(controlID: "paintBrush")) { layerMode = "paint" }
        if state.selectedLayer != nil { geometryTool = nil }
    }

    /// The watermark's logo: the last photo picked, as picked and the preview's size.
    private(set) var watermarkLogo: (full: CIImage, preview: CIImage)?

    /// "watermark logo": the last photo picked becomes the logo.
    private func useWatermarkLogo() {
        guard let photo = mergePhotos.last else {
            if watermarkLogo == nil {
                feedback = Feedback(text: "Pick the logo first (Layers panel → Pick Photos), then say “watermark logo”.", isProblem: true)
            }
            return
        }
        watermarkLogo = (photo, PhotoRenderer.downscaled(photo, maxSide: previewSide))
    }

    /// The watermark's words (the panel's text field), as “watermark text …” would set them.
    func setWatermarkText(_ text: String) {
        apply([.run("watermarkText", text: text)])
    }

    /// New photo layers ("place photo", "place photo 2") get the photo picked they ask for (the last
    /// one, or the second…); without photos picked they go again.
    private func attachLayerPhotos() {
        for i in state.layers.indices.reversed() where state.layers[i].kind == "photo" && state.layers[i].values["photo"] == nil {
            guard !mergePhotos.isEmpty else {
                state.layers.remove(at: i)
                state.selectLayer(nil)
                feedback = Feedback(text: "Pick a photo first (Layers panel → Pick Photos).", isProblem: true)
                continue
            }
            let n = Int(state.layers[i].values["picked"] ?? 0) - 1
            let photo = mergePhotos[mergePhotos.indices.contains(n) ? n : mergePhotos.count - 1]
            layerPhotos.append((photo, PhotoRenderer.downscaled(photo, maxSide: previewSide)))
            state.layers[i].values["photo"] = Double(layerPhotos.count - 1)
            state.layers[i].values["picked"] = nil
        }
    }

    // MARK: - Pickers (tap the photo)

    /// Picker tools and what they ask the user to tap.
    static let pickers: [String: String] = [
        "wbPicker": "Tap something on the photo that should be neutral grey.",
        "pointColorPicker": "Tap the colour on the photo you want to change.",
        "spotSource": "Tap where the selected spot should copy from.",
        "portraitFocus": "Tap what should be sharp: the depth there becomes the Focus Depth.",
        CreativeFilters.centerPicker: centerHint,
        "colorSampler": "Tap the photo where to read the colour (RGB and L*a*b*; up to 4 samplers).",
    ]

    /// The import actions and the picker each asks the view to show.
    static let importers = ["importPhotos": "photos", "importFiles": "files", "importCamera": "camera"]

    /// What the Effect Center picker asks.
    static let centerHint = "Tap the photo where the effect's centre should be."

    /// A picker that ran (by button, voice or typing) now waits for a tap on the photo.
    private func armPickers(_ outcomes: [CommandInterpreter.Outcome]) {
        followZoom(outcomes)
        revealedPanel = nil
        for case .workflow(let event) in outcomes {
            if case .historyShown = event { revealedPanel = "history" }
            if case .library(.browsed) = event { revealedPanel = "library" }
            if case .library(.info) = event { revealedPanel = "library/Info" }
            // "light panel", "show layers"; "panel" alone: the panel of the control used last.
            if case .panelShown(let group) = event {
                revealedPanel = group ?? focusedControlID.flatMap { registry.control(id: $0) }.map(panel(for:))
            }
            if case .library(.mapShown) = event { showsMap = true }
            // "next photo": the engine has put that photo's edit in place; its picture comes now.
            if case .library(.opened(let id, _, _)) = event {
                showLibraryPhoto(id)
                feedback?.text += rawNote
            }
        }
        if outcomes.contains(where: { if case .ran(let id) = $0 { return Library.actions.contains(id) } else { return false } }) {
            saveLibrary()
        }
        armGeometryTools(outcomes)
        armLayerTools(outcomes)
        noteMissingInputs(outcomes)
        for case .ran(let id) in outcomes {
            if id == "clearSamplers" {
                samplers = []
                feedback = Feedback(text: "Colour samplers cleared")
            }
            if let kind = MergeTools.actions[id] { merge(kind) }
            if let kind = Self.importers[id] {
                importer = kind
                revealedPanel = "library"
            }
            if id == "tetheredShot" { tetheredShot() }
            if id == "export" { save() }
            if id == "saveToFiles" { saveToFiles() }
            if id == "share" { share() }
            if id == "print" { printPhoto() }
            if id == "proCamera" { showsCamera = true }
            if id == "takePhoto" {
                showsCamera = true
                cameraShots += 1
            }
            if id == "batchEdit" { batchEdit() }
            if id == "matchExposures" { batchEdit(matching: true) }
        }
        for case .ran(let id) in outcomes {
            if let hint = Self.pickers[id] {
                armedPicker = id
                feedback = Feedback(text: hint)
            }
        }
        // Naming a filter that works around a point ("zoom blur") lets the next tap place it.
        for case .changed(let id, let from, let to) in outcomes
        where CreativeFilters.centered.contains(id) && from == 0 && to != 0 && armedPicker == nil {
            armedPicker = CreativeFilters.centerPicker
            feedback?.text += " · " + Self.centerHint
        }
        // The panel asked for shows ("library/Info": the Library panel, its Info section open).
        if let revealedPanel {
            shownPanel = String(revealedPanel.prefix { $0 != "/" })
        }
    }

    /// The photo was tapped while a picker waited, or for the selected mask part (a colour range's
    /// sample): `x`, `y` from the top-left corner, 0…1.
    func tap(atX shownX: Double, y shownY: Double) {
        guard let picker = armedPicker else {
            draw([MaskPoint(shownX, shownY)])
            return
        }
        armedPicker = nil
        if picker == "colorSampler" {
            // Samplers read the picture as shown, where it was tapped.
            samplers.append(MaskPoint(min(max(shownX, 0), 1), min(max(shownY, 0), 1)))
            if samplers.count > Scopes.maxSamplers { samplers.removeFirst() }
            feedback = Feedback(text: "Sampler \(samplers.count): " + sample(editedPreview(), at: samplers[samplers.count - 1]))
            render()
            return
        }
        // Pickers read the photo itself: the point on the (cropped, turned) preview maps back.
        let onPhoto = toPhoto(MaskPoint(shownX, shownY))
        let x = onPhoto.x, y = onPhoto.y
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
        case "pointColorPicker":
            // The hue of the photo there (before other edits) becomes Point color's target.
            let image = renderer.whiteBalanceInput(previewSource, value: currentValue)
            let color = ImageStats.averageColor(of: image, in: Self.spot(x, y, in: image.extent), context: renderer.context)
            if let hue = ColorLook.pickedHue(linear: color) {
                let outcomes = interpreter.apply([.set("pointHue", hue.rounded())], state: &state)
                focusedControlID = interpreter.lastControlID
                feedback = describe(outcomes)
            } else {
                feedback = Feedback(text: "That spot is grey. Tap a coloured area.", isProblem: true)
            }
        case "portraitFocus":
            // The depth under the finger is kept sharp.
            guard let depth = renderer.portrait.depth else {
                feedback = Feedback(text: "This photo has no depth data (take it in Portrait mode on an iPhone).", isProblem: true)
                break
            }
            let outcomes = interpreter.apply([.set("focusDepth", (Double(depth.depth(at: MaskPoint(x, y))) * 100).rounded())], state: &state)
            focusedControlID = interpreter.lastControlID
            feedback = describe(outcomes)
        case CreativeFilters.centerPicker:
            // The creative filters work on the picture as framed: the point on it, not on the photo.
            let shown = MaskPoint(shownX, shownY)
            let c = CreativeFilters.centerValues(previewPlan?.toWarpSpace(shown) ?? shown)
            let outcomes = interpreter.apply([.set("effectCenterX", c.x), .set("effectCenterY", c.y)], state: &state)
            focusedControlID = interpreter.lastControlID
            feedback = describe(outcomes)
        case "spotSource":
            // The selected spot copies from around the tapped point.
            if let s = state.selectedRetouch {
                let centre = state.retouches[s].centre
                let tapped = state.retouches.contains { $0.tool == "liquify" }
                    ? renderer.retouch.unwarp([MaskPoint(x, y)])[0] : MaskPoint(x, y)
                state.retouches[s].offset = MaskPoint(tapped.x - centre.x, tapped.y - centre.y)
                feedback = Feedback(text: "Spot \(s + 1): source set")
                historyLabel = "Spot \(s + 1): source"
            }
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
        historyLabel = nil
        let outcomes = interpreter.interpret(trimmed, state: &state)
        focusedControlID = interpreter.lastControlID
        var result = describe(outcomes)
        if heard { result.text = "Heard “\(trimmed)” · " + result.text }
        feedback = result
        armPickers(outcomes)
        // A control said by name: its panel shows ("contrast more" shows Light). Not for words that act on
        // the workspace ("undo", "next photo") or name no control ("more").
        if revealedPanel == nil,
           let named = interpreter.lastCommands.last(where: { $0.control.map { !Workspace.actions.contains($0) } ?? false })?.control,
           let control = registry.control(id: named) {
            shownPanel = panel(for: control)
        }
        render()
    }

    // MARK: - Panels

    /// A panel the rail offers: its group, title and icon (an SF Symbol).
    struct PanelInfo: Identifiable {
        let group: String
        let title: String
        let symbol: String
        var id: String { group }
    }

    /// The panels the rail offers, in order.
    static let panels: [PanelInfo] = [
        PanelInfo(group: "library", title: "Library", symbol: "photo.on.rectangle.angled"),
        PanelInfo(group: "light", title: "Light", symbol: "sun.max"),
        PanelInfo(group: "color", title: "Color", symbol: "paintpalette"),
        PanelInfo(group: "effects", title: "Effects", symbol: "sparkles"),
        PanelInfo(group: "detail", title: "Detail", symbol: "triangle"),
        PanelInfo(group: "optics", title: "Optics", symbol: "camera.aperture"),
        PanelInfo(group: "masks", title: "Masks", symbol: "circle.dashed"),
        PanelInfo(group: "retouch", title: "Retouch", symbol: "bandage"),
        PanelInfo(group: "geometry", title: "Geometry", symbol: "crop.rotate"),
        PanelInfo(group: "merge", title: "Merge", symbol: "square.stack.3d.up"),
        PanelInfo(group: "creative", title: "Creative", symbol: "wand.and.stars"),
        PanelInfo(group: "layers", title: "Layers", symbol: "square.3.stack.3d"),
        PanelInfo(group: "presets", title: "Presets", symbol: "rectangle.stack"),
        PanelInfo(group: "history", title: "History", symbol: "clock.arrow.circlepath"),
        PanelInfo(group: "view", title: "View", symbol: "eye"),
        PanelInfo(group: "export", title: "Export", symbol: "square.and.arrow.up"),
    ]

    /// The title of a panel ("light" → "Light").
    static func panelTitle(_ group: String) -> String {
        panels.first { $0.group == group }?.title ?? group.prefix(1).uppercased() + group.dropFirst()
    }

    /// Whether a panel can show now: while a mask is selected only the Library, Masks, History and Export
    /// panels do (sliders change the mask, as in Lightroom); while an adjustment layer is, also Layers.
    func panelAvailable(_ group: String) -> Bool {
        if state.selectedMask != nil { return ["library", "masks", "history", "export"].contains(group) }
        if adjustmentLayerSelected { return ["library", "masks", "layers", "history", "export"].contains(group) }
        return true
    }

    /// The panel where a control is: a selected mask's (or adjustment layer's) local sliders are in the
    /// Masks (Layers) panel, the brush with the retouch tool in use in Retouch, the Camera panel's in Library.
    func panel(for control: Control) -> String {
        if retouchTool != nil, ["brushSize", "brushFeather"].contains(control.id) || control.group == "retouch" { return "retouch" }
        if control.group == "masks" || (control.local && state.selectedMask != nil) { return "masks" }
        if control.local, adjustmentLayerSelected { return "layers" }
        return control.group == "camera" ? "library" : control.group
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

    // MARK: - Library (import, open, next / previous)

    /// Every photo imported, each with its own edit.
    var library: Library { interpreter.workspace.library }

    /// The browser's small picture of a library photo.
    func thumbnail(_ id: String) -> UIImage? {
        libraryStore.thumbnail(id)
    }

    /// Pictures imported (from Photos, Files, a camera or an SD card): added to the library, the first
    /// one opened.
    func importPictures(_ items: [LibraryImport]) {
        var added: [LibraryPhoto] = []
        for item in items {
            guard let photo = libraryStore.add(item) else { continue }
            interpreter.workspace.library.add(photo)
            added.append(photo)
        }
        guard let first = added.first else {
            feedback = Feedback(text: items.isEmpty ? "Nothing to import." : "Those files couldn't be opened as photos.", isProblem: true)
            return
        }
        openLibraryPhoto(first.id)
        let n = added.count
        feedback = Feedback(text: "Imported \(n) photo\(n == 1 ? "" : "s")" + (n < items.count ? " (\(items.count - n) couldn't be read)" : "")
                            + " · the library has \(library.photos.count) · editing \(first.name)" + rawNote)
        saveLibrary()
    }

    /// Files picked in Files (or copied from a camera or card), read while the app may.
    func importFiles(_ urls: [URL]) {
        var items: [LibraryImport] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            if let data = try? Data(contentsOf: url) { items.append(LibraryImport(data: data, name: url.lastPathComponent, asset: nil)) }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        importPictures(items)
    }

    /// A picture that isn't in the library yet (the render gallery's "open" step): imported, then opened.
    func open(_ image: CIImage) {
        guard let data = renderer.jpegData(image) else { return }
        importPictures([LibraryImport(data: data, name: "Photo.jpg", asset: nil)])
    }

    /// Opens a library photo by touch (its thumbnail), as "photo 3" would: its own edit comes back.
    func openLibraryPhoto(_ id: String) {
        guard id != library.current, library.photo(id) != nil else { return }
        historyLabel = nil
        interpreter.workspace.openPhoto(id, state: &state)
        let shown = library.shown
        let index = (shown.firstIndex { $0.id == id } ?? 0) + 1
        showLibraryPhoto(id)
        feedback = Feedback(text: describe(LibraryEvent.opened(id: id, index: index, count: shown.count)).text + rawNote)
        saveLibrary()
        render()
    }

    /// Shows a library photo's picture (the engine has already put its edit in place): a file at once, a
    /// Photos asset when it has loaded.
    private func showLibraryPhoto(_ id: String) {
        guard let photo = library.photo(id) else { return }
        pictureInfo = nil
        if let data = libraryStore.fileData(for: photo) {
            show(data)
            return
        }
        Task { @MainActor in
            let data = await self.libraryStore.data(for: photo)
            guard self.library.current == id else { return }
            guard let data else {
                self.feedback = Feedback(text: "“\(photo.name)” can't be read: was it deleted from Photos, or may the app no longer read the library?",
                                         isProblem: true)
                return
            }
            self.show(data)
            self.render()
        }
    }

    /// A picture's bytes become the photo being edited; the touch tools and what belonged to the photo
    /// before (merges, layer pictures, samplers, zoom) start afresh.
    private func show(_ data: Data) {
        guard let picture = LibraryStore.decode(data) else {
            feedback = Feedback(text: "That file couldn't be opened as a photo.", isProblem: true)
            return
        }
        opened = picture.image
        merged = nil
        livePhoto = nil
        mergeJob += 1
        isMerging = false
        replacePhoto(picture.image, lens: Self.lens(properties: picture.properties))
        renderer.asShotKelvin = picture.asShotKelvin
        pictureInfo = picture
        renderer.portrait.depth = picture.isRaw ? nil : Self.depth(in: data, context: renderer.context)
        armedPicker = nil
        geometryTool = nil
        dragBase = nil
        cropDrag = nil
        quadDrag = nil
        pinDrag = nil
        layerDrag = nil
        layerMode = "move"
        layerPhotos = []
        watermarkLogo = nil
        samplers = []
        zoomPercent = 0
        viewCenter = MaskPoint(0.5, 0.5)
        loupe = nil
    }

    /// The photo being edited as decoded (its type, raw or not, As Shot), when it came from the library.
    private var pictureInfo: LibraryStore.Decoded?

    /// At launch: the photo being edited when the app was last used, with its edit.
    private func resumeLibrary() {
        guard let id = library.current, let photo = library.photo(id) else { return }
        state = photo.edit ?? EditState()
        interpreter.workspace.history = EditHistory(state, registry: registry)
        showLibraryPhoto(id)
        render()
    }

    // MARK: - Pro camera (Camera panel)

    /// The manual settings, 0 = automatic: ISO, shutter speed (1/N s), focus (1…100), white balance (K).
    var cameraSettings: [Double] {
        ["cameraISO", "shutterSpeed", "focusDistance", "cameraKelvin"].map { id in registry.control(id: id).map { state.value(of: $0) } ?? 0 }
    }

    /// Capture Raw is on.
    var capturesRaw: Bool { isOn("captureRaw") }

    /// "2026-11-21 10-00-05": names photos taken with the Pro camera.
    static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return format.string(from: Date())
    }

    // MARK: - Tethered capture (Camera panel)

    /// What the last Tethered Shot did (the render gallery's manifest).
    private var lastShot = ""

    /// Tethered Capture on or off: connected cameras' new shots come in while it is on.
    private func syncTethering() {
        let on = isOn("tetheredCapture")
        if cameras.tethered != on { cameras.tethered = on }
    }

    /// Fires the connected camera's shutter; the shot comes in when Tethered Capture is on.
    private func tetheredShot() {
        let fired = cameras.takePicture { [weak self] problem in
            guard let problem else { return }
            Task { @MainActor in self?.feedback = Feedback(text: "The camera didn't take the shot: \(problem)", isProblem: true) }
        }
        lastShot = fired ? "fired" : "no camera"
        feedback = fired
            ? Feedback(text: "Shutter fired" + (isOn("tetheredCapture") ? ": the photo opens when the camera has it" : " · turn on Tethered Capture to bring it in"))
            : Feedback(text: "No camera connected: connect one by USB (Tethered Capture brings in each shot taken on it)", isProblem: true)
    }

    /// Writes the library (with the edit of the photo being edited) to its file.
    func saveLibrary() {
        guard keepsLibrary else { return }
        var kept = library
        if let id = kept.current { kept.store(state, for: id) }
        libraryStore.write(kept)
    }

    /// What the library did, for the feedback line.
    private func describe(_ event: LibraryEvent) -> (text: String, problem: Bool) {
        func name(_ id: String?) -> String { library.photo(id)?.name ?? "" }
        switch event {
        case .empty:
            return ("The library is empty: import photos first (Library panel → Photos, Files or Card)", true)
        case .opened(let id, let index, let count):
            let edited = library.photo(id)?.edit != nil
            return ("Photo \(index) of \(count): \(name(id))" + (edited ? " (its edit is back)" : ""), false)
        case .at(let index, let count):
            return index == 0 ? ("This photo isn't among the \(count) the library shows", false)
                : ("Photo \(index) of \(count): \(name(library.current))", false)
        case .noPhoto(let n):
            return ("No photo \(n): the library shows \(library.shown.count)", true)
        case .end(let next):
            return (next ? "That's the last photo" : "That's the first photo", true)
        case .browsed(let shown, let total):
            return ("Library: \(total) photo\(total == 1 ? "" : "s")" + (shown < total ? ", \(shown) shown" : ""), false)
        case .notInLibrary:
            return ("This photo isn't in the library: import it first (Library panel → Photos, Files or Card)", true)
        case .rated(let stars):
            return (stars == 0 ? "No stars" : String(repeating: "★", count: stars) + " (\(stars) star\(stars == 1 ? "" : "s"))", false)
        case .flagged(let flag):
            return (flag == 1 ? "Flagged as a pick" : flag == -1 ? "Rejected" : "Flag removed", false)
        case .labelled(let label):
            return (label.isEmpty ? "Label removed" : "Label: \(label.capitalized)", false)
        case .filtered(let shown, let total):
            return ("Showing \(shown) of \(total) photos" + (library.filter.isEmpty ? "" : ": " + Self.describe(library.filter)), false)
        case .albumMade(let name):
            return ("New album “\(name)”", false)
        case .addedToAlbum(let name):
            return ("In album “\(name)” (\(library.albums.first { $0.name == name }?.photos.count ?? 0) photos)", false)
        case .removedFromAlbum(let name):
            return ("Taken out of album “\(name)”", false)
        case .notInAlbum(let name):
            return ("This photo isn't in album “\(name)”", true)
        case .albumDeleted(let name):
            return ("Album “\(name)” deleted (its photos stay in the library)", false)
        case .albumExists(let name):
            return ("There is an album called “\(name)” already: say “add to album \(name)”", true)
        case .noAlbum(let word):
            return (word.isEmpty ? "Say the album's name, e.g. “album trips”" : "No album called “\(word)”", true)
        case .albumChoices(let word, let names):
            return ("“\(word)” could be: " + names.map { "“\($0)”" }.joined(separator: ", "), true)
        case .albums(let names):
            return (names.isEmpty ? "No albums yet: say “new album …”" : "Albums: " + names.joined(separator: ", "), false)
        case .keywordsAdded(let words):
            let all = library.photo(library.current)?.keywords ?? []
            return ((words.isEmpty ? "Keywords unchanged" : "Keywords added: " + words.joined(separator: ", ")) + " · now: " + all.joined(separator: ", "), false)
        case .keywordRemoved(let word):
            return ("Keyword “\(word)” removed", false)
        case .noKeyword(let word):
            return ("This photo has no keyword “\(word)”", true)
        case .keywords(let words):
            return (words.isEmpty ? "No keywords yet: say “keyword beach”" : "Keywords: " + words.joined(separator: ", "), false)
        case .described(let field, let value):
            return (field.capitalized + (value.isEmpty ? ": none" : ": “\(value)”"), false)
        case .info:
            return ("Info: " + photoInfo, false)
        case .selected(let count):
            return (count == 0 ? "No photos selected" : "\(count) photo\(count == 1 ? "" : "s") selected · “stack these” stacks them", false)
        case .stacked(let count):
            return ("Stacked \(count) photos", false)
        case .nothingToStack:
            return ("Nothing to stack: select photos first (long press their thumbnails, or “select photo 3”); with none selected, the photos taken within \(Workflow.number(library.stackGap)) s of this one are stacked", true)
        case .autoStacked(let stacks, let photos, let gap):
            return (stacks == 0 ? "No photos taken within \(Workflow.number(gap)) s of each other"
                    : "Auto Stack: \(stacks) stack\(stacks == 1 ? "" : "s") of \(photos) photos (taken within \(Workflow.number(gap)) s of each other)", false)
        case .unstacked(let count):
            return (count == 0 ? "This photo isn't in a stack" : "Unstacked \(count) photos", count == 0)
        case .stacksExpanded(let open):
            return (open ? "Stacks expanded: every photo shows" : "Stacks collapsed: one photo of each shows", false)
        case .exportNamed(let name):
            return (name.isEmpty ? "Say the name, e.g. “export name Trip”" : "Exports are named “\(name)-001”, “\(name)-002”…", name.isEmpty)
        case .mapShown(let located, let shown):
            return (located == 0 ? "None of the \(shown) photos shown says where it was taken"
                    : "Map: \(located) of \(shown) photos say where they were taken · tap one to edit it", located == 0)
        }
    }

    /// The camera data, when and where the photo being edited was taken.
    var photoInfo: String {
        guard let photo = library.photo(library.current) else { return "this photo isn't in the library" }
        var parts = [photo.name]
        let camera = PhotoMetadata.summary(photo.camera)
        if !camera.isEmpty { parts.append(camera) }
        if let w = photo.camera.width, let h = photo.camera.height { parts.append("\(w) × \(h)") }
        if let date = photo.captured { parts.append("taken " + PhotoMetadata.exifText(date)) }
        if let lat = photo.latitude, let lon = photo.longitude { parts.append(String(format: "%.4f, %.4f", lat, lon)) }
        return parts.joined(separator: " · ")
    }

    /// The filter in words ("3+ stars · picks · red label").
    static func describe(_ filter: LibraryFilter) -> String {
        var parts: [String] = []
        if filter.minRating > 0 { parts.append("\(filter.minRating)+ star\(filter.minRating == 1 ? "" : "s")") }
        if filter.flag != "all" { parts.append(filter.flag) }
        if !filter.label.isEmpty { parts.append(filter.label + " label") }
        if !filter.album.isEmpty { parts.append("album “\(filter.album)”") }
        if !filter.keyword.isEmpty { parts.append("keyword “\(filter.keyword)”") }
        return parts.isEmpty ? "all photos" : parts.joined(separator: " · ")
    }

    /// For a raw photo: its camera's white balance (the presets are relative to it).
    private var rawNote: String {
        guard let info = pictureInfo, info.isRaw else { return "" }
        return " · raw" + (info.asShotKelvin.map { ", shot at \(Int($0.rounded())) K (As Shot)" } ?? "")
    }

    /// Library and export details for the render gallery's manifest (checked as "field" expectations).
    func galleryFields() -> [String: String] {
        var out: [String: String] = [:]
        let lib = library
        out["library.count"] = String(lib.photos.count)
        out["library.shown"] = String(lib.shown.count)
        out["photo.index"] = String(lib.currentIndex ?? 0)
        if let photo = lib.photo(lib.current) {
            out["photo.name"] = photo.name
            out["photo.rating"] = String(photo.rating)
            out["photo.flag"] = String(photo.flag)
            out["photo.label"] = photo.label
            out["photo.albums"] = lib.albums(of: photo.id).joined(separator: ", ")
            out["photo.keywords"] = photo.keywords.joined(separator: ", ")
            out["photo.title"] = photo.title
            out["photo.caption"] = photo.caption
            out["photo.copyright"] = photo.copyright
            out["photo.camera"] = PhotoMetadata.summary(photo.camera)
            out["photo.captured"] = photo.captured.map { PhotoMetadata.exifText($0) } ?? ""
            if let lat = photo.latitude, let lon = photo.longitude { out["photo.gps"] = String(format: "%.2f,%.2f", lat, lon) }
        }
        if !lastExported.isEmpty { out["export.saved"] = lastExported }
        if let url = shareFile { out["export.shared"] = url.lastPathComponent }
        if let file = fileToSave { out["export.files"] = file.name }
        if !lastPrint.isEmpty { out["print.job"] = lastPrint }
        out["color.working"] = renderer.context.workingColorSpace?.name.map { $0 as String } ?? ""
        out["export.presets"] = interpreter.workspace.exportPresets.map(\.name).joined(separator: ", ")
        out["camera.tethered"] = cameras.tethered ? "on" : "off"
        if showsCamera { out["ui.camera"] = "shown" }
        out["camera.shots"] = String(cameraShots)
        out["camera.devices"] = String(cameras.count)
        if !lastShot.isEmpty { out["camera.shot"] = lastShot }
        out["library.stacks"] = String(lib.stacks.count)
        out["library.located"] = String(lib.located.count)
        if showsMap { out["ui.map"] = "shown" }
        out["library.selected"] = String(lib.selected.count)
        if let id = lib.current { out["photo.stack"] = String(lib.stackCount(of: id)) }
        out["library.albums"] = lib.albums.map { "\($0.name):\($0.photos.count)" }.joined(separator: ", ")
        out["library.filter"] = Self.describe(lib.filter)
        if let info = pictureInfo {
            out["photo.type"] = info.type ?? ""
            out["photo.raw"] = info.isRaw ? "yes" : "no"
            out["photo.width"] = String(Int(info.image.extent.width))
            out["photo.height"] = String(Int(info.image.extent.height))
            if let kelvin = info.asShotKelvin { out["photo.asShot"] = String(Int(kelvin.rounded())) }
        }
        if let importer { out["ui.importer"] = importer }
        if let revealedPanel { out["ui.panel"] = revealedPanel }
        return out
    }

    // MARK: - Portrait depth

    /// The depth map and portrait matte an iPhone Portrait photo keeps in its file (nil without them).
    private static func depth(in data: Data, context: CIContext) -> Portrait.DepthMap? {
        func aux(_ key: CIImageOption) -> CIImage? {
            CIImage(data: data, options: [key: true, .applyOrientationProperty: true])
        }
        let matte = aux(.auxiliaryPortraitEffectsMatte)
        if let disparity = aux(.auxiliaryDisparity) {
            return PortraitRenderer.depthMap(disparity: disparity, isDepth: false, matte: matte, context: context)
        }
        if let depth = aux(.auxiliaryDepth) {
            return PortraitRenderer.depthMap(disparity: depth, isDepth: true, matte: matte, context: context)
        }
        return nil
    }

    /// A depth (disparity) picture for the photo, and its matte (the render gallery's made-up portrait).
    func useDepth(disparity: CIImage, matte: CIImage? = nil) {
        renderer.portrait.depth = PortraitRenderer.depthMap(disparity: disparity, isDepth: false, matte: matte, context: renderer.context)
        render()
    }

    /// Says so when a Portrait or Live Photo setting is used on a photo that has no depth or video.
    private func noteMissingInputs(_ outcomes: [CommandInterpreter.Outcome]) {
        var ids: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .changed(let id, _, _), .ran(let id), .unchanged(let id, _): ids.append(id)
            default: break
            }
        }
        let sections = Set(ids.compactMap { registry.control(id: $0) }.filter { $0.group == "merge" }.compactMap(\.section))
        var note: String?
        if sections.contains("Portrait"), renderer.portrait.depth == nil {
            note = "this photo has no depth data (take it in Portrait mode on an iPhone)"
        } else if sections.contains("Live Photo"), livePhoto == nil {
            note = "open a Live Photo first"
        }
        if let note {
            feedback = Feedback(text: (feedback.map { $0.text + " · " } ?? "") + note, isProblem: true)
        }
    }

    // MARK: - Live Photo

    /// The Live Photo opened (its photo and video frames), or nil.
    @Published private(set) var livePhoto: LiveFrames?

    /// A Live Photo picked in the library: its video is read, and the Live Photo effects work on it.
    func openLive(_ live: PHLivePhoto) async {
        guard let url = await LiveFrames.pairedVideo(of: live), let frames = await LiveFrames.load(still: opened, video: url) else { return }
        useLive(frames)
    }

    /// Edits a Live Photo: its effect and key frame (Merge panel) decide the photo being edited.
    func useLive(_ frames: LiveFrames) {
        livePhoto = frames
        merged = ("live", [])  // worked out on the next render, with the current settings
        render()
        feedback = Feedback(text: "Live Photo: \(frames.count) frames · say “live photo loop”, “bounce”, “long exposure” or “key frame 12”")
    }

    /// A Live Photo effect, or the key frame, becomes the photo being edited.
    private func mergeLive() {
        guard let live = livePhoto else {
            merged = nil
            return
        }
        merged = ("live", mergeKey("live"))
        mergeJob += 1
        let job = mergeJob
        let value = currentValue
        let merger = self.merger
        let lens = Self.lens(of: live.still)
        let done = "Live Photo: " + optionLabel("livePhotoEffect")
        if waitsForMerge {
            finishMerge(merger.live(live, value: value), name: "Live Photo", done: done, count: 1, lens: lens, job: job)
            return
        }
        isMerging = true
        mergeQueue.async {
            let result = merger.live(live, value: value)
            Task { @MainActor in
                self.finishMerge(result, name: "Live Photo", done: done, count: 1, lens: lens, job: job)
            }
        }
    }

    /// The label of a choice's current option.
    private func optionLabel(_ id: String) -> String {
        guard let control = registry.control(id: id) else { return "" }
        let i = Int(state.value(of: control))
        return control.options.indices.contains(i) ? control.options[i].label : ""
    }

    /// The Live Photo effect chosen (Live when no Live Photo is open).
    private var liveEffect: LivePhoto.Effect {
        guard livePhoto != nil, let control = registry.control(id: "livePhotoEffect") else { return .live }
        let i = Int(state.value(of: control))
        return LivePhoto.effects.indices.contains(i) ? LivePhoto.Effect(rawValue: LivePhoto.effects[i]) ?? .live : .live
    }

    /// Loop or Bounce: the Live Photo's video as an animated GIF with the edits (sliders, masks,
    /// geometry; not retouching), saved to Photos. Made off the main thread with a renderer of its own.
    private func saveAnimation(_ live: LiveFrames, _ effect: LivePhoto.Effect) {
        let name = effect == .loop ? "loop" : "bounce"
        feedback = Feedback(text: "Saving the \(name)…")
        let value = currentValue, masks = state.masks, geometry = state.geometry, lens = renderer.lens
        let layers = state.layers, photos = layerPhotos.map { $0.full }, words = state.watermarkText, logo = watermarkLogo?.full
        mergeQueue.async {
            let exporter = PhotoRenderer()
            exporter.lens = lens
            let data = live.gif(effect, side: 720, context: exporter.context) { frame in
                exporter.apply(to: frame, value: value, masks: masks, geometry: geometry, layers: layers, layerPhotos: photos,
                               watermark: words, logo: logo)
            }
            Task { @MainActor in
                guard let data else {
                    self.feedback = Feedback(text: "Couldn't make the \(name).", isProblem: true)
                    return
                }
                self.saveToPhotos([data], done: "Saved the \(name) to Photos (an animated GIF).")
            }
        }
    }

    /// Edits another picture (a photo opened, or a merge's result); the sliders stay as they are.
    private func replacePhoto(_ image: CIImage, lens: PhotoLens) {
        original = image
        previewSource = PhotoRenderer.downscaled(image, maxSide: previewSide)
        renderer.geometry.photoGeneration += 1
        renderer.lens = lens
        installActions()
    }

    // MARK: - Presets

    /// The user's own presets, oldest first.
    var userPresets: [Preset] { interpreter.workspace.presets }
    /// The built-in presets, pack by pack.
    var builtInPresets: [Preset] { interpreter.workspace.packs }

    /// Where the user's presets are kept.
    private static var presetsFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("presets.json")
    }

    /// Where the user's export presets are kept.
    private static var exportPresetsFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("export-presets.json")
    }

    private static func readPresets(_ file: URL) -> [Preset] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }

    /// Writes the presets and export presets when they changed (saved, renamed, deleted).
    private func writePresets() {
        guard keepsPresets else { return }
        let presets = interpreter.workspace.presets
        if presets != savedPresets, let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: Self.presetsFile, options: .atomic)
            savedPresets = presets
        }
        let exports = interpreter.workspace.exportPresets
        if exports != savedExportPresets, let data = try? JSONEncoder().encode(exports) {
            try? data.write(to: Self.exportPresetsFile, options: .atomic)
            savedExportPresets = exports
        }
    }

    /// What a workspace event says on the feedback line.
    private func describe(_ event: WorkflowEvent) -> (text: String, problem: Bool) {
        func panels(_ groups: [String]) -> String {
            groups.isEmpty ? "no panels" : groups.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ", ")
        }
        switch event {
        case .presetApplied(let name, let amount, let changes):
            return ("Preset “\(name)” at \(Int(amount)) % (\(changes) setting\(changes == 1 ? "" : "s") changed)", false)
        case .presetSaved(let name, let groups):
            return ("Saved preset “\(name)”: \(panels(groups))", false)
        case .presetRenamed(let from, let to):
            return ("Preset “\(from)” is now “\(to)”", false)
        case .presetDeleted(let name):
            return ("Preset “\(name)” deleted", false)
        case .noPreset(let word):
            return (word.isEmpty ? "Say the preset's name, e.g. “preset portra”" : "No preset called “\(word)”", true)
        case .presetChoices(let word, let names):
            return ("“\(word)” could be: " + names.map { "“\($0)”" }.joined(separator: ", "), true)
        case .builtInPreset(let name):
            return ("“\(name)” is a built-in preset: it can't be renamed or deleted", true)
        case .copied(let groups):
            return ("Copied: \(panels(groups)) (say “paste settings” on another photo)", false)
        case .pasted(let changes):
            return ("Pasted (\(changes) setting\(changes == 1 ? "" : "s") changed)", false)
        case .nothingCopied:
            return ("Nothing copied yet: say “copy settings” first", true)
        case .previousApplied(let changes):
            return ("Previous: the last photo's edit (\(changes) setting\(changes == 1 ? "" : "s") changed)", false)
        case .noPrevious:
            return ("No previous photo yet: open another photo first", true)
        case .undone(let labels):
            return (labels.count == 1 ? "Undo “\(labels[0])”" : "Undo \(labels.count) steps", false)
        case .redone(let labels):
            return (labels.count == 1 ? "Redo “\(labels[0])”" : "Redo \(labels.count) steps", false)
        case .nothingToUndo:
            return ("Nothing to undo", true)
        case .nothingToRedo:
            return ("Nothing to redo", true)
        case .historyJumped(let step, let label):
            return ("History: step \(step), “\(label)”", false)
        case .panelShown(let group):
            guard let shown = group ?? focusedControlID.flatMap({ registry.control(id: $0) }).map(panel(for:)) else {
                return ("Say which panel, e.g. “light panel”, “show layers”, “open export”", true)
            }
            return ("\(Self.panelTitle(shown)) panel", false)
        case .historyShown(let steps):
            return ("History: \(steps) step\(steps == 1 ? "" : "s") · say “history 2” to go to step 2, “history 0” for the photo as opened", false)
        case .noHistoryStep(let n):
            return ("No step \(n): the history has \(historySteps.count - 1)", true)
        case .snapshotSaved(let name):
            return ("Snapshot “\(name)” saved (say “restore snapshot \(name)” to come back to it)", false)
        case .snapshotRestored(let name):
            return ("Snapshot “\(name)” restored", false)
        case .snapshotDeleted(let name):
            return ("Snapshot “\(name)” deleted", false)
        case .noSnapshot(let word):
            return (word.isEmpty ? "Say the snapshot's name or number, e.g. “restore snapshot 1”" : "No snapshot called “\(word)”", true)
        case .snapshotChoices(let word, let names), .copyChoices(let word, let names):
            return ("“\(word)” could be: " + names.map { "“\($0)”" }.joined(separator: ", "), true)
        case .copyMade(let name):
            return ("Virtual copy “\(name)”: a new edit of this photo, with its own history (“go to copy original” goes back)", false)
        case .copySwitched(let name):
            return ("Editing copy “\(name)”", false)
        case .copyDeleted(let name):
            return ("Copy “\(name)” deleted", false)
        case .noCopy(let word):
            return (copyNames.count == 1 ? "No virtual copies yet: say “virtual copy …”" : "No copy called “\(word)”", true)
        case .lastCopy:
            return ("The photo's only edit can't be deleted", true)
        case .library(let event):
            return describe(event)
        case .exportPresetSaved(let name):
            return ("Saved export preset “\(name)” (say “export preset \(name)” to use it)", false)
        case .exportPresetApplied(let name, let changes):
            return ("Export preset “\(name)” (\(changes) setting\(changes == 1 ? "" : "s") changed)", false)
        case .exportPresetDeleted(let name):
            return ("Export preset “\(name)” deleted", false)
        case .noExportPreset(let word):
            return (word.isEmpty ? "Say the export preset's name, e.g. “export preset web”" : "No export preset called “\(word)”", true)
        case .exportPresetChoices(let word, let names):
            return ("“\(word)” could be: " + names.map { "“\($0)”" }.joined(separator: ", "), true)
        case .builtInExportPreset(let name):
            return ("“\(name)” is a built-in export preset: it can't be deleted", true)
        }
    }

    /// The user's export presets, then the built-in ones (Export panel).
    var exportPresets: [Preset] { interpreter.workspace.allExportPresets }

    /// How many of the export presets are the user's (the rest are built in).
    var userExportPresetCount: Int { interpreter.workspace.exportPresets.count }

    // MARK: - Batch (the photos picked)

    /// The pictures the last batch made (the render gallery shows the first one).
    private(set) var lastBatch: [CIImage] = []

    /// Batch Edit: the panels of this edit that the Include switches choose (as Copy Settings takes
    /// them) on every photo picked (Merge or Layers panel), each saved to Photos as a JPEG; the photo
    /// being edited stays as it is. Worked out in the background with a renderer of its own (the
    /// render gallery waits and keeps the pictures instead of saving them).
    /// Match Exposures (`matching`) also moves each photo's Exposure by the stops between its brightness
    /// and this photo's, both before any edit (MatchExposure), so the set looks evenly exposed.
    private func batchEdit(matching: Bool = false) {
        let photos = mergePhotos
        let name = matching ? "Match Exposures" : "Batch Edit"
        guard !photos.isEmpty else {
            feedback = Feedback(text: "Pick the photos first (Merge or Layers panel → Pick Photos), then say “\(name.lowercased())”.", isProblem: true)
            return
        }
        let registry = self.registry
        let bundle = Preset.capture(state, name: "Batch", groups: Presets.included(state, registry: registry), registry: registry)
        var edits: [EditState] = photos.map { _ in
            var edit = EditState()
            bundle.apply(to: &edit, registry: registry)
            return edit
        }
        if matching, let exposure = registry.control(id: "exposure") {
            let context = renderer.context
            let reference = MatchExposure.key(rgba: ImageStats.linearPixels(of: previewSource, context: context))
            for i in photos.indices {
                let stops = MatchExposure.stops(reference: reference, photo: MatchExposure.key(rgba: ImageStats.linearPixels(of: photos[i], context: context)))
                edits[i].set(exposure, to: edits[i].value(of: exposure) + (stops * 100).rounded() / 100)
            }
        }
        let lenses = photos.map { Self.lens(of: $0) }
        let layerPhotos = self.layerPhotos.map { $0.full }, logo = watermarkLogo?.full
        let count = photos.count
        if waitsForMerge {
            lastBatch = Self.renderBatch(photos, edits: edits, lenses: lenses, registry: registry, layerPhotos: layerPhotos, logo: logo,
                                    with: PhotoRenderer())
            feedback = Feedback(text: "\(name): \(count) photo\(count == 1 ? "" : "s") edited")
            return
        }
        let ppis = edits.map { edit in registry.control(id: "resolution").map { edit.value(of: $0) } ?? 72 }
        feedback = Feedback(text: "\(name): editing \(count) photo\(count == 1 ? "" : "s")…")
        mergeQueue.async {
            let exporter = PhotoRenderer()
            let pictures = Self.renderBatch(photos, edits: edits, lenses: lenses, registry: registry, layerPhotos: layerPhotos, logo: logo,
                                       with: exporter)
            let files = pictures.indices.compactMap { Self.jpeg(pictures[$0], context: exporter.context, ppi: ppis[$0]) }
            Task { @MainActor in
                guard !files.isEmpty else {
                    self.feedback = Feedback(text: "\(name): couldn't render the photos.", isProblem: true)
                    return
                }
                self.saveToPhotos(files, done: "\(name): saved \(files.count) edited photo\(files.count == 1 ? "" : "s") to Photos.")
            }
        }
    }

    /// Each photo with its own edit, by `exporter` (a renderer of the batch's own).
    nonisolated private static func renderBatch(_ photos: [CIImage], edits: [EditState], lenses: [PhotoLens], registry: ControlRegistry,
                                           layerPhotos: [CIImage], logo: CIImage?, with exporter: PhotoRenderer) -> [CIImage] {
        photos.indices.map { i in
            let edit = edits[i]
            exporter.lens = lenses[i]
            return exporter.apply(to: photos[i], value: { id in registry.control(id: id).map { edit.value(of: $0) } },
                                  masks: edit.masks, retouches: edit.retouches, geometry: edit.geometry, layers: edit.layers,
                                  layerPhotos: layerPhotos, watermark: edit.watermarkText, logo: logo)
        }
    }

    // MARK: - Merge (HDR, …)

    /// Photos picked for merging, in the order they were picked.
    @Published private(set) var mergePhotos: [CIImage] = []
    /// A merge is being worked out (in the background).
    @Published private(set) var isMerging = false
    /// Work out merges before showing the preview (the render gallery), instead of in the background.
    var waitsForMerge = false
    /// The merge that made the photo being edited and the settings it used (nil: the photo as opened).
    private var merged: (kind: String, key: [Double])?
    /// Counts merge jobs, so only the newest one's result is used.
    private var mergeJob = 0
    private lazy var merger = MergeRenderer(context: renderer.context)
    private let mergeQueue = DispatchQueue(label: "merge", qos: .userInitiated)

    /// Photos picked for merging (the Merge panel's photo picker, or the render gallery).
    func pickForMerge(_ photos: [CIImage]) {
        mergePhotos = photos
        feedback = Feedback(text: photos.count == 1 ? "1 photo picked for merging"
                            : "\(photos.count) photos picked for merging: say or tap a merge, e.g. “HDR Merge”")
    }

    /// Photos picked in the photo library for merging (their files), in the order picked.
    func pickForMerge(files: [Data]) {
        let photos = files.compactMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
        guard !photos.isEmpty else {
            feedback = Feedback(text: "Those files couldn't be opened as photos.", isProblem: true)
            return
        }
        pickForMerge(photos)
    }

    /// The fewest photos a kind of merge needs.
    private static func minimumPhotos(_ kind: String) -> Int {
        switch kind {
        case "hdrPanorama": return 4
        case "double": return 1  // one picked photo goes over the photo as opened
        case "collage": return 2  // the photo as opened and at least one picked
        default: return 2
        }
    }

    /// The settings a kind of merge reads, as numbers (when they change, the photo it made is merged again).
    private func mergeKey(_ kind: String) -> [Double] {
        MergeTools.settings(for: kind).map { id in registry.control(id: id).map { state.value(of: $0) } ?? 0 }
    }

    /// Merges the photos picked (the last "Photos to Merge" of them) and edits the result; every other
    /// panel then works on it. Runs in the background (the gallery waits).
    private func merge(_ kind: String) {
        if kind == "live" {
            mergeLive()
            return
        }
        let count = registry.control(id: MergeTools.countID).map { state.value(of: $0) } ?? 0
        var photos = MergeTools.chosen(mergePhotos, count: count)
        if kind == "double", photos.count == 1 { photos.insert(opened, at: 0) }
        // A collage starts with the photo as opened, then the photos picked.
        if kind == "collage" { photos.insert(opened, at: 0) }
        let needed = Self.minimumPhotos(kind)
        guard photos.count >= needed else {
            // The photo stays as it is (a merge made before is no longer redone).
            merged = nil
            feedback = Feedback(text: kind == "collage" ? "Pick at least 1 photo for the collage first (Layers panel → Pick Photos)."
                                : "Pick at least \(needed) photos to merge first (Merge panel → Pick Photos to Merge).", isProblem: true)
            return
        }
        merged = (kind, mergeKey(kind))
        mergeJob += 1
        let job = mergeJob
        let value = currentValue
        let merger = self.merger
        let name = MergeTools.actions.first { $0.value == kind }.flatMap { registry.control(id: $0.key)?.label } ?? "Merge"
        // A panorama's photos point different ways: no lens correction fits the result.
        let lens = ["panorama", "hdrPanorama", "collage"].contains(kind) ? PhotoLens() : Self.lens(of: photos[0])
        let done = kind == "collage" ? "Collage of \(photos.count) photos: every panel now edits it" : "\(name): \(photos.count) photos merged"
        if waitsForMerge {
            finishMerge(merger.merge(kind, photos: photos, value: value), name: name, done: done, count: photos.count, lens: lens, job: job)
            return
        }
        isMerging = true
        feedback = Feedback(text: "\(name): merging \(photos.count) photos…")
        mergeQueue.async {
            let result = merger.merge(kind, photos: photos, value: value)
            Task { @MainActor in
                self.finishMerge(result, name: name, done: done, count: photos.count, lens: lens, job: job)
            }
        }
    }

    /// A merge finished: its result becomes the photo being edited (only the newest job's), with the
    /// lens of the first photo merged; `done` is said when all `count` photos went in.
    private func finishMerge(_ result: MergeRenderer.Merged?, name: String, done: String, count: Int, lens: PhotoLens, job: Int) {
        guard job == mergeJob else { return }
        isMerging = false
        guard let result, !result.image.extent.isEmpty else {
            merged = nil
            feedback = Feedback(text: "\(name): these photos couldn't be merged (do they overlap?).", isProblem: true)
            return
        }
        replacePhoto(result.image, lens: lens)
        feedback = Feedback(text: result.used < count ? "\(name): \(result.used) of \(count) photos fitted together" : done)
        render()
    }

    /// Renders the full-resolution photo and saves it to the photo library.
    /// With HDR on it saves a 10-bit HEIF that keeps the brighter-than-white levels.
    func save() {
        if let live = livePhoto, liveEffect == .loop || liveEffect == .bounce {
            saveAnimation(live, liveEffect)
            return
        }
        let edited = editedPhoto()
        if isHDR {
            guard let data = renderer.hdrHEIF(edited) else {
                feedback = Feedback(text: "Couldn't render the HDR photo.", isProblem: true)
                return
            }
            saveToPhotos([data], done: "Saved HDR photo to Photos.")
            return
        }
        // The Export panel's format, size, sharpening and metadata, with the Resolution written in.
        guard let file = exportFile(edited) else {
            feedback = Feedback(text: "Couldn't render the photo.", isProblem: true)
            return
        }
        interpreter.workspace.library.exportCount += 1
        saveLibrary()
        lastExported = file.name
        guard exportsFiles else {
            feedback = Feedback(text: "Exported \(file.name)")
            return
        }
        saveToPhotos([file.data], names: [file.name], done: "Saved \(file.name) to Photos" + (file.note.map { " (\($0))" } ?? "") + ".")
    }

    /// Save To Files: the photo as the Export panel says, in the Files app's save dialog (where to keep it).
    func saveToFiles() {
        guard let file = exportFile() else {
            feedback = Feedback(text: "Couldn't render the photo.", isProblem: true)
            return
        }
        interpreter.workspace.library.exportCount += 1
        saveLibrary()
        lastExported = file.name
        feedback = Feedback(text: "Save \(file.name): choose where in Files" + (file.note.map { " (\($0))" } ?? ""))
        fileToSave = (ExportDocument(data: file.data), UTType(file.type) ?? .jpeg, file.name)
    }

    /// The Export panel's Print settings.
    var printSetup: PrintSetup {
        func v(_ id: String) -> Double { registry.control(id: id).map { state.value(of: $0) } ?? 0 }
        return PrintSetup(size: ExportSettings.option(PrintLayout.sizes, v("printSize")), fill: v("printFit") == 1, marginMM: v("printMargins"))
    }

    /// The photo as it prints: as exported (output sharpening and all), at full size.
    func printPicture() -> CIImage {
        var options = exportOptions
        options.longEdge = 0
        options.percent = 100
        return Exporter.prepare(editedPhoto(), options: options)
    }

    /// What the last Print did (the render gallery's manifest).
    private var lastPrint = ""

    /// Print: AirPrint's dialog with the photo laid out as Print Size, Print Layout and Print Margins say.
    func printPhoto() {
        let picture = printPicture()
        guard let cg = renderer.context.createCGImage(picture, from: picture.extent.integral) else {
            feedback = Feedback(text: "Couldn't render the photo.", isProblem: true)
            return
        }
        let name = library.photo(library.current)?.name ?? "Photo"
        lastPrint = "ready"
        let setup = printSetup
        feedback = Feedback(text: "Print \(name): " + (setup.size == "page" ? "as large as the page allows" : setup.size)
                            + (setup.fill ? ", filling it" : "") + ", \(Int(setup.marginMM)) mm margins")
        guard exportsFiles else { return }
        PhotoPrinter.present(UIImage(cgImage: cg), name: name, setup: setup) { [weak self] message in
            Task { @MainActor in self?.feedback = Feedback(text: message) }
        }
    }

    /// The Files app saved the export.
    func saved(to url: URL) {
        feedback = Feedback(text: "Saved \(url.lastPathComponent) in Files")
    }

    /// Share: the photo as the Export panel says, as a file named as it says, in the share sheet.
    func share() {
        guard let file = exportFile() else {
            feedback = Feedback(text: "Couldn't render the photo.", isProblem: true)
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file.name)
        do {
            try file.data.write(to: url, options: .atomic)
        } catch {
            feedback = Feedback(text: "Couldn't make the file to share.", isProblem: true)
            return
        }
        interpreter.workspace.library.exportCount += 1
        saveLibrary()
        lastExported = file.name
        feedback = Feedback(text: "Sharing \(file.name)" + (file.note.map { " (\($0))" } ?? ""))
        shareFile = url
    }

    /// The full-size edited photo.
    private func editedPhoto() -> CIImage {
        renderer.apply(to: original, value: currentValue, masks: state.masks, retouches: state.retouches,
                       geometry: state.geometry, layers: state.layers, layerPhotos: layerPhotos.map { $0.full },
                       watermark: state.watermarkText, logo: watermarkLogo?.full)
    }

    /// The Export panel's settings.
    var exportOptions: ExportOptions {
        func v(_ id: String) -> Double { registry.control(id: id).map { state.value(of: $0) } ?? 0 }
        var o = ExportOptions()
        o.format = ExportSettings.option(ExportSettings.formats, v("exportFormat"))
        o.quality = v("exportQuality") / 100
        o.longEdge = v("exportLongEdge")
        o.percent = v("exportScale")
        o.sharpening = ExportSettings.option(ExportSettings.media, v("outputSharpening"))
        o.sharpenAmount = ExportSettings.option(ExportSettings.amounts, v("sharpenAmount"))
        o.metadata = ExportSettings.option(ExportSettings.metadata, v("exportMetadata"))
        o.removeLocation = v("removeLocation") != 0
        o.naming = ExportSettings.option(ExportSettings.namings, v("fileNaming"))
        o.colorSpace = ExportSettings.option(ExportSettings.colorSpaces, v("outputColorSpace"))
        o.bits = v("bitDepth") >= 1 ? 16 : 8
        return o
    }

    /// The photo as the Export panel says (format, quality, size, output sharpening, metadata, name), with
    /// the camera data and date of the file opened, its place (unless Remove Location), and the library's
    /// title, caption, keywords and copyright. A format this iPad can't write becomes JPEG (said in `note`).
    func exportFile(_ rendered: CIImage? = nil) -> ExportedFile? {
        let o = exportOptions
        let format = Exporter.isWritable(o.format) ? o.format : "jpeg"
        let bits = ExportSettings.bits(format: format, wanted: o.bits)
        var notes: [String] = []
        if format != o.format { notes.append("\(o.format.uppercased()) can't be written on this iPad: JPEG instead") }
        if bits < o.bits { notes.append("\(format.uppercased()) holds \(bits) bits per channel") }
        let note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        let picture = Exporter.prepare(rendered ?? editedPhoto(), options: o)
        let ppi = registry.control(id: "resolution").map { state.value(of: $0) } ?? 72
        let photo = library.photo(library.current)
        let all = PhotoMetadata.properties(for: photo, original: pictureInfo?.properties ?? original.properties,
                                           removeLocation: o.removeLocation, ppi: ppi)
        let type = ExportSettings.types[format] ?? UTType.jpeg.identifier
        guard let data = Exporter.encode(picture, context: renderer.context, type: type, quality: o.quality,
                                         properties: ExportSettings.filtered(all, keep: o.metadata),
                                         space: Exporter.colorSpace(o.colorSpace), bits: bits) else { return nil }
        let name = ExportSettings.fileName(original: photo?.name ?? "Photo", naming: o.naming, custom: library.exportName, date: Date(),
                                           sequence: library.exportCount + 1, ext: ExportSettings.extensions[format] ?? "jpg")
        return ExportedFile(data: data, type: type, name: name, note: note)
    }

    /// JPEG bytes (quality 0.92) with the resolution (pixels per inch) written into them.
    nonisolated static func jpeg(_ image: CIImage, context: CIContext, ppi: Double) -> Data? {
        let data = NSMutableData()
        guard let cg = context.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92,
                                           kCGImagePropertyDPIWidth: ppi, kCGImagePropertyDPIHeight: ppi]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Adds photo files to the photo library.
    private func saveToPhotos(_ files: [Data], names: [String] = [], done: String) {
        // The model lives as long as the app, so these closures may hold it.
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self.feedback = Feedback(text: "Photo library access is off.", isProblem: true)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for (i, data) in files.enumerated() {
                    // The file's name as exported (Photos shows it as the original name).
                    let options = PHAssetResourceCreationOptions()
                    if names.indices.contains(i) { options.originalFilename = names[i] }
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
                }
            }, completionHandler: { ok, _ in
                Task { @MainActor in
                    self.feedback = Feedback(text: ok ? done : "Couldn't save to Photos.", isProblem: !ok)
                }
            })
        }
    }

    /// The lens a photo was taken with, from its EXIF data (Lens Profile Correction).
    static func lens(of image: CIImage) -> PhotoLens {
        lens(properties: image.properties)
    }

    /// The lens in a file's properties (EXIF and TIFF dictionaries).
    static func lens(properties: [String: Any]) -> PhotoLens {
        let exif = properties["{Exif}"] as? [String: Any]
        let tiff = properties["{TIFF}"] as? [String: Any]
        return PhotoLens(make: tiff?["Make"] as? String,
                         lensModel: exif?["LensModel"] as? String,
                         focal: (exif?["FocalLength"] as? NSNumber)?.doubleValue,
                         aperture: (exif?["FNumber"] as? NSNumber)?.doubleValue)
    }

    /// Said after Lens Profile Correction is turned on: which profile, or why there is none.
    private var lensNote: String {
        if let name = renderer.lensProfileName { return "profile: \(name)" }
        if let model = renderer.lens.lensModel { return "no profile for \(model)" }
        return "no lens information in this photo"
    }

    /// Whether the HDR toggle is on (preview and saving keep levels above SDR white).
    var isHDR: Bool {
        registry.control(id: "hdr").map { state.value(of: $0) != 0 } ?? false
    }

    /// The preview photo with the current edits (not yet turned into pixels).
    func editedPreview() -> CIImage {
        let edited = renderer.apply(to: previewSource, value: currentValue, masks: state.masks, overlay: overlayMask,
                                    retouches: state.retouches, waitForRetouch: waitsForRetouch, visualize: visualizeThreshold,
                                    geometry: state.geometry, stage: geometryStage, previewScale: previewScale,
                                    layers: state.layers, layerPhotos: layerPhotos.map { $0.preview },
                                    watermark: state.watermarkText, logo: watermarkLogo?.preview)
        previewPlan = renderer.lastPlan
        return edited
    }

    /// What the screen shows: the edited preview with the View panel's overlays (before / after, …),
    /// and zoomed as on screen (the screen zooms the picture itself; the render gallery gets it here).
    func shownPreview() -> CIImage {
        let edited = editedPreview()
        previewLong = Double(max(edited.extent.width, edited.extent.height))
        let shown = self.shown(edited)
        return magnification > 1 ? ViewRenderer.zoomed(shown, to: visibleRect, magnification: magnification) : shown
    }

    private func shown(_ edited: CIImage) -> CIImage {
        viewRenderer.apply(edited, before: isHDR ? previewSource : previewSource.applyingFilter("CIColorClamp"), value: currentValue,
                           samplers: samplers)
    }

    /// Whether a View panel switch is on.
    private func isOn(_ id: String) -> Bool {
        registry.control(id: id).map { state.value(of: $0) != 0 } ?? false
    }

    /// The scopes that are on, from a small copy of the edited preview as sRGB levels.
    private func readScopes(_ edited: CIImage) {
        guard isOn("histogram") || isOn("clippingWarning") || isOn("vectorscope") || !samplers.isEmpty else {
            scopes = nil
            return
        }
        var readings = ScopeReadings()
        readings.samples = samplers.enumerated().map { "\($0.offset + 1): " + sample(edited, at: $0.element) }
        guard isOn("histogram") || isOn("clippingWarning") || isOn("vectorscope") else {
            scopes = readings
            return
        }
        let bytes = ImageStats.srgbBytes(of: edited, context: renderer.context)
        if isOn("histogram") {
            let h = Scopes.histogram(rgba: bytes)
            readings.histogram = (Scopes.heights(h.red), Scopes.heights(h.green), Scopes.heights(h.blue), Scopes.heights(h.luma))
        }
        if isOn("clippingWarning") { readings.clipping = Scopes.clippedShares(rgba: bytes) }
        if isOn("vectorscope") { readings.vectorscope = (64, Scopes.intensities(Scopes.vectorscope(rgba: bytes, size: 64))) }
        scopes = readings
    }

    /// A colour sampler's readout at a point of the edited picture (a small square's average).
    private func sample(_ edited: CIImage, at p: MaskPoint) -> String {
        let color = ImageStats.averageColor(of: edited, in: Self.spot(p.x, p.y, in: edited.extent), context: renderer.context).encoded
        let read = Scopes.readout(color.r, color.g, color.b)
        return String(format: "R %d G %d B %d · L %.0f a %.0f b %.0f", read.rgb[0], read.rgb[1], read.rgb[2], read.lab[0], read.lab[1], read.lab[2])
    }

    // MARK: - Zoom (View panel)

    /// The zoom, in % of the photo's own pixels (0 = fit), and the middle of the part shown (0…1 from
    /// the top-left of the picture).
    @Published private(set) var zoomPercent: Double = 0
    @Published private(set) var viewCenter = MaskPoint(0.5, 0.5)
    /// The part shown rendered from the full-size photo, when zoomed in past the preview's own pixels.
    @Published private(set) var loupe: (image: UIImage, rect: ViewRect)?
    /// The picture's long side on screen when it fits, in pixels (the canvas measures it; 0: the preview's).
    private(set) var fitPixels: Double = 0
    /// The preview's long side in pixels, as last rendered.
    private var previewLong: Double = 0
    private var pinchBase: Double?
    private var panBase: MaskPoint?
    private var loupeJob = 0
    private lazy var loupeRenderer = PhotoRenderer()
    private let loupeQueue = DispatchQueue(label: "loupe", qos: .userInitiated)

    /// The finished picture's long side at full size, in pixels.
    private var fullLong: Double { previewLong / max(previewScale, 1e-6) }

    /// How many times larger than fit the picture shows.
    var magnification: Double {
        Viewport.magnification(percent: zoomPercent, full: fullLong, fit: fitPixels > 0 ? fitPixels : previewLong)
    }

    /// The part of the picture shown (shares from the top-left).
    var visibleRect: ViewRect {
        Viewport.visible(magnification: magnification, center: (viewCenter.x, viewCenter.y))
    }

    /// No tool, picker or comparison takes the touches on the photo (then they pan and zoom).
    var touchesFree: Bool {
        armedPicker == nil && targetedMode == nil && geometryTool == nil && retouchTool == nil && canvasTool == nil && layerCanvasTool == nil
            && !isComparing
    }

    // MARK: - Targeted adjustment (View panel)

    /// The Targeted Adjustment mode in use ("saturation", …), or nil: then drags on the photo change it.
    var targetedMode: String? {
        guard armedPicker == nil, let control = registry.control(id: "targetedAdjustment") else { return nil }
        let i = Int(state.value(of: control))
        return i > 0 && TargetedAdjustment.modes.indices.contains(i) ? TargetedAdjustment.modes[i] : nil
    }

    /// Where the current targeted drag began: the colour there and the values it started from.
    private var targetedBase: (color: RGB, values: [String: Double])?

    /// A drag on the photo with Targeted Adjustment: up raises, down lowers the controls acting on the
    /// tone or colour where it began (TargetedAdjustment), from their values then.
    private func targetedDraw(_ mode: String, _ shown: [MaskPoint], finished: Bool) {
        guard let start = shown.first, let end = shown.last else { return }
        let base: (color: RGB, values: [String: Double])
        if let began = targetedBase {
            base = began
        } else {
            let edited = editedPreview()
            let color = ImageStats.averageColor(of: edited, in: Self.spot(start.x, start.y, in: edited.extent), context: renderer.context).encoded
            var values: [String: Double] = [:]
            for target in TargetedAdjustment.targets(mode: mode, color: color) {
                values[target.id] = registry.control(id: target.id).map { state.current($0) } ?? 0
            }
            base = (color, values)
        }
        targetedBase = finished ? nil : base
        let new = TargetedAdjustment.values(mode: mode, color: base.color, rise: start.y - end.y) { base.values[$0] ?? 0 }
        guard !new.isEmpty else {
            feedback = Feedback(text: "That spot is grey: drag on a coloured part (or use Tone Curve)", isProblem: true)
            return
        }
        var said: [String] = []
        for id in new.keys.sorted() {
            guard let control = registry.control(id: id), let target = state.target(for: control), let v = new[id] else { continue }
            said.append("\(control.label) \(Self.format(state.set(control, to: v, at: target), control))")
        }
        feedback = Feedback(text: said.joined(separator: " · "))
        render()
    }

    /// A drag pans the photo: zoomed in and no tool takes the touches.
    var canPan: Bool { touchesFree && magnification > 1 }

    /// The canvas measured the fitted picture.
    func setFit(pixels: Double) {
        guard abs(pixels - fitPixels) > 0.5 else { return }
        fitPixels = pixels
        updateLoupe()
    }

    /// Two fingers pinching: `factor` since they touched.
    func pinch(_ factor: Double) {
        let base = pinchBase ?? magnification
        pinchBase = base
        let fit = Viewport.fitPercent(full: fullLong, fit: fitPixels > 0 ? fitPixels : previewLong)
        let m = min(32, max(1, base * factor))
        zoomPercent = m <= 1.001 ? 0 : m * fit
        loupe = nil
    }

    func endPinch() {
        pinchBase = nil
        updateLoupe()
    }

    /// A finger dragging the zoomed photo by `translation` points over a picture `size` points big.
    func pan(by translation: CGSize, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let base = panBase ?? viewCenter
        panBase = base
        let m = magnification
        viewCenter = MaskPoint(base.x - Double(translation.width / size.width) / m, base.y - Double(translation.height / size.height) / m)
        loupe = nil
    }

    func endPan() {
        panBase = nil
        // Keep the middle where the view stopped (it can't leave the picture).
        let r = visibleRect
        viewCenter = MaskPoint(r.x + r.width / 2, r.y + r.height / 2)
        updateLoupe()
    }

    /// A double tap: zoomed in, back to fit; at fit, 100 % (or the first level above fit) around the point.
    func toggleLoupe(at point: MaskPoint) {
        if magnification > 1 {
            setZoom(0)
        } else {
            let fit = Viewport.fitPercent(full: fullLong, fit: fitPixels > 0 ? fitPixels : previewLong)
            setZoom(100 > fit + 0.5 ? 3 : Viewport.firstLevel(above: fit), center: point)
        }
    }

    /// Zoom to a level of the Zoom choice (0 = fit), around `center` when given; `rendering`: show it now
    /// (after a command the render follows anyway).
    private func setZoom(_ index: Int, center: MaskPoint? = nil, rendering: Bool = true) {
        guard Viewport.levels.indices.contains(index) else { return }
        if let zoom = registry.control(id: "zoom") { state.set(zoom, to: Double(index)) }
        zoomPercent = Viewport.levels[index]
        if let center { viewCenter = center }
        if index == 0 { viewCenter = MaskPoint(0.5, 0.5) }
        loupe = nil
        if rendering { render() }
    }

    /// "zoom 200", "zoom in", "fit": the Zoom choice changed (zooming in from fit skips levels smaller than fit).
    private func followZoom(_ outcomes: [CommandInterpreter.Outcome]) {
        for outcome in outcomes {
            switch outcome {
            case .changed("zoom", let from, let to):
                let fit = Viewport.fitPercent(full: fullLong, fit: fitPixels > 0 ? fitPixels : previewLong)
                var index = Int(to)
                if to > from, Viewport.levels.indices.contains(index), Viewport.levels[index] <= fit + 0.5 {
                    index = Viewport.firstLevel(above: fit)
                }
                setZoom(index, rendering: false)
            case .ran("zoomFit"):
                setZoom(0, rendering: false)
            default:
                break
            }
        }
    }

    /// Zoomed in past the preview's own pixels: renders the part shown from the full-size photo, in the
    /// background with a renderer of its own, a moment after the last change (pans and edits settle first).
    private func updateLoupe() {
        loupeJob += 1
        let job = loupeJob
        loupe = nil  // an older rendering would show an older edit or place
        guard showsPreview, previewLong > 0, magnification * (fitPixels > 0 ? fitPixels : previewLong) > previewLong * 1.05 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, job == self.loupeJob else { return }
            let rect = self.visibleRect, value = self.currentValue, state = self.state, original = self.original
            let photos = self.layerPhotos.map { $0.full }, logo = self.watermarkLogo?.full
            let exporter = self.loupeRenderer
            exporter.lens = self.renderer.lens
            self.loupeQueue.async {
                let output = exporter.apply(to: original, value: value, masks: state.masks, retouches: state.retouches, geometry: state.geometry,
                                            layers: state.layers, layerPhotos: photos, watermark: state.watermarkText, logo: logo)
                let e = output.extent
                let area = CGRect(x: e.minX + CGFloat(rect.x) * e.width, y: e.minY + CGFloat(1 - rect.y - rect.height) * e.height,
                                  width: CGFloat(rect.width) * e.width, height: CGFloat(rect.height) * e.height).integral.intersection(e)
                let cg = exporter.context.createCGImage(output, from: area)
                Task { @MainActor in
                    guard job == self.loupeJob, let cg else { return }
                    self.loupe = (UIImage(cgImage: cg), rect)
                }
            }
        }
    }

    /// Before / after is on: touches on the photo do nothing (it isn't the picture being edited).
    var isComparing: Bool {
        ["showBefore", "compare"].contains { id in registry.control(id: id).map { state.value(of: $0) != 0 } ?? false }
    }

    /// The Before button is held down (or let go).
    func holdBefore(_ held: Bool) {
        guard let before = registry.control(id: "showBefore") else { return }
        setFromSlider(before, to: held ? 1 : 0)
    }

    /// Visualize Spots' threshold while it is on (the preview only shows it).
    private var visualizeThreshold: Double? {
        guard let on = registry.control(id: "visualizeSpots"), state.value(of: on) != 0 else { return nil }
        return registry.control(id: "visualizeThreshold").map { state.value(of: $0) } ?? 50
    }

    /// The mask shown as a red tint: the selected one, while Mask Overlay is on.
    private var overlayMask: Mask? {
        guard let overlay = registry.control(id: "maskOverlay"), state.value(of: overlay) != 0,
              let m = state.selectedMask else { return nil }
        return state.masks[m]
    }

    /// Looks up a control's current value by id; nil when controls.json has no such control.
    private var currentValue: (String) -> Double? {
        { [state, registry] id in
            registry.control(id: id).map { state.value(of: $0) }
        }
    }

    private func render() {
        // A selected mask or retouch tool takes the touches on the photo instead of a geometry tool.
        if geometryTool != nil, state.selectedMask != nil || state.retouchTool != nil || state.selectedLayer != nil { geometryTool = nil }
        // A merge's setting changed ("deghost high"): merge again.
        if let merged, mergeKey(merged.kind) != merged.key { merge(merged.kind) }
        // History: a touch edit is a step (a drag's renders merge into one); after a command, what the
        // app added (a placed photo's picture, …) belongs to the step the interpreter made.
        if let label = historyLabel {
            interpreter.record(state, label: label, key: historyKey)
            if historySeal { interpreter.workspace.history.seal() }
        } else {
            interpreter.workspace.history.amend(state)
        }
        historyLabel = nil
        historyKey = nil
        historySeal = false
        syncTethering()
        let edited = editedPreview()
        previewLong = Double(max(edited.extent.width, edited.extent.height))
        if showsPreview {
            preview = renderer.uiImage(shown(edited), hdr: isHDR)
            readScopes(edited)
            updateLoupe()
        }
        pinRetouchSources()
        writePresets()
    }

    /// Spots whose source the canvas picked keep it in the edit: it stays put when other spots change,
    /// shows on the photo, and the saved photo copies from the same place.
    private func pinRetouchSources() {
        guard let done = renderer.retouch.finished, !done.sources.isEmpty, done.steps == state.retouches else { return }
        for (i, offset) in done.sources where state.retouches.indices.contains(i) && state.retouches[i].offset == nil {
            state.retouches[i].offset = offset
        }
    }

    private func describe(_ outcomes: [CommandInterpreter.Outcome]) -> Feedback {
        // A whole panel reset: one line, not every slider.
        if outcomes.contains(.ran(controlID: "resetPanel")) {
            let changed = outcomes.filter { if case .changed = $0 { return true } else { return false } }.count
            let panel = registry.control(id: "resetPanel")?.options.first { option in
                outcomes.contains { if case .changed(let id, _, _) = $0 { return registry.control(id: id)?.group == option.id } else { return false } }
            }?.label
            return Feedback(text: "\(panel.map { $0 + " panel" } ?? "Panel") reset (\(changed) setting\(changed == 1 ? "" : "s"))")
        }
        var parts: [String] = []
        var choices: [Control] = []
        var problem = false
        for outcome in outcomes {
            switch outcome {
            case .changed(EditState.maskSelectorID, _, let to):
                parts.append(to == 0 ? "Global sliders" : "Mask \(Int(to)) selected: local sliders")
            case .changedInMask(let mask, let id, let from, let to):
                let control = registry.control(id: id)
                parts.append("Mask \(mask) · \(control?.label ?? id) \(Self.format(from, control)) → \(Self.format(to, control))")
            case .masked(let mask, let event):
                parts.append(describe(event, mask: mask))
            case .needsMask(let id):
                let control = registry.control(id: id)
                if control?.scope == "component", let kind = control?.component {
                    parts.append("No \(label(ofPart: kind)) in the selected mask")
                } else {
                    parts.append("Select a mask first, e.g. “mask 1”")
                }
                problem = true
            case .ran(let id) where registry.control(id: id)?.group == "masks":
                break  // described by its .masked outcome
            case .ran(let id) where GeometryTools.actions[id] != nil:
                // A geometry tool: what to do with it.
                let tool = GeometryTools.actions[id] ?? ""
                parts.append((registry.control(id: id)?.label ?? id) + (Self.geometryHints[tool].map { ": " + $0 } ?? ""))
            case .ran(let id) where registry.control(id: id)?.group == "retouch":
                // A tool: what to do with it; other actions are described by their .retouched outcome.
                if let tool = registry.control(id: id)?.tool {
                    parts.append(label(ofTool: tool) + (Self.toolHints[tool].map { ": " + $0 } ?? ""))
                }
            case .changedInSpot(let spot, let id, let from, let to):
                let control = registry.control(id: id)
                parts.append("Spot \(spot) · \(control?.label ?? id) \(Self.format(from, control)) → \(Self.format(to, control))")
            case .retouched(let spot, let event):
                switch event {
                case .deleted: parts.append("Spot \(spot) deleted")
                case .allDeleted: parts.append("Spots deleted")
                }
            case .needsSpot:
                parts.append(state.retouches.isEmpty ? "No spots yet" : "Select a spot first, e.g. “spot 1”")
                problem = true
            case .changed(EditState.layerSelectorID, _, let to):
                parts.append(to == 0 ? "No layer selected" : "Layer \(Int(to)) selected: " + layerName(Int(to) - 1))
            case .changedInLayer(let layer, let id, let from, let to):
                let control = registry.control(id: id)
                parts.append("Layer \(layer) · \(control?.label ?? id) \(Self.format(from, control)) → \(Self.format(to, control))")
            case .layered(let layer, let event):
                parts.append(describe(event, layer: layer))
            case .needsLayer(let id):
                if let kind = registry.control(id: id)?.layer, !state.layers.isEmpty {
                    parts.append("No \(Layers.title(of: kind).lowercased()) layer yet")
                } else {
                    parts.append(state.layers.isEmpty ? "No layers yet" : "Select a layer first, e.g. “layer 1”")
                }
                problem = true
            case .ran(let id) where registry.control(id: id)?.group == "layers":
                break  // described by its .layered outcome (or by the app: a photo placed)
            case .changed(let id, let from, let to):
                let control = registry.control(id: id)
                var text = "\(control?.label ?? id) \(Self.format(from, control)) → \(Self.format(to, control))"
                if id == "lensProfile", to != 0 { text += " (\(lensNote))" }
                parts.append(text)
            case .ran(let id) where Workspace.actions.contains(id):
                break  // described by its .workflow outcome
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
            case .workflow(let event):
                let said = describe(event)
                parts.append(said.text)
                problem = problem || said.problem
            }
        }
        if parts.isEmpty { parts = ["Nothing to do"] }
        return Feedback(text: parts.joined(separator: " · "), choices: choices, isProblem: problem)
    }

    private func describe(_ event: LayerEvent, layer: Int) -> String {
        switch event {
        case .created(let kind):
            return "Layer \(layer): new \(Layers.title(of: kind).lowercased())" + (Self.layerHints[kind].map { " · " + $0 } ?? "")
        case .deleted: return "Layer \(layer) deleted"
        case .duplicated(let from): return "Layer \(layer): copy of Layer \(from)"
        case .moved(let to): return "Layer moved to \(to) of \(state.layers.count)"
        case .hidden: return "Layer \(layer) hidden"
        case .textChanged: return "Layer \(layer): “\(state.layers.indices.contains(layer - 1) ? state.layers[layer - 1].text : "")”"
        case .masked(let part):
            switch part {
            case "none": return "Layer \(layer): mask removed"
            case "invert": return "Layer \(layer): mask inverted"
            case "brush": return "Layer \(layer): paint its mask on the picture (Brush Size, Eraser)"
            default: return "Layer \(layer): shows at the \(part == "center" ? "middle" : part)"
            }
        case .noMask: return "Layer \(layer) has no mask (say “layer mask top”, “layer mask brush”, …)"
        case .deselected: return "No layer selected"
        case .allDeleted: return "Layers deleted"
        }
    }

    /// A layer's name for the panel and the feedback line ("Photo", …).
    func layerName(_ index: Int) -> String {
        guard state.layers.indices.contains(index) else { return "" }
        let layer = state.layers[index]
        if layer.kind == "text" { return "Text “\(layer.text)”" }
        if layer.kind == "sticker", let control = registry.control(id: "addSticker"),
           control.options.indices.contains(Int(layer.value("sticker", 0))) {
            return "Sticker " + control.options[Int(layer.value("sticker", 0))].label
        }
        return Layers.title(of: layer.kind)
    }

    /// Changes the selected text layer's words (the panel's text field), as “edit text …” would.
    func setLayerText(_ text: String) {
        apply([.run("editText", text: text)])
    }

    /// What to do on the photo with a new layer of a kind.
    static let layerHints: [String: String] = [
        "photo": "drag it to move it; Layer Scale, Layer Rotation and Layer Opacity change it",
        "adjustment": "the sliders a mask holds (exposure, contrast, …) now change everything below it; “layer mask top” limits it",
        "text": "drag it to move it; “edit text …”, Text Size, Text Font and Text Colour change it",
        "paint": "paint on the picture with a finger or the Pencil (press harder for a wider line, lean it over to shade); Brush Colour and Paint Size",
        "fill": "Fill Colour, Fill End Colour and Fill Angle change it; Layer Opacity and Layer Blend mix it in; “layer mask top” fills only part",
        "sticker": "drag it to move it; Layer Scale and Layer Rotation change it, the layer styles dress it up",
        "shape": "drag it to move it; Shape Width, Height, Fill and Line Width change it (pen: tap corners, drag for curves, tap the first point to close)",
    ]

    private func describe(_ event: MaskEvent, mask: Int) -> String {
        switch event {
        case .created(let kind):
            return "Mask \(mask): new \(label(ofPart: kind))" + (Self.hints[kind].map { " · " + $0 } ?? "")
        case .added(let kind, let mode):
            return "Mask \(mask): \(mode.rawValue) \(label(ofPart: kind))" + (Self.hints[kind].map { " · " + $0 } ?? "")
        case .deleted: return "Mask \(mask) deleted"
        case .duplicated(let from): return "Mask \(mask): copy of Mask \(from)"
        case .partDeleted: return "Mask \(mask): part deleted"
        case .deselected: return "Global sliders"
        case .allDeleted: return "Masks deleted"
        }
    }

    /// What to do on the photo with a retouch tool.
    static let toolHints: [String: String] = [
        "remove": "paint over what to remove",
        "heal": "tap or paint over a spot; it takes texture from nearby, matched to the colours around it (“clone source”, then tap, to choose where from)",
        "clone": "tap or paint; it copies pixels exactly from nearby (“clone source”, then tap, to choose where from)",
        "patch": "draw around the flaw, then drag from inside it to a clean area (without a drag it takes texture from nearby)",
        "move": "draw around the object, then drag from inside it to where it should go; its old place is filled in",
        "redEye": "tap the middle of a red eye with a brush about the eye's size, or draw around the eye",
        "petEye": "tap a glowing pet eye with a brush about the eye's size, or draw around the eye",
        "liquify": "drag to push, or hold still (tap) to twirl, pucker, bloat or reconstruct; Liquify Mode and Tool Strength set how",
        "dodge": "paint to lighten (up to a stop at full Tool Strength), mostly in the Tone Range; press harder with the Pencil for more",
        "burn": "paint to darken (up to a stop at full Tool Strength), mostly in the Tone Range; press harder with the Pencil for more",
        "sponge": "paint to add colour or take it away (Sponge Mode), as much as Tool Strength and the Pencil's pressure say",
        "blurBrush": "paint to soften detail (more with Tool Strength and Pencil pressure)",
        "sharpenBrush": "paint to crispen detail (more with Tool Strength and Pencil pressure)",
        "smudge": "drag to smear colours along the stroke, like a finger through wet paint",
    ]

    /// What to do on the photo with a Geometry panel tool.
    static let geometryHints: [String: String] = [
        "crop": "drag a corner or edge, or inside the box to move it (it keeps the Crop Aspect); “done” when finished",
        "straighten": "draw a line along something that should be level (a horizon) or upright; the photo turns to match",
        "guides": "draw up to four lines along edges that should be upright or level (two upright ones straighten converging walls); “clear guides” to start again",
        "perspective": "drag the four corners onto the corners of the tilted page, picture or wall; “done” squares it up",
        "warp": "drag the grid's handles to bend the picture (the outer ones hold the edges); “reset warp” to start again",
        "puppet": "tap to pin the picture where it should stay, then drag a pin to bend it; “reset warp” clears the pins",
    ]

    /// What to do on the photo after making a mask part.
    static let hints: [String: String] = [
        "brush": "paint on the photo",
        "linear": "drag on the photo from where it is full to where it ends",
        "radial": "drag inside it to move it, outside to resize it",
        "colorRange": "tap the colour to select (or say a colour: “color range blue”)",
        "luminanceRange": "tap a brightness to select around it, or set Low and High",
        "lasso": "draw around the area",
        "polygon": "tap the corners; tap the first one again to close",
        "rectangle": "drag from one corner to the other",
        "ellipse": "drag from one corner of its box to the other",
        "magicWand": "tap the area to select",
        "quickSelect": "paint over the area; it grows out to its edges",
    ]

    nonisolated static func format(_ value: Double, _ control: Control?) -> String {
        let step = control?.step ?? 1
        let decimals = step < 0.1 ? 2 : step < 1 ? 1 : 0
        return String(format: "%.\(decimals)f", value)
    }
}
