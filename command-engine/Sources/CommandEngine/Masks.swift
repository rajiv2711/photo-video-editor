import Foundation

// Masks (local adjustments), as in Lightroom: a mask is one or more parts (a brush, a linear or
// radial gradient, a colour or brightness range, a selection) joined by add, subtract or
// intersect, refined (feather, smooth, expand), and it holds its own values of the global sliders
// that allow it (`Control.local`): exposure inside the mask, on top of the global exposure.
//
// While a mask is selected (the "mask" control, 1 = the first mask, 0 = none), every local-capable
// slider changes that mask, by touch or by name; everything else, and every slider when no mask
// is selected, is global. "done" (or "mask 0") goes back to the global sliders.
//
// The mask pictures are worked out by MaskRaster; the iPad blends the locally edited photo through them.

/// A point on the photo: x, y from the top-left corner, 0…1.
public struct MaskPoint: Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// One brush stroke (Brush, Quick select): its path and the brush settings it was painted with.
public struct MaskStroke: Hashable, Codable {
    public var points: [MaskPoint]
    /// Diameter, % of the photo's long side.
    public var size: Double
    /// Soft edge, % of the radius (0 = hard, 100 = soft all the way in).
    public var feather: Double
    /// How much each dab adds, % (a stroke builds up where it overlaps itself).
    public var flow: Double
    /// The most a stroke reaches, %.
    public var density: Double
    /// Eraser: the stroke takes the mask away.
    public var erase: Bool
    /// Auto mask: paints only on colours like the one under the brush's centre.
    public var autoMask: Bool

    public init(points: [MaskPoint], size: Double = 10, feather: Double = 50, flow: Double = 100, density: Double = 100,
                erase: Bool = false, autoMask: Bool = false) {
        self.points = points
        self.size = size
        self.feather = feather
        self.flow = flow
        self.density = density
        self.erase = erase
        self.autoMask = autoMask
    }
}

/// One part of a mask, joined to the parts before it by its mode.
public struct MaskComponent: Hashable, Codable {
    public enum Mode: String, Codable, CaseIterable {
        case add, subtract, intersect
    }

    /// "brush", "linear", "radial", "colorRange", "luminanceRange", "lasso", "polygon", "rectangle",
    /// "ellipse", "magicWand" or "quickSelect" (the `component` of the action that made it).
    public var kind: String
    /// Settings by control id ("radialSize", "componentMode", …) plus a few set by touch or presets
    /// ("left", "top", "right", "bottom" of a marquee; "hue" of a colour range preset).
    public var values: [String: Double]
    /// Brush and Quick select strokes, in painting order.
    public var strokes: [MaskStroke]
    /// Lasso and polygon lasso outline.
    public var path: [MaskPoint]
    /// A tap: Color range's sample, Magic wand's seed.
    public var point: MaskPoint?

    public init(kind: String, values: [String: Double] = [:], strokes: [MaskStroke] = [], path: [MaskPoint] = [],
                point: MaskPoint? = nil) {
        self.kind = kind
        self.values = values
        self.strokes = strokes
        self.path = path
        self.point = point
    }

    /// How it joins the parts before it (the "componentMode" choice: add, subtract, intersect).
    public var mode: Mode {
        get {
            let index = Int(values["componentMode"] ?? 0)
            return Mode.allCases.indices.contains(index) ? Mode.allCases[index] : .add
        }
        set { values["componentMode"] = Double(Mode.allCases.firstIndex(of: newValue) ?? 0) }
    }

    /// The part's own Invert (a radial gradient's outside, …).
    public var inverted: Bool {
        (values["invertComponent"] ?? 0) != 0
    }
}

/// One mask: its parts, its refine settings and its local slider values.
public struct Mask: Hashable, Codable {
    public var components: [MaskComponent]
    /// The part that touch and the part controls act on (index into `components`).
    public var selectedComponent: Int
    /// Mask settings by control id (invert, feather, smooth, expand, refine edge, amount).
    public var settings: [String: Double]
    /// Local slider values by control id (exposure, contrast, …); missing = no change.
    public var adjustments: [String: Double]

    public init(components: [MaskComponent] = [], selectedComponent: Int = 0, settings: [String: Double] = [:],
                adjustments: [String: Double] = [:]) {
        self.components = components
        self.selectedComponent = selectedComponent
        self.settings = settings
        self.adjustments = adjustments
    }

