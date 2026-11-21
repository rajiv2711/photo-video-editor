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
// (scope "layer") change it, by touch or by name; "done" (or "layer 0") deselects it. An adjustment
// layer also takes the sliders a mask can hold (`Control.local`: exposure, contrast, …): they change
// everything below it. Any layer can have a mask (`Layer.mask`), made of the same parts as the Masks
// panel's (a gradient from a side, a radial, brush strokes) on the canvas instead of the photo.

/// One layer: its kind, its settings by control id and what touch or words made (text, paths, strokes).
public struct Layer: Hashable, Codable {
    /// "photo" (a picked photo), …
    public var kind: String
    /// Settings by control id (layerOpacity, layerX, …) plus a few set by the action that made it
    /// ("picked": which photo picked it shows, until the app gives it its picture, "photo").
    public var values: [String: Double]
    /// Adjustment layers: their own values of the sliders a mask can hold (exposure, …); missing = no change.
    public var adjustments: [String: Double]
    /// Where the layer shows (white) and where not (black), in canvas coordinates; nil = everywhere.
    public var mask: Mask?
    /// Text layers: the words, as typed or said.
    public var text: String
    /// Pen paths: the points tapped (or dragged out for curves), L units around the centre.
    public var path: [PathNode]
    /// Pen paths: joined back to the first point (filled) or open (a line).
    public var closed: Bool
    /// Paint layers: the brush strokes, oldest first.
    public var strokes: [PaintStroke]

    public init(kind: String, values: [String: Double] = [:], adjustments: [String: Double] = [:], mask: Mask? = nil,
                text: String = "", path: [PathNode] = [], closed: Bool = false, strokes: [PaintStroke] = []) {
        self.kind = kind
        self.values = values
        self.adjustments = adjustments
        self.mask = mask
        self.text = text
        self.path = path
        self.closed = closed
        self.strokes = strokes
    }

