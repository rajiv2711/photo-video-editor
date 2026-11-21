import Foundation

// Layers (the Layers panel), as in Photoshop: the developed photo (every other panel, after the crop,
// canvas and resize) is the background, and a list of layers stacks above it, the first just above
// the photo, the newest on top. Each layer is kept in the edit (`EditState.layers`) as its kind and
// settings and drawn again from them on every render, so nothing is baked in: a layer can be selected
// ("layer 2"), moved, scaled, made more transparent, hidden, put higher or lower, copied or deleted at
// any time.
//
// Layers live on the finished picture (the output canvas): positions are shares of its width and
// height from the top-left (0…100 %), sizes shares of its long side, so the preview and the saved
// photo agree. A layer's content is drawn around its centre (Layer X, Layer Y), then scaled (Layer
// Scale) and turned (Layer Rotation, clockwise). Frames (Creative panel) and the watermark go over the
// layers.
//
// While a layer is selected (the "layer" control, 1 = the lowest, 0 = none) the layer settings
// (scope "layer") change it, by touch or by name; "done" (or "layer 0") deselects it.

/// One layer: its kind, its settings by control id and what touch or words made (text, paths, strokes).
public struct Layer: Hashable, Codable {
    /// "photo" (a picked photo), …
    public var kind: String
    /// Settings by control id (layerOpacity, layerX, …) plus a few set by the action that made it
    /// ("photo": which picked photo).
    public var values: [String: Double]

    public init(kind: String, values: [String: Double] = [:]) {
        self.kind = kind
        self.values = values
    }

    /// A setting, or its default when the layer doesn't have it.
    public func value(_ id: String, _ fallback: Double) -> Double {
        values[id] ?? fallback
    }

    /// Whether it is drawn (Layer Visible).
    public var isVisible: Bool {
        (values["layerVisible"] ?? 1) != 0
    }

    /// Opacity 0…1 (Layer Opacity).
    public var opacity: Double {
        Swift.min(1, Swift.max(0, (values["layerOpacity"] ?? 100) / 100))
    }

    /// Where its content sits on the canvas and how big and turned it is.
    public var transform: LayerTransform {
        LayerTransform(x: value("layerX", 50) / 100, y: value("layerY", 50) / 100,
                       scale: Swift.max(0.01, value("layerScale", 100) / 100), angle: value("layerRotation", 0))
    }
}

/// A layer's placement: its centre (shares of the canvas width and height from the top-left), its
/// scale (1 = as made) and its turn (degrees, clockwise on screen). Content is given around the centre
/// in units of the canvas's long side ("L"), y down, before scaling and turning.
public struct LayerTransform: Equatable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public var angle: Double

    public init(x: Double = 0.5, y: Double = 0.5, scale: Double = 1, angle: Double = 0) {
        self.x = x
        self.y = y
        self.scale = scale
        self.angle = angle
    }

    /// A point of the content (L units around the centre) → canvas pixels (from the top-left).
    public func toCanvas(_ p: Vec2, width: Double, height: Double) -> Vec2 {
        let long = Swift.max(width, height), a = angle * .pi / 180
        let sx = p.x * scale * long, sy = p.y * scale * long
        return Vec2(x * width + sx * cos(a) - sy * sin(a), y * height + sx * sin(a) + sy * cos(a))
    }

    /// Canvas pixels → the point of the content there (L units around the centre).
    public func toLayer(_ p: Vec2, width: Double, height: Double) -> Vec2 {
        let long = Swift.max(width, height), a = angle * .pi / 180
        let dx = p.x - x * width, dy = p.y - y * height
        let k = 1 / Swift.max(scale * long, 1e-9)
        return Vec2((dx * cos(a) + dy * sin(a)) * k, (-dx * sin(a) + dy * cos(a)) * k)
    }

    /// The affine map that draws content given in pixels of a `contentWidth` × `contentHeight` picture
    /// (y up, as Core Image has it) onto a `width` × `height` canvas (y up), the picture's long side
    /// `side` L units before scaling: a, b, c, d, tx, ty with x' = a x + c y + tx, y' = b x + d y + ty.
    public func pictureMap(contentWidth: Double, contentHeight: Double, side: Double, width: Double, height: Double) -> [Double] {
        let long = Swift.max(width, height)
        let k = side * long * scale / Swift.max(contentWidth, contentHeight, 1e-9)
        let a = angle * .pi / 180
        // y up turns the other way: clockwise on screen is a negative angle.
        let c = cos(a), s = -sin(a)
        let cx = x * width, cy = (1 - y) * height
        let mx = contentWidth / 2, my = contentHeight / 2
        return [k * c, k * s, -k * s, k * c, cx - k * (c * mx - s * my), cy - k * (s * mx + c * my)]
    }
}