    /// The selected part, if any.
    public var component: MaskComponent? {
        components.indices.contains(selectedComponent) ? components[selectedComponent] : nil
    }

    /// Everything that decides the mask's picture (parts and settings, not the local sliders), for caching.
    public var shape: MaskShape {
        MaskShape(components: components, settings: settings)
    }
}

/// The parts and settings of a mask: equal shapes give equal mask pictures.
public struct MaskShape: Hashable {
    public let components: [MaskComponent]
    public let settings: [String: Double]
}

/// Something that happened to a mask, for the feedback line.
public enum MaskEvent: Equatable {
    /// A new mask with one part of this kind.
    case created(String)
    /// A part of this kind joined the selected mask.
    case added(String, MaskComponent.Mode)
    case deleted
    case duplicated(from: Int)
    /// The selected part was deleted (and the mask with it if it was the last).
    case partDeleted
    /// Back to the global sliders.
    case deselected
    /// "reset all" deleted every mask.
    case allDeleted
}

// MARK: - Where a control's value lives

extension EditState {
    /// The control that selects a mask: its value is the mask's number (1 = first), 0 = none.
    public static let maskSelectorID = "mask"
    /// The control that selects a part of the selected mask (1 = first).
    public static let componentSelectorID = "maskComponent"

    /// Where one control's value is stored.
    public enum Target: Hashable {
        case global
        /// A setting or local slider of the mask at this index in `masks`.
        case mask(Int)
        /// A setting of a part: mask index, part index.
        case component(Int, Int)
    }

    /// The selected mask's index in `masks`, or nil when the sliders are global.
    public var selectedMask: Int? {
        let number = Int(values[Self.maskSelectorID] ?? 0)
        return number >= 1 && number <= masks.count ? number - 1 : nil
    }

    /// Selects a mask by index (nil = global sliders).
    public mutating func selectMask(_ index: Int?) {
        let number = index.map { $0 + 1 } ?? 0
        values[Self.maskSelectorID] = Double(number)
    }

    /// Where a command on this control acts now; nil when it needs a selected mask (or a part of
    /// its kind) and there is none.
    public func target(for control: Control) -> Target? {
        switch control.scope {
        case "mask":
            return selectedMask.map { .mask($0) }
        case "component":
            guard let m = selectedMask else { return nil }
            let mask = masks[m]
            guard let kind = control.component else {
                return mask.component == nil ? nil : .component(m, mask.selectedComponent)
            }
            // The selected part when it is of this kind, else the newest part of this kind.
            if mask.component?.kind == kind { return .component(m, mask.selectedComponent) }
            return mask.components.lastIndex { $0.kind == kind }.map { .component(m, $0) }
        default:
            if control.local, let m = selectedMask { return .mask(m) }
            return .global
        }
    }

    public func value(of control: Control, at target: Target) -> Double {
        switch target {
        case .global:
            return value(of: control)
        case .mask(let m):
            guard masks.indices.contains(m) else { return control.defaultValue }
            if control.id == Self.componentSelectorID { return Double(masks[m].selectedComponent + 1) }
            let stored = control.scope == "mask" ? masks[m].settings : masks[m].adjustments
            return stored[control.id] ?? control.defaultValue
        case .component(let m, let c):
            guard masks.indices.contains(m), masks[m].components.indices.contains(c) else { return control.defaultValue }
            return masks[m].components[c].values[control.id] ?? control.defaultValue
        }
    }

    /// Sets a control where `target` says, clamped and tidied like `set(_:to:)`. Returns the stored value.
    @discardableResult
    public mutating func set(_ control: Control, to value: Double, at target: Target) -> Double {
        var stored = Self.tidy(control.clamp(value))
        switch target {
        case .global:
            set(control, to: stored)
            if control.id == Self.maskSelectorID {
                // Only masks that exist can be selected.
                stored = Swift.min(stored.rounded(), Double(masks.count))
                values[control.id] = stored
            }
        case .mask(let m):
            guard masks.indices.contains(m) else { return stored }
            if control.id == Self.componentSelectorID {
                let count = masks[m].components.count
                let number = Swift.min(Swift.max(1, Int(stored.rounded())), Swift.max(1, count))
                masks[m].selectedComponent = number - 1
                return Double(number)
            }
            if control.scope == "mask" {
                masks[m].settings[control.id] = stored
            } else {
                masks[m].adjustments[control.id] = stored
            }
        case .component(let m, let c):
            guard masks.indices.contains(m), masks[m].components.indices.contains(c) else { return stored }
            masks[m].components[c].values[control.id] = stored
        }
        return stored
    }