    /// Shapes: rectangle, ellipse, line, polygon or path (Layers.shapeTypes).
    public var shapeType: String {
        let i = Int(values["shapeType"] ?? 0)
        return Layers.shapeTypes.indices.contains(i) ? Layers.shapeTypes[i] : "rectangle"
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

/// One point of a pen path and its curve handle: the path leaves it towards `point + handle` and
/// arrives from `point − handle` (no handle: a corner). L units around the layer's centre.
public struct PathNode: Hashable, Codable {
    public var point: MaskPoint
    public var handle: MaskPoint

    public init(_ point: MaskPoint, handle: MaskPoint = MaskPoint(0, 0)) {
        self.point = point
        self.handle = handle
    }
}

/// One paint brush stroke: its points (L units around the layer's centre), the Pencil's pressure
/// (0…1) and tilt (0 upright … 1 lying flat) at each, the brush size (% of the long side) and its
/// colour (a Brush Colour value).
public struct PaintStroke: Hashable, Codable {
    public var points: [MaskPoint]
    public var pressure: [Double]
    public var tilt: [Double]
    public var size: Double
    public var color: Double

    public init(points: [MaskPoint], pressure: [Double] = [], tilt: [Double] = [], size: Double = 1, color: Double = 2) {
        self.points = points
        self.pressure = pressure
        self.tilt = tilt
        self.size = size
        self.color = color
    }

    /// The line's width at point `i`, in L units: the brush size, thinner with a light touch (a
    /// third at the lightest), wider as the Pencil leans over (up to three times, like shading with
    /// a pencil's side). Fingers press fully and stand upright.
    public func width(at i: Int) -> Double {
        let p = pressure.indices.contains(i) ? Swift.min(1, Swift.max(0, pressure[i])) : 1
        let t = tilt.indices.contains(i) ? Swift.min(1, Swift.max(0, tilt[i])) : 0
        return size / 100 * (0.3 + 0.7 * p) * (1 + 2 * t)
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

    /// The colours of the colour choices (Text Colour, …), in option order: id and sRGB levels.
    public static let colors: [(id: String, rgb: RGB)] = [
        ("white", RGB(1, 1, 1)), ("black", RGB(0.04, 0.04, 0.04)), ("red", RGB(0.89, 0.12, 0.14)), ("orange", RGB(1, 0.55, 0.1)),
        ("yellow", RGB(1, 0.86, 0.12)), ("green", RGB(0.16, 0.68, 0.27)), ("blue", RGB(0.13, 0.42, 0.95)),
        ("purple", RGB(0.56, 0.27, 0.86)), ("pink", RGB(1, 0.45, 0.71)), ("grey", RGB(0.5, 0.5, 0.5)), ("brown", RGB(0.5, 0.31, 0.16)),
    ]

    /// A colour choice's value as a colour; `none`: the choice starts with a "none" option (nil for it).
    public static func color(_ value: Double, none: Bool = false) -> RGB? {
        let i = Int(value) - (none ? 1 : 0)
        return colors.indices.contains(i) ? colors[i].rgb : nil
    }

    /// "textFont" option ids, in order; must match controls.json.
    public static let fonts = ["sans", "serif", "rounded", "mono", "script", "display", "typewriter", "marker"]

    /// The kinds of shape, in the order of the "shapeType" setting the add actions give a shape layer.
    public static let shapeTypes = ["rectangle", "ellipse", "line", "polygon", "path"]

    /// The shape each add action makes and the size it starts at (width, height, % of the long side).
    public static let shapeActions: [String: (type: String, width: Double, height: Double)] = [
        "addRectangle": ("rectangle", 30, 20), "addEllipse": ("ellipse", 25, 25), "addLine": ("line", 40, 20),
        "addPolygon": ("polygon", 25, 25), "penTool": ("path", 30, 20),
    ]

    /// A shape's box (width, height) in L units.
    public static func shapeSize(_ layer: Layer) -> (width: Double, height: Double) {
        (layer.value("shapeWidth", 30) / 100, layer.value("shapeHeight", 20) / 100)
    }

    /// A regular polygon of `sides` corners in a `width` × `height` box around the centre, the first
    /// corner at the top, going clockwise (y down).
    public static func polygon(sides: Int, width: Double, height: Double) -> [Vec2] {
        let n = Swift.max(3, sides)
        return (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi
            return Vec2(sin(a) * width / 2, -cos(a) * height / 2)
        }
    }

    /// A pen path as cubic Bézier pieces (start, control 1, control 2, end), joined back to the start when closed.
    public static func bezier(_ nodes: [PathNode], closed: Bool) -> [(Vec2, Vec2, Vec2, Vec2)] {
        guard nodes.count >= 2 else { return [] }
        func v(_ p: MaskPoint) -> Vec2 { Vec2(p.x, p.y) }
        let pairs = Array(zip(nodes, nodes.dropFirst())) + (closed ? [(nodes[nodes.count - 1], nodes[0])] : [])
        return pairs.map { a, b in (v(a.point), v(a.point) + v(a.handle), v(b.point) - v(b.handle), v(b.point)) }
    }

    /// A point on a Bézier piece at `t` (0…1).
    public static func point(on piece: (Vec2, Vec2, Vec2, Vec2), at t: Double) -> Vec2 {
        let u = 1 - t
        return piece.0 * (u * u * u) + piece.1 * (3 * u * u * t) + piece.2 * (3 * u * t * t) + piece.3 * (t * t * t)
    }

    /// A fill layer's look (its "fillStyle" setting): a solid colour, or a linear or radial gradient.
    public static let fillStyles = ["solid", "linear", "radial"]

    /// A linear gradient fill on a `width` × `height` canvas: where the start colour is full and where
    /// the end colour is (pixels from the top-left). It runs along `angle` (Fill Angle: 0 = left to
    /// right, 90 = top to bottom) through the layer's centre, across the whole canvas at Layer Scale 100.
    public static func linearFill(_ layer: Layer, width: Double, height: Double) -> (start: Vec2, end: Vec2) {
        let t = layer.transform, a = layer.value("fillAngle", -90) * .pi / 180
        let u = Vec2(cos(a), sin(a))
        let half = (abs(width * u.x) + abs(height * u.y)) / 2 * t.scale
        let c = Vec2(t.x * width, t.y * height)
        return (c - u * half, c + u * half)
    }

    /// A radial gradient fill: its centre (the layer's) and the radius where the end colour is (half the
    /// canvas's diagonal at Layer Scale 100), in pixels.
    public static func radialFill(_ layer: Layer, width: Double, height: Double) -> (centre: Vec2, radius: Double) {
        let t = layer.transform
        return (Vec2(t.x * width, t.y * height), (width * width + height * height).squareRoot() / 2 * t.scale)
    }

    /// Text Size is per mille of the canvas's long side: the font size in L units.
    public static func fontSize(_ layer: Layer) -> Double {
        layer.value("textSize", 60) / 1000
    }

    /// The display name of a layer kind ("Photo", …).
    public static func title(of kind: String) -> String {
        switch kind {
        case "photo": return "Photo"
        case "adjustment": return "Adjustment"
        case "text": return "Text"
        case "shape": return "Shape"
        case "paint": return "Paint"
        case "fill": return "Fill"
        case "sticker": return "Sticker"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    /// The size of a layer's content before Layer Scale, in L units (width, height); nil for layers
    /// that cover the whole canvas. `aspect`: a photo layer's width ÷ height.
    public static func size(of layer: Layer, aspect: Double? = nil) -> (width: Double, height: Double)? {
        box(of: layer, aspect: aspect).map { ($0.maxX - $0.x, $0.maxY - $0.y) }
    }

    /// The box around a layer's content before Layer Scale and Rotation, in L units around its centre;
    /// nil for layers that cover the whole canvas.
    public static func box(of layer: Layer, aspect: Double? = nil) -> GeoRect? {
        func centred(_ w: Double, _ h: Double) -> GeoRect { GeoRect(x: -w / 2, y: -h / 2, width: w, height: h) }
        switch layer.kind {
        case "shape":
            let size = shapeSize(layer)
            switch layer.shapeType {
            case "line":
                return centred(size.width, layer.value("lineWidth", 1) / 100)
            case "path":
                let points = bezier(layer.path, closed: layer.closed).flatMap { piece in
                    stride(from: 0.0, through: 1.0, by: 0.125).map { point(on: piece, at: $0) }
                } + layer.path.map { Vec2($0.point.x, $0.point.y) }
                guard let first = points.first else { return centred(0.02, 0.02) }
                let xs = points.map(\.x), ys = points.map(\.y)
                return GeoRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                               height: (ys.max() ?? 0) - (ys.min() ?? 0))
            default:
                return centred(size.width, size.height)
            }
        case "paint":
            var box: GeoRect?
            for stroke in layer.strokes {
                for (i, p) in stroke.points.enumerated() {
                    let r = stroke.width(at: i) / 2
                    let dot = GeoRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                    guard let b = box else { box = dot; continue }
                    let x0 = Swift.min(b.x, dot.x), y0 = Swift.min(b.y, dot.y)
                    box = GeoRect(x: x0, y: y0, width: Swift.max(b.maxX, dot.maxX) - x0, height: Swift.max(b.maxY, dot.maxY) - y0)
                }
            }
            return box ?? centred(0.02, 0.02)
        default:
            return sizeAround(layer, aspect: aspect).map { centred($0.width, $0.height) }
        }
    }

    /// The content size of layers drawn around their centre.
    private static func sizeAround(_ layer: Layer, aspect: Double?) -> (width: Double, height: Double)? {
        switch layer.kind {
        case "photo":
            let a = Swift.max(0.01, aspect ?? 1)
            return a >= 1 ? (photoSide, photoSide / a) : (photoSide * a, photoSide)
        case "sticker":
            return (Stickers.side, Stickers.side)
        case "text":
            // About: letters are near 0.6 of the font size wide, lines 1.2 tall.
            let lines = layer.text.split(separator: "\n", omittingEmptySubsequences: false)
            let longest = Double(lines.map(\.count).max() ?? 1)
            let size = fontSize(layer)
            return (Swift.max(1, longest) * 0.6 * size, Double(Swift.max(1, lines.count)) * 1.2 * size)
        default:
            return nil
        }
    }

    /// The layer's outline on a `width` × `height` canvas (pixels from the top-left): the corners of
    /// its content's box, placed, scaled and turned (top-left, top-right, bottom-right, bottom-left).
    public static func outline(_ layer: Layer, aspect: Double? = nil, width: Double, height: Double) -> [Vec2] {
        guard let b = box(of: layer, aspect: aspect) else {
            return [Vec2(0, 0), Vec2(width, 0), Vec2(width, height), Vec2(0, height)]
        }
        return [Vec2(b.x, b.y), Vec2(b.maxX, b.y), Vec2(b.maxX, b.maxY), Vec2(b.x, b.maxY)]
            .map { layer.transform.toCanvas($0, width: width, height: height) }
    }

    /// "layerMask" option ids and the mask part each makes: a linear gradient full at that side, a
    /// radial in the middle, brush strokes to paint (then draw on the picture); "none" removes the mask.
    public static let maskOptions = ["brush", "top", "bottom", "left", "right", "center", "none"]

    /// Gives a layer the mask a Layer Mask option asks for: a gradient or radial replaces the mask; a
    /// brush is added to it (strokes then paint it) unless its newest part is a brush already.
    public static func setMask(_ option: String, on layer: inout Layer, registry: ControlRegistry) {
        switch option {
        case "none":
            layer.mask = nil
        case "brush":
            var mask = layer.mask ?? Mask()
            if mask.components.last?.kind != "brush" { mask.components.append(MaskComponent(kind: "brush")) }
            mask.selectedComponent = mask.components.count - 1
            layer.mask = mask
        default:
            let kind = option == "center" ? "radial" : "linear"
            layer.mask = Mask(components: [MaskPresets.component(kind: kind, mode: .add, option: option, registry: registry)])
        }
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
    /// A text layer's words changed.
    case textChanged
    /// Its mask changed: made from a part (an option id of Layer Mask), inverted, or removed ("none").
    case masked(String)
    /// "invert layer mask" on a layer with no mask.
    case noMask
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
        if control.scope != "layer", control.kind != .action {
            // A slider a mask can hold: the selected adjustment layer's own.
            guard control.local, let l = selectedLayer, layers[l].kind == "adjustment" else { return nil }
            return l
        }
        if let l = selectedLayer, control.layer == nil || layers[l].kind == control.layer { return l }
        guard let kind = control.layer else { return nil }
        return layers.lastIndex { $0.kind == kind }
    }
}

// MARK: - Touch edits (the app calls these; commands go through CommandApplier)

extension EditState {
    /// Adds a brush stroke (canvas coordinates) to the selected layer's mask, to its newest brush
    /// part. Returns false when it has none.
    @discardableResult
    public mutating func addLayerMaskStroke(_ stroke: MaskStroke) -> Bool {
        guard let l = selectedLayer, let p = layers[l].mask?.components.lastIndex(where: { $0.kind == "brush" }),
              !stroke.points.isEmpty else { return false }
        layers[l].mask?.components[p].strokes.append(stroke)
        return true
    }
}

extension EditState {
    /// A paint stroke on the selected paint layer: `points` in canvas pixels of a `width` × `height`
    /// canvas, with the Pencil's pressure and tilt at each; the brush's size and colour. Returns false
    /// when no paint layer is selected.
    @discardableResult
    public mutating func addPaintStroke(_ points: [Vec2], pressure: [Double] = [], tilt: [Double] = [], size: Double, color: Double,
                                        width: Double, height: Double) -> Bool {
        guard let l = selectedLayer, layers[l].kind == "paint", !points.isEmpty else { return false }
        let t = layers[l].transform
        let local = points.map { t.toLayer($0, width: width, height: height) }.map { MaskPoint($0.x, $0.y) }
        // Sizes on the layer: a scaled layer gets a brush that looks as wide as the one on screen.
        layers[l].strokes.append(PaintStroke(points: local, pressure: pressure, tilt: tilt, size: size / t.scale, color: color))
        return true
    }

    /// The pen on the selected open path: a point at `point` (canvas pixels of a `width` × `height`
    /// canvas) with a curve handle dragged out to `handleEnd` (nil: a corner). A point on the first one
    /// (with three or more) closes the path. Returns false when no open path is selected.
    @discardableResult
    public mutating func penPoint(_ point: Vec2, handleEnd: Vec2? = nil, width: Double, height: Double) -> Bool {
        guard let l = selectedLayer, layers[l].kind == "shape", layers[l].shapeType == "path", !layers[l].closed else { return false }
        let t = layers[l].transform
        let p = t.toLayer(point, width: width, height: height)
        if layers[l].path.count >= 3, let first = layers[l].path.first {
            let close = 0.02 / t.scale  // 2 % of the long side, on screen
            if hypot(p.x - first.point.x, p.y - first.point.y) < close {
                layers[l].closed = true
                return true
            }
        }
        var handle = MaskPoint(0, 0)
        if let end = handleEnd {
            let q = t.toLayer(end, width: width, height: height)
            handle = MaskPoint(q.x - p.x, q.y - p.y)
        }
        layers[l].path.append(PathNode(MaskPoint(p.x, p.y), handle: handle))
        return true
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
            // Which photo picked ("place photo 2": the second; 0 = the last): the app, which holds the
            // photos, gives the layer its picture.
            var layer = Layers.make("photo", registry: registry)
            layer.values["picked"] = command.value ?? 0
            state.layers.append(layer)
            state.selectLayer(state.layers.count - 1)
            return [ran, .layered(layer: state.layers.count, event: .created("photo"))]
        case "newTextLayer":
            var layer = Layers.make("text", registry: registry)
            layer.text = command.text ?? "Text"
            state.layers.append(layer)
            state.selectLayer(state.layers.count - 1)
            return [ran, .layered(layer: state.layers.count, event: .created("text"))]
        case "editText":
            guard let l = state.layerTarget(for: control) else { return [.needsLayer(controlID: control.id)] }
            state.layers[l].text = command.text ?? ""
            return [ran, .layered(layer: l + 1, event: .textChanged)]
        case "addRectangle", "addEllipse", "addLine", "addPolygon", "penTool":
            // The pen goes on drawing the selected path while it is open.
            if control.id == "penTool", let l = state.selectedLayer, state.layers[l].kind == "shape",
               state.layers[l].shapeType == "path", !state.layers[l].closed {
                return [ran]
            }
            let made = Layers.shapeActions[control.id] ?? ("rectangle", 30, 20)
            var layer = Layers.make("shape", registry: registry)
            layer.values["shapeType"] = Double(Layers.shapeTypes.firstIndex(of: made.type) ?? 0)
            layer.values["shapeWidth"] = made.width
            layer.values["shapeHeight"] = made.height
            state.layers.append(layer)
            state.selectLayer(state.layers.count - 1)
            return [ran, .layered(layer: state.layers.count, event: .created("shape"))]
        case "paintBrush":
            // Painting goes on on the selected paint layer; otherwise a new one.
            if let l = state.selectedLayer, state.layers[l].kind == "paint" { return [ran] }
            state.layers.append(Layers.make("paint", registry: registry))
            state.selectLayer(state.layers.count - 1)
            return [ran, .layered(layer: state.layers.count, event: .created("paint"))]
        case "addSticker":
            var layer = Layers.make("sticker", registry: registry)
            let i = Int(command.value ?? 0)
            layer.values["sticker"] = Double(Stickers.ids.indices.contains(i) ? i : 0)
            state.layers.append(layer)
            state.selectLayer(state.layers.count - 1)
            return [ran, .layered(layer: state.layers.count, event: .created("sticker"))]
        case "solidFill", "gradientFill":
            var layer = Layers.make("fill", registry: registry)
            var style = "solid"
            if control.id == "gradientFill" {
                let i = Int(command.value ?? 0)
                style = control.options.indices.contains(i) ? control.options[i].id : "linear"
            }
            layer.values["fillStyle"] = Double(Layers.fillStyles.firstIndex(of: style) ?? 0)
            state.layers.append(layer)
            state.selectLayer(state.layers.count - 1)
            return [ran, .layered(layer: state.layers.count, event: .created("fill"))]
        case "newAdjustmentLayer":
            state.layers.append(Layers.make("adjustment", registry: registry))
            state.selectLayer(state.layers.count - 1)
            return [ran, .layered(layer: state.layers.count, event: .created("adjustment"))]
        case "layerMask":
            guard let l = state.selectedLayer else { return [.needsLayer(controlID: control.id)] }
            let i = Int(command.value ?? 0)
            let option = control.options.indices.contains(i) ? control.options[i].id : "brush"
            Layers.setMask(option, on: &state.layers[l], registry: registry)
            return [ran, .layered(layer: l + 1, event: .masked(option))]
        case "invertLayerMask":
            guard let l = named() else { return [.needsLayer(controlID: control.id)] }
            guard state.layers[l].mask != nil else { return [ran, .layered(layer: l + 1, event: .noMask)] }
            let inverted = (state.layers[l].mask?.settings["maskInvert"] ?? 0) != 0
            state.layers[l].mask?.settings["maskInvert"] = inverted ? 0 : 1
            return [ran, .layered(layer: l + 1, event: .masked("invert"))]
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

// MARK: - Blend modes

/// How a layer mixes with what is below it (Layer Blend), with the usual formulas (the W3C compositing
/// spec, as Photoshop has them) on sRGB levels 0…1: `base` is below, `top` the layer. The iPad uses
/// Core Image's filters of the same names; these are the reference the tests check them against.
public enum LayerBlend {
    /// "layerBlend" option ids, in order; must match controls.json.
    public static let modes = ["normal", "multiply", "screen", "overlay", "softLight", "hardLight", "darken", "lighten",
                               "colorDodge", "colorBurn", "difference", "exclusion", "hue", "saturation", "color", "luminosity"]

    /// The mode id of a Layer Blend value ("normal" when out of range).
    public static func mode(_ value: Double) -> String {
        let i = Int(value)
        return modes.indices.contains(i) ? modes[i] : "normal"
    }

    /// One colour of a layer blended onto one below it.
    public static func blend(_ base: RGB, _ top: RGB, mode: String) -> RGB {
        switch mode {
        case "hue": return setLum(setSat(top, sat(base)), lum(base))
        case "saturation": return setLum(setSat(base, sat(top)), lum(base))
        case "color": return setLum(top, lum(base))
        case "luminosity": return setLum(base, lum(top))
        default:
            return RGB(channel(base.r, top.r, mode), channel(base.g, top.g, mode), channel(base.b, top.b, mode))
        }
    }

    /// The separable modes, one channel at a time (`b` below, `s` the layer).
    static func channel(_ b: Double, _ s: Double, _ mode: String) -> Double {
        switch mode {
        case "multiply": return b * s
        case "screen": return b + s - b * s
        case "overlay": return channel(s, b, "hardLight")
        case "hardLight": return s <= 0.5 ? b * 2 * s : channel(b, 2 * s - 1, "screen")
        case "softLight":
            if s <= 0.5 { return b - (1 - 2 * s) * b * (1 - b) }
            let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()
            return b + (2 * s - 1) * (d - b)
        case "darken": return Swift.min(b, s)
        case "lighten": return Swift.max(b, s)
        case "colorDodge":
            if b == 0 { return 0 }
            return s >= 1 ? 1 : Swift.min(1, b / (1 - s))
        case "colorBurn":
            if b >= 1 { return 1 }
            return s <= 0 ? 0 : 1 - Swift.min(1, (1 - b) / s)
        case "difference": return abs(b - s)
        case "exclusion": return b + s - 2 * b * s
        default: return s  // normal
        }
    }

    static func lum(_ c: RGB) -> Double {
        0.3 * c.r + 0.59 * c.g + 0.11 * c.b
    }

    static func sat(_ c: RGB) -> Double {
        Swift.max(c.r, c.g, c.b) - Swift.min(c.r, c.g, c.b)
    }

    /// `c` with its luminosity moved to `l`, brought back into range keeping its hue.
    static func setLum(_ c: RGB, _ l: Double) -> RGB {
        let d = l - lum(c)
        var out = RGB(c.r + d, c.g + d, c.b + d)
        let l2 = lum(out), n = Swift.min(out.r, out.g, out.b), x = Swift.max(out.r, out.g, out.b)
        if n < 0 {
            out = RGB(l2 + (out.r - l2) * l2 / (l2 - n), l2 + (out.g - l2) * l2 / (l2 - n), l2 + (out.b - l2) * l2 / (l2 - n))
        }
        if x > 1 {
            out = RGB(l2 + (out.r - l2) * (1 - l2) / (x - l2), l2 + (out.g - l2) * (1 - l2) / (x - l2), l2 + (out.b - l2) * (1 - l2) / (x - l2))
        }
        return out
    }

    /// `c` with its saturation (largest − smallest channel) set to `s`, the middle channel in proportion.
    static func setSat(_ c: RGB, _ s: Double) -> RGB {
        let values = [c.r, c.g, c.b]
        let order = values.indices.sorted { values[$0] < values[$1] }
        let lo = values[order[0]], mid = values[order[1]], hi = values[order[2]]
        var out = [0.0, 0.0, 0.0]
        if hi > lo {
            out[order[1]] = (mid - lo) * s / (hi - lo)
            out[order[2]] = s
        }
        return RGB(out[0], out[1], out[2])
    }
}