/// The Layers panel's kinds, named places and the actions' work.
public enum Layers {
    /// "layerPosition" option ids and where they put a layer's centre (shares of the canvas).
    public static let positions: [String: (x: Double, y: Double)] = [
        "center": (0.5, 0.5), "top": (0.5, 0.15), "bottom": (0.5, 0.85), "left": (0.2, 0.5), "right": (0.8, 0.5),
        "topLeft": (0.2, 0.15), "topRight": (0.8, 0.15), "bottomLeft": (0.2, 0.85), "bottomRight": (0.8, 0.85),
    ]

    /// A picked photo placed as a layer: its long side, in L units, at Layer Scale 100.
    public static let photoSide = 0.5

    /// The display name of a layer kind ("Photo", …).
    public static func title(of kind: String) -> String {
        switch kind {
        case "photo": return "Photo"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    /// The size of a layer's content before Layer Scale, in L units (width, height); nil for layers
    /// that cover the whole canvas. `aspect`: a photo layer's width ÷ height.
    public static func size(of layer: Layer, aspect: Double? = nil) -> (width: Double, height: Double)? {
        switch layer.kind {
        case "photo":
            let a = Swift.max(0.01, aspect ?? 1)
            return a >= 1 ? (photoSide, photoSide / a) : (photoSide * a, photoSide)
        default:
            return nil
        }
    }

    /// The layer's outline on a `width` × `height` canvas (pixels from the top-left): the corners of
    /// its content's box, placed, scaled and turned (top-left, top-right, bottom-right, bottom-left).
    public static func outline(_ layer: Layer, aspect: Double? = nil, width: Double, height: Double) -> [Vec2] {
        guard let size = size(of: layer, aspect: aspect) else {
            return [Vec2(0, 0), Vec2(width, 0), Vec2(width, height), Vec2(0, height)]
        }
        let w = size.width / 2, h = size.height / 2
        return [Vec2(-w, -h), Vec2(w, -h), Vec2(w, h), Vec2(-w, h)].map { layer.transform.toCanvas($0, width: width, height: height) }
    }

    /// A new layer of `kind` with the layer settings at their defaults (the settings every layer has,
    /// and those of its kind).
    public static func make(_ kind: String, registry: ControlRegistry) -> Layer {
        var layer = Layer(kind: kind)
        for control in registry.controls where control.scope == "layer" && (control.layer == nil || control.layer == kind) {
            layer.values[control.id] = control.defaultValue
        }
        return layer
    }
}

/// Something that happened to a layer, for the feedback line.
public enum LayerEvent: Equatable {
    /// A new layer of this kind (on top, selected).
    case created(String)
    case deleted
    case duplicated(from: Int)
    /// Moved up or down the stack: now this number.
    case moved(to: Int)
    case hidden
    /// "done": no layer selected.
    case deselected
    /// "reset all" deleted every layer.
    case allDeleted
}

// MARK: - Selecting a layer

extension EditState {
    /// The control that selects a layer: its value is the layer's number (1 = the lowest), 0 = none.
    public static let layerSelectorID = "layer"

    /// The selected layer's index in `layers`, or nil.
    public var selectedLayer: Int? {
        let number = Int(values[Self.layerSelectorID] ?? 0)
        return number >= 1 && number <= layers.count ? number - 1 : nil
    }

    /// Selects a layer by index (nil = none). Selecting one puts the masks and the retouch tool away:
    /// touches on the photo then move or draw the layer.
    public mutating func selectLayer(_ index: Int?) {
        values[Self.layerSelectorID] = Double(index.map { $0 + 1 } ?? 0)
        if index != nil {
            values[Self.maskSelectorID] = 0
            setRetouchTool(nil)
        }
    }

    /// The layer a scope-"layer" control acts on: the selected one when it is of the control's kind
    /// (or the control fits every layer), else the newest layer of that kind; nil when there is none.
    func layerTarget(for control: Control) -> Int? {
        if let l = selectedLayer, control.layer == nil || layers[l].kind == control.layer { return l }
        guard let kind = control.layer else { return nil }
        return layers.lastIndex { $0.kind == kind }
    }
}

// MARK: - Layer actions

extension CommandApplier {
    /// Runs a Layers-panel action (make, delete, duplicate, move a layer…); nil for other actions.
    func layerAction(_ control: Control, _ command: Command, state: inout EditState) -> [CommandOutcome]? {
        guard control.group == "layers" else { return nil }

        /// "delete layer 2" names a layer; otherwise the selected one.
        func named() -> Int? {
            if let v = command.value {
                let i = Int(v) - 1
                return state.layers.indices.contains(i) ? i : nil
            }
            return state.selectedLayer
        }
        let ran = CommandOutcome.ran(controlID: control.id)

        switch control.id {
        case "placePhoto":
            // The app adds the layer: it holds the photos picked.
            return [ran]
        case "deleteLayer":
            guard let l = named() else { return [.needsLayer(controlID: control.id)] }
            state.layers.remove(at: l)
            state.selectLayer(nil)
            return [ran, .layered(layer: l + 1, event: .deleted)]
        case "duplicateLayer":
            guard let l = named() else { return [.needsLayer(controlID: control.id)] }
            // The copy goes just above the original, nudged so both show.
            var copy = state.layers[l]
            copy.values["layerX"] = Swift.min(100, copy.value("layerX", 50) + 3)
            copy.values["layerY"] = Swift.min(100, copy.value("layerY", 50) + 3)
            state.layers.insert(copy, at: l + 1)
            state.selectLayer(l + 1)
            return [ran, .layered(layer: l + 2, event: .duplicated(from: l + 1))]
        case "moveLayerUp", "moveLayerDown":
            guard let l = named() else { return [.needsLayer(controlID: control.id)] }
            let to = control.id == "moveLayerUp" ? Swift.min(l + 1, state.layers.count - 1) : Swift.max(l - 1, 0)
            state.layers.swapAt(l, to)
            state.selectLayer(to)
            return [ran, .layered(layer: to + 1, event: .moved(to: to + 1))]
        case "hideLayer":
            guard let l = named() else { return [.needsLayer(controlID: control.id)] }
            state.layers[l].values["layerVisible"] = 0
            return [ran, .layered(layer: l + 1, event: .hidden)]
        case "layerPosition":
            guard let l = state.selectedLayer else { return [.needsLayer(controlID: control.id)] }
            let i = Int(command.value ?? 0)
            let id = control.options.indices.contains(i) ? control.options[i].id : "center"
            let spot = Layers.positions[id] ?? (0.5, 0.5)
            var out = [ran]
            for (key, v) in [("layerX", spot.x * 100), ("layerY", spot.y * 100)] {
                let from = state.layers[l].value(key, 50)
                state.layers[l].values[key] = v
                if from != v { out.append(.changedInLayer(layer: l + 1, controlID: key, from: from, to: v)) }
            }
            return out
        default:
            return nil
        }
    }
}
