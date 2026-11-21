import CoreImage
import CommandEngine
import ImageIO
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
    /// The Geometry panel's touch tool in use ("crop", …; see GeometryTools), or nil.
    @Published private(set) var geometryTool: String?
    /// The geometry of the shown preview: touches on it map back to the photo through it.
    @Published private(set) var previewPlan: GeometryPlan?
    /// What touches do to the selected layer: "move" (drag it), … (see `layerCanvasTool`).
    @Published private(set) var layerMode = "move"

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
    /// Work out retouch steps before showing the preview (the render gallery), instead of in the background.
    var waitsForRetouch = false
    /// Turn each render into the on-screen picture (the render gallery only saves the last one).
    var showsPreview = true
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
        self.opened = start
        self.previewSide = previewSide
        self.previewSource = PhotoRenderer.downscaled(start, maxSide: previewSide)
        renderer.lens = Self.lens(of: start)
        installActions()
        // Retouch steps are worked out in the background: show them when they are ready.
        renderer.retouch.onFinish = { [weak self] in
            Task { @MainActor in self?.render() }
        }
        render()

        // Launch argument used by the cloud build to screenshot a command's effect.
        if let demo = UserDefaults.standard.string(forKey: "demoCommand") {
            run(demo)
        }
    }

    /// The value a slider shows: while a mask is selected, its own value for local sliders.
    func value(of control: Control) -> Double {
        state.current(control)
    }

    func setFromSlider(_ control: Control, to value: Double) {
        guard let target = state.target(for: control) else {
            feedback = describe([.needsMask(controlID: control.id)])
            return
        }
        state.set(control, to: value, at: target)
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
        geometryTool = nil
        dragBase = nil
        cropDrag = nil
        quadDrag = nil
        pinDrag = nil
        layerDrag = nil
        layerMode = "move"
        layerPhotos = []
        mergePhotos = []
        livePhoto = nil
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
    func draw(_ shown: [MaskPoint], pressure: [Double] = [], finished: Bool = true) {
        if let tool = geometryTool {
            geometryDraw(tool, shown, finished: finished)
            return
        }
        // Layers live on the finished picture itself: the shown points are theirs.
        if retouchTool == nil, canvasTool == nil, let tool = layerCanvasTool {
            layerDraw(tool, shown, pressure: pressure, finished: finished)
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

    /// A drag on the picture with a layer selected (points on the shown picture, 0…1): moves it.
    private func layerDraw(_ tool: String, _ points: [MaskPoint], pressure: [Double], finished: Bool) {
        guard let l = state.selectedLayer, let start = points.first, let end = points.last else { return }
        switch tool {
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

    /// The eye in the layer list: shows or hides a layer.
    func toggleLayerVisible(_ index: Int) {
        guard state.layers.indices.contains(index) else { return }
        state.layers[index].values["layerVisible"] = state.layers[index].isVisible ? 0 : 1
        render()
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
            case .ran("placePhoto"):
                placePhoto(interpreter.lastCommands.first { $0.control == "placePhoto" }?.value)
            case .layered(_, .created), .layered(_, .duplicated), .changed(EditState.layerSelectorID, _, _):
                layerMode = "move"
            default:
                break
            }
        }
        if state.selectedLayer != nil { geometryTool = nil }
    }

    /// A photo picked (the last one, or "place photo 2": the second) becomes a new layer on top.
    private func placePhoto(_ number: Double?) {
        guard !mergePhotos.isEmpty else {
            feedback = Feedback(text: "Pick a photo first (Layers panel → Pick Photos).", isProblem: true)
            return
        }
        let i = number.map { Int($0) - 1 }.flatMap { mergePhotos.indices.contains($0) ? $0 : nil } ?? mergePhotos.count - 1
        let photo = mergePhotos[i]
        layerPhotos.append((photo, PhotoRenderer.downscaled(photo, maxSide: previewSide)))
        var layer = Layers.make("photo", registry: registry)
        layer.values["photo"] = Double(layerPhotos.count - 1)
        state.layers.append(layer)
        state.selectLayer(state.layers.count - 1)
        layerMode = "move"
        feedback = Feedback(text: "Layer \(state.layers.count): photo placed · " + (Self.layerHints["photo"] ?? ""))
    }

    // MARK: - Pickers (tap the photo)

    /// Picker tools and what they ask the user to tap.
    static let pickers: [String: String] = [
        "wbPicker": "Tap something on the photo that should be neutral grey.",
        "pointColorPicker": "Tap the colour on the photo you want to change.",
        "spotSource": "Tap where the selected spot should copy from.",
        "portraitFocus": "Tap what should be sharp: the depth there becomes the Focus Depth.",
        CreativeFilters.centerPicker: centerHint,
    ]

    /// What the Effect Center picker asks.
    static let centerHint = "Tap the photo where the effect's centre should be."

    /// A picker that ran (by button, voice or typing) now waits for a tap on the photo.
    private func armPickers(_ outcomes: [CommandInterpreter.Outcome]) {
        armGeometryTools(outcomes)
        armLayerTools(outcomes)
        noteMissingInputs(outcomes)
        for case .ran(let id) in outcomes {
            if let kind = MergeTools.actions[id] { merge(kind) }
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
    }

    /// The photo was tapped while a picker waited, or for the selected mask part (a colour range's
    /// sample): `x`, `y` from the top-left corner, 0…1.
    func tap(atX shownX: Double, y shownY: Double) {
        guard let picker = armedPicker else {
            draw([MaskPoint(shownX, shownY)])
            return
        }
        armedPicker = nil
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
        opened = image
        merged = nil
        livePhoto = nil
        mergeJob += 1
        isMerging = false
        replacePhoto(image, lens: Self.lens(of: image))
        renderer.portrait.depth = Self.depth(in: data, context: renderer.context)
        render()
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
        let layers = state.layers, photos = layerPhotos.map { $0.full }
        mergeQueue.async {
            let exporter = PhotoRenderer()
            exporter.lens = lens
            let data = live.gif(effect, side: 720, context: exporter.context) { frame in
                exporter.apply(to: frame, value: value, masks: masks, geometry: geometry, layers: layers, layerPhotos: photos)
            }
            Task { @MainActor in
                guard let data else {
                    self.feedback = Feedback(text: "Couldn't make the \(name).", isProblem: true)
                    return
                }
                self.saveToPhotos(data, done: "Saved the \(name) to Photos (an animated GIF).")
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
        let needed = Self.minimumPhotos(kind)
        guard photos.count >= needed else {
            // The photo stays as it is (a merge made before is no longer redone).
            merged = nil
            feedback = Feedback(text: "Pick at least \(needed) photos to merge first (Merge panel → Pick Photos to Merge).", isProblem: true)
            return
        }
        merged = (kind, mergeKey(kind))
        mergeJob += 1
        let job = mergeJob
        let value = currentValue
        let merger = self.merger
        let name = MergeTools.actions.first { $0.value == kind }.flatMap { registry.control(id: $0.key)?.label } ?? "Merge"
        // A panorama's photos point different ways: no lens correction fits the result.
        let lens = kind == "panorama" || kind == "hdrPanorama" ? PhotoLens() : Self.lens(of: photos[0])
        let done = "\(name): \(photos.count) photos merged"
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
        let edited = renderer.apply(to: original, value: currentValue, masks: state.masks, retouches: state.retouches,
                                    geometry: state.geometry, layers: state.layers, layerPhotos: layerPhotos.map { $0.full })
        if isHDR {
            guard let data = renderer.hdrHEIF(edited) else {
                feedback = Feedback(text: "Couldn't render the HDR photo.", isProblem: true)
                return
            }
            saveToPhotos(data, done: "Saved HDR photo to Photos.")
            return
        }
        // A JPEG with the Resolution (pixels per inch) written into it.
        let ppi = registry.control(id: "resolution").map { state.value(of: $0) } ?? 72
        let data = NSMutableData()
        guard let cg = renderer.context.createCGImage(edited, from: edited.extent),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            feedback = Feedback(text: "Couldn't render the photo.", isProblem: true)
            return
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92,
                                           kCGImagePropertyDPIWidth: ppi, kCGImagePropertyDPIHeight: ppi]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            feedback = Feedback(text: "Couldn't render the photo.", isProblem: true)
            return
        }
        saveToPhotos(data as Data, done: "Saved to Photos.")
    }

    /// Adds a photo file to the photo library.
    private func saveToPhotos(_ data: Data, done: String) {
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
                    self.feedback = Feedback(text: ok ? done : "Couldn't save to Photos.", isProblem: !ok)
                }
            })
        }
    }

    /// The lens a photo was taken with, from its EXIF data (Lens Profile Correction).
    static func lens(of image: CIImage) -> PhotoLens {
        let exif = image.properties["{Exif}"] as? [String: Any]
        let tiff = image.properties["{TIFF}"] as? [String: Any]
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
                                    layers: state.layers, layerPhotos: layerPhotos.map { $0.preview })
        previewPlan = renderer.lastPlan
        return edited
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
        let edited = editedPreview()
        if showsPreview { preview = renderer.uiImage(edited, hdr: isHDR) }
        pinRetouchSources()
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

    private func describe(_ event: LayerEvent, layer: Int) -> String {
        switch event {
        case .created(let kind):
            return "Layer \(layer): new \(Layers.title(of: kind).lowercased())" + (Self.layerHints[kind].map { " · " + $0 } ?? "")
        case .deleted: return "Layer \(layer) deleted"
        case .duplicated(let from): return "Layer \(layer): copy of Layer \(from)"
        case .moved(let to): return "Layer moved to \(to) of \(state.layers.count)"
        case .hidden: return "Layer \(layer) hidden"
        case .deselected: return "No layer selected"
        case .allDeleted: return "Layers deleted"
        }
    }

    /// A layer's name for the panel and the feedback line ("Photo", …).
    func layerName(_ index: Int) -> String {
        guard state.layers.indices.contains(index) else { return "" }
        return Layers.title(of: state.layers[index].kind)
    }

    /// What to do on the photo with a new layer of a kind.
    static let layerHints: [String: String] = [
        "photo": "drag it to move it; Layer Scale, Layer Rotation and Layer Opacity change it",
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
