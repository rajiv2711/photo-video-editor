import Foundation

// Retouching (the Retouch panel), as in Lightroom's Remove tool and Photoshop's retouch brushes: each
// spot or stroke is one step, kept in the edit (`EditState.retouches`) with its tool, its geometry on
// the photo (points from the top-left, 0…1) and its settings, and drawn again from them on every
// render, so nothing is baked in: a step can be selected ("spot 2"), changed (its opacity), deleted
// ("delete spot 2", "undo last spot") at any time.
//
// A tool is picked by name or button ("remove brush", "heal"); the photo is then painted or tapped
// with it. The steps are worked out by RetouchCanvas on the photo after lens corrections (as the
// masks and pickers see it), before white balance and every other slider.

/// One retouch step: a spot or stroke of a tool.
public struct Retouch: Hashable, Codable {
    /// The tool (an option id of the "retouchTool" choice): "remove", …
    public var tool: String
    /// The stroke, from the top-left (0…1); one point for a tap.
    public var points: [MaskPoint]
    /// Pen pressure at each point (0…1); empty = full pressure everywhere.
    public var pressure: [Double]
    /// Brush diameter, % of the photo's long side.
    public var size: Double
    /// Soft edge, % of the radius.
    public var feather: Double
    /// Where a copying tool (heal, …) takes its pixels from: source = destination + offset, as shares of
    /// the photo's width and height. Nil until picked: the canvas then picks one nearby (and the app
    /// keeps it in the edit).
    public var offset: MaskPoint?
    /// Settings by control id (opacity, …), copied from the panel when the step was made.
    public var values: [String: Double]

    public init(tool: String, points: [MaskPoint], pressure: [Double] = [], size: Double = 10, feather: Double = 50,
                offset: MaskPoint? = nil, values: [String: Double] = [:]) {
        self.tool = tool
        self.points = points
        self.pressure = pressure
        self.size = size
        self.feather = feather
        self.offset = offset
        self.values = values
    }

    /// The middle of the stroke's points (a tap: the tap), from the top-left, 0…1.
    public var centre: MaskPoint {
        guard let first = points.first else { return MaskPoint(0.5, 0.5) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return points.count == 1 ? first : MaskPoint((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
    }

    /// Opacity 0…1 (the "spotOpacity" value, 100 % when missing).
    public var opacity: Double {
        Swift.min(1, Swift.max(0, (values["spotOpacity"] ?? 100) / 100))
    }
}

/// The retouch tools: their ids (the "retouchTool" choice's options, in order, index 0 = none) and
/// which per-step settings each keeps.
public enum RetouchTools {
    /// Option ids of the "retouchTool" choice; must match controls.json (unit-tested).
    public static let ids = ["none", "remove", "heal"]

    /// Tools that copy from a source spot (its `offset`; "clone source" picks it by a tap).
    public static let copying: Set<String> = ["heal"]

    /// The controls a new step of `tool` copies from the panel (and keeps as its own settings).
    public static func settings(for tool: String) -> [String] {
        ["spotOpacity"]
    }
}

/// Something that happened to the retouch steps, for the feedback line.
public enum RetouchEvent: Equatable {
    /// A step was deleted ("delete spot 2", "undo last spot").
    case deleted
    /// "reset all" deleted every step.
    case allDeleted
}

extension EditState {
    /// The control that selects a retouch step: its value is the step's number (1 = first), 0 = none.
    public static let spotSelectorID = "spot"
    /// The choice that holds the retouch tool in use (0 = none).
    public static let retouchToolID = "retouchTool"

    /// The selected step's index in `retouches`, or nil.
    public var selectedRetouch: Int? {
        let number = Int(values[Self.spotSelectorID] ?? 0)
        return number >= 1 && number <= retouches.count ? number - 1 : nil
    }

    /// Selects a step by index (nil = none).
    public mutating func selectRetouch(_ index: Int?) {
        values[Self.spotSelectorID] = Double(index.map { $0 + 1 } ?? 0)
    }

    /// The retouch tool in use ("remove", …), or nil when touches on the photo don't retouch.
    public var retouchTool: String? {
        let index = Int(values[Self.retouchToolID] ?? 0)
        return index > 0 && index < RetouchTools.ids.count ? RetouchTools.ids[index] : nil
    }

    /// Picks a tool by id (nil or "none" puts it away).
    public mutating func setRetouchTool(_ tool: String?) {
        values[Self.retouchToolID] = Double(RetouchTools.ids.firstIndex(of: tool ?? "none") ?? 0)
    }

    /// Adds a step (made by touch) and selects it.
    public mutating func addRetouch(_ step: Retouch) {
        retouches.append(step)
        selectRetouch(retouches.count - 1)
    }
}