    /// The value a slider shows now: the selected mask's own for local sliders and mask settings,
    /// the default when there is nothing to act on.
    public func current(_ control: Control) -> Double {
        target(for: control).map { value(of: control, at: $0) } ?? control.defaultValue
    }

    // MARK: - Touch edits (the app calls these; commands go through CommandApplier)

    /// The selected part of the selected mask, if any.
    public var selectedComponent: (mask: Int, component: Int)? {
        guard let m = selectedMask, masks[m].component != nil else { return nil }
        return (m, masks[m].selectedComponent)
    }

    /// Adds a brush stroke to the selected part (a brush or quick select). Returns false when there is none.
    @discardableResult
    public mutating func addStroke(_ stroke: MaskStroke) -> Bool {
        guard let s = selectedComponent, ["brush", "quickSelect"].contains(masks[s.mask].components[s.component].kind),
              !stroke.points.isEmpty else { return false }
        masks[s.mask].components[s.component].strokes.append(stroke)
        return true
    }

    /// Sets the outline of the selected lasso or polygon lasso part.
    @discardableResult
    public mutating func setPath(_ path: [MaskPoint]) -> Bool {
        guard let s = selectedComponent, ["lasso", "polygon"].contains(masks[s.mask].components[s.component].kind),
              path.count >= 3 else { return false }
        masks[s.mask].components[s.component].path = path
        return true
    }

    /// Sets the tap point of the selected colour range or magic wand part.
    @discardableResult
    public mutating func setPoint(_ point: MaskPoint) -> Bool {
        guard let s = selectedComponent, ["colorRange", "magicWand"].contains(masks[s.mask].components[s.component].kind) else {
            return false
        }
        masks[s.mask].components[s.component].point = point
        masks[s.mask].components[s.component].values["hue"] = nil  // a tap replaces a named colour
        return true
    }

    /// Sets settings of the selected part directly (drag handles, a marquee's corners).
    public mutating func setComponentValues(_ new: [String: Double]) {
        guard let s = selectedComponent else { return }
        for (key, value) in new { masks[s.mask].components[s.component].values[key] = EditState.tidy(value) }
    }
}

// MARK: - Making parts

/// Name-based placements for new mask parts ("linear gradient from top", "radial gradient center")
/// and the drag geometry of the gradients. Positions are 0…100 % of the photo's width or height.
public enum MaskPresets {
    /// The placement used when a part is made without one.
    public static func defaultOption(for kind: String) -> String? {
        switch kind {
        case "linear": return "top"
        case "radial", "rectangle", "ellipse": return "center"
        case "luminanceRange": return "highlights"
        default: return nil
        }
    }

    /// A new part of `kind` with its controls at their defaults, joined by `mode`, placed by `option`.
    public static func component(kind: String, mode: MaskComponent.Mode, option: String?, registry: ControlRegistry) -> MaskComponent {
        var part = MaskComponent(kind: kind)
        for control in registry.controls where control.scope == "component" && control.component == kind {
            part.values[control.id] = control.defaultValue
        }
        part.mode = mode
        if let option = option ?? defaultOption(for: kind) { apply(option, to: &part) }
        return part
    }

    /// Box presets of the marquees: left, top, right, bottom (0…1).
    static let boxes: [String: [Double]] = [
        "center": [0.25, 0.25, 0.75, 0.75], "top": [0, 0, 1, 0.5], "bottom": [0, 0.5, 1, 1],
        "left": [0, 0, 0.5, 1], "right": [0.5, 0, 1, 1],
    ]

    /// Radial centres, % of width and height.
    static let spots: [String: (x: Double, y: Double)] = [
        "center": (50, 50), "top": (50, 25), "bottom": (50, 75), "left": (25, 50), "right": (75, 50),
        "topLeft": (25, 25), "topRight": (75, 25), "bottomLeft": (25, 75), "bottomRight": (75, 75),
    ]

    /// Linear gradient angles: the side the effect is full on (0 = top, turning clockwise).
    static let sides: [String: Double] = ["top": 0, "right": 90, "bottom": 180, "left": -90]

