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
    /// The Geometry panel's touch tool in use ("crop", …; see GeometryTools), or nil.
    @Published private(set) var geometryTool: String?
    /// The geometry of the shown preview: touches on it map back to the photo through it.
    @Published private(set) var previewPlan: GeometryPlan?

    enum VoiceState: Equatable {
        case idle, listening, transcribing
    }

    private var interpreter: CommandInterpreter
    private var original: CIImage
    private var previewSource: CIImage
    private let previewSide: CGFloat
    let renderer = PhotoRenderer()
    /// Work out retouch steps before showing the preview (the render gallery), instead of in the background.
    var waitsForRetouch = false
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
        renderer.geometry.plan(extent: extent, value: currentValue, edits: state.geometry, stage: .full)
    }

    /// Where the photo's own coordinates lie on the shown preview (`shown`: its size on screen): the
    /// photo's size on screen and the projection from there onto the preview. Mask handles and spot
    /// outlines are drawn on the photo and projected (see SourceSpace).
    func sourceLayout(shown: CGSize) -> (size: CGSize, projection: ProjectionTransform) {
        guard let plan = previewPlan, !plan.isIdentity, plan.shapedWidth > 0, shown.width > 0 else {
            return (shown, ProjectionTransform())
        }
        let k = Double(shown.width) / plan.shapedWidth
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

    // MARK: - Pickers (tap the photo)

    /// Picker tools and what they ask the user to tap.
    static let pickers: [String: String] = [
        "wbPicker": "Tap something on the photo that should be neutral grey.",
        "pointColorPicker": "Tap the colour on the photo you want to change.",
        "spotSource": "Tap where the selected spot should copy from.",
    ]

    /// A picker that ran (by button, voice or typing) now waits for a tap on the photo.
    private func armPickers(_ outcomes: [CommandInterpreter.Outcome]) {
        armGeometryTools(outcomes)
        for case .ran(let id) in outcomes {
            if let hint = Self.pickers[id] {
                armedPicker = id
                feedback = Feedback(text: hint)
            }
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
        original = image
        previewSource = PhotoRenderer.downscaled(image, maxSide: previewSide)
        renderer.geometry.photoGeneration += 1
        renderer.lens = Self.lens(of: image)
        installActions()
        render()
    }

    /// Renders the full-resolution photo and saves it to the photo library.
    /// With HDR on it saves a 10-bit HEIF that keeps the brighter-than-white levels.
    func save() {
        let edited = renderer.apply(to: original, value: currentValue, masks: state.masks, retouches: state.retouches,
                                    geometry: state.geometry)
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
                                    geometry: state.geometry, stage: geometryStage)
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
        if geometryTool != nil, state.selectedMask != nil || state.retouchTool != nil { geometryTool = nil }
        preview = renderer.uiImage(editedPreview(), hdr: isHDR)
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