    /// Luminance ranges (low, high), luma 0…100.
    static let tones: [String: (low: Double, high: Double)] = [
        "shadows": (0, 25), "darks": (0, 50), "midtones": (25, 75), "lights": (50, 100), "highlights": (75, 100),
    ]

    /// Colour range presets: hue on the colour wheel (sRGB hue, degrees).
    static let hues: [String: Double] = [
        "red": 0, "orange": 30, "yellow": 60, "green": 120, "aqua": 180, "blue": 240, "purple": 270, "magenta": 300,
    ]

    /// Whether `option` is a placement this kind knows (used by the tests to check controls.json).
    public static func knows(_ option: String, kind: String) -> Bool {
        var probe = MaskComponent(kind: kind)
        return apply(option, to: &probe)
    }

    @discardableResult
    static func apply(_ option: String, to part: inout MaskComponent) -> Bool {
        switch part.kind {
        case "linear":
            guard let angle = sides[option] else { return false }
            part.values["linearAngle"] = angle
            part.values["linearPosition"] = 25
            part.values["linearWidth"] = 50
        case "radial":
            guard let spot = spots[option] else { return false }
            part.values["radialX"] = spot.x
            part.values["radialY"] = spot.y
        case "rectangle", "ellipse":
            guard let box = boxes[option] else { return false }
            part.values["left"] = box[0]
            part.values["top"] = box[1]
            part.values["right"] = box[2]
            part.values["bottom"] = box[3]
        case "luminanceRange":
            guard let tone = tones[option] else { return false }
            part.values["luminanceRangeLow"] = tone.low
            part.values["luminanceRangeHigh"] = tone.high
        case "colorRange":
            guard let hue = hues[option] else { return false }
            part.values["hue"] = hue
            part.point = nil
        default:
            return false
        }
        return true
    }

    /// The luminance range around a tapped brightness (luma 0…100): ±15.
    public static func luminanceRange(around luma: Double) -> (low: Double, high: Double) {
        (Swift.max(0, (luma - 15).rounded()), Swift.min(100, (luma + 15).rounded()))
    }
}

/// Converts between touch drags and the gradients' settings. Distances are measured in pixels of a
/// `width` × `height` photo, so a 45° gradient looks 45° on a wide photo too.
public enum MaskGeometry {
    /// A linear gradient drawn from `start` (full effect) to `end` (none): angle (0 = full at the
    /// top, clockwise), position and width (% of the photo's span in that direction).
    public static func linear(from start: MaskPoint, to end: MaskPoint, width: Double, height: Double)
        -> (angle: Double, position: Double, width: Double) {
        let dx = (end.x - start.x) * width, dy = (end.y - start.y) * height
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return (0, 25, 50) }
        let nx = dx / length, ny = dy / length
        // n = (−sin a, cos a): a = 0 points down (full effect at the top).
        let angle = atan2(-nx, ny) * 180 / .pi
        let span = abs(nx) * width + abs(ny) * height
        let midX = ((start.x + end.x) / 2 - 0.5) * width, midY = ((start.y + end.y) / 2 - 0.5) * height
        let position = ((midX * nx + midY * ny) / span + 0.5) * 100
        return (angle, position, length / span * 100)
    }

    /// The start (full effect) and end (none) points of a linear gradient, for drawing its handles.
    public static func linearHandles(angle: Double, position: Double, width gradientWidth: Double,
                                     width: Double, height: Double) -> (start: MaskPoint, end: MaskPoint) {
        let a = angle * .pi / 180
        let nx = -sin(a), ny = cos(a)
        let span = abs(nx) * width + abs(ny) * height
        let offset = (position / 100 - 0.5) * span, half = gradientWidth / 100 * span / 2
        func point(_ d: Double) -> MaskPoint {
            MaskPoint(0.5 + nx * d / width, 0.5 + ny * d / height)
        }
        return (point(offset - half), point(offset + half))
    }

    /// A radial gradient's two radii in pixels: `size` % of half the short side, stretched by
    /// `aspect` (−100…100: + wider, − taller, up to 2× each way).
    public static func radialRadii(size: Double, aspect: Double, width: Double, height: Double) -> (x: Double, y: Double) {
        let r = size / 100 * Swift.min(width, height) / 2
        let stretch = pow(2, aspect / 100)
        return (r * stretch, r / stretch)
    }
}
