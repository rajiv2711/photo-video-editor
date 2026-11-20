import Foundation

/// One user-facing editing control. Its label and synonyms are the words a user can say or type to
/// reach it; `step` is how far one "more" or "less" moves it.
///
/// `kind` says how it is shown and spoken to (all store one number in `EditState`):
/// - `slider`: a range, min…max ("contrast 20", "contrast more").
/// - `toggle`: 0 = off, 1 = on ("hdr on", "hdr off"; the bare name turns it on).
/// - `choice`: one of `options`; the value is the option's index ("white balance cloudy").
/// - `action`: a one-shot button with no value ("auto"); the app runs it.
/// - `curve_point`: one draggable point of a curve editor (`channel`, input level `x`); the value is
///   the output level 0…100 ("curve 50 60", "red curve 75 up").
///
/// `group` is the panel (light, color, effects, detail, optics…); `section` an optional sub-panel
/// inside it ("Tone curve", "Levels").
///
/// Masks (local adjustments) add three optional fields:
/// - `local`: a global slider that a selected mask can also hold ("exposure" inside Mask 1).
/// - `scope`: where a Masks-panel value lives: "mask" (a setting of the selected mask, e.g. its
///   feather) or "component" (of the mask's selected part, e.g. a radial gradient's size).
///   No scope: one value for the whole photo, as before.
/// - `component`: the kind of mask part a control makes (actions such as "linearGradient") or
///   belongs to (a "component" control such as "radialSize").
public struct Control: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable {
        case slider, toggle, choice, action
        case curvePoint = "curve_point"
    }

    /// One named option of a `choice` control.
    public struct Option: Codable, Equatable {
        public let id: String
        public let label: String
        public let synonyms: [String]

        public init(id: String, label: String, synonyms: [String] = []) {
            self.id = id
            self.label = label
            self.synonyms = synonyms
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decode(String.self, forKey: .label)
            synonyms = try c.decodeIfPresent([String].self, forKey: .synonyms) ?? []
        }

        var names: [String] {
            [label.lowercased()] + synonyms.map { $0.lowercased() }
        }
    }

    public let id: String
    public let label: String
    public let synonyms: [String]
    public let group: String
    public let section: String?
    public let kind: Kind
    public let min: Double
    public let max: Double
    public let defaultValue: Double
    public let step: Double
    public let options: [Option]
    /// curve_point only: "rgb", "red", "green" or "blue".
    public let channel: String?
    /// curve_point only: the input level (0…100) the point sits at.
    public let x: Double?
    /// A selected mask can hold its own value of this control (a local adjustment).
    public let local: Bool
    /// "mask" or "component" for Masks-panel values stored on a mask; nil for photo-wide values.
    public let scope: String?
    /// The mask part kind this control makes or belongs to ("brush", "linear", "radial", …).
    public let component: String?

    enum CodingKeys: String, CodingKey {
        case id, label, synonyms, group, section, kind, min, max, step, options, channel, x, local, scope, component
        case defaultValue = "default"
    }

    public init(id: String, label: String, synonyms: [String] = [], group: String = "other", section: String? = nil,
                kind: Kind = .slider, min: Double, max: Double, defaultValue: Double, step: Double,
                options: [Option] = [], channel: String? = nil, x: Double? = nil,
                local: Bool = false, scope: String? = nil, component: String? = nil) {
        self.id = id
        self.label = label
        self.synonyms = synonyms
        self.group = group
        self.section = section
        self.kind = kind
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.step = step
        self.options = options
        self.channel = channel
        self.x = x
        self.local = local
        self.scope = scope
        self.component = component
    }

    /// Older entries without group/kind still load (as sliders in "other"). Toggles, choices and
    /// actions may leave out min/max/default/step.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        synonyms = try c.decodeIfPresent([String].self, forKey: .synonyms) ?? []
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? "other"
        section = try c.decodeIfPresent(String.self, forKey: .section)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .slider
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        local = try c.decodeIfPresent(Bool.self, forKey: .local) ?? false
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        component = try c.decodeIfPresent(String.self, forKey: .component)
        let top: Double
        switch kind {
        case .toggle: top = 1
        case .choice: top = Double(Swift.max(0, options.count - 1))
        default: top = 0
        }
        min = try c.decodeIfPresent(Double.self, forKey: .min) ?? 0
        max = try c.decodeIfPresent(Double.self, forKey: .max) ?? top
        defaultValue = try c.decodeIfPresent(Double.self, forKey: .defaultValue) ?? 0
        step = try c.decodeIfPresent(Double.self, forKey: .step) ?? (kind == .action ? 0 : 1)
    }

    /// Keeps a value inside the control's range.
    public func clamp(_ value: Double) -> Double {
        Swift.min(max, Swift.max(min, value))
    }

    /// Every lower-cased name this control answers to.
    var names: [String] {
        [label.lowercased()] + synonyms.map { $0.lowercased() }
    }
}

/// The full list of controls, loaded from `controls.json`. Sliders and the command parser both
/// read this one list, so anything reachable by touch is reachable by name.
public struct ControlRegistry: Equatable {
    public let controls: [Control]

    public init(controls: [Control]) {
        self.controls = controls
    }

    public func control(id: String) -> Control? {
        controls.first { $0.id == id }
    }

    /// Panel names in the order they first appear in controls.json ("light", "color", …).
    public var groups: [String] {
        var out: [String] = []
        for c in controls where !out.contains(c.group) { out.append(c.group) }
        return out
    }

    public func controls(inGroup group: String) -> [Control] {
        controls.filter { $0.group == group }
    }

    /// Loads the bundled `controls.json`.
    public static func bundled() throws -> ControlRegistry {
        guard let url = Bundle.module.url(forResource: "controls", withExtension: "json") else {
            throw RegistryError.missingFile
        }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> ControlRegistry {
        struct File: Codable { let controls: [Control] }
        let file = try JSONDecoder().decode(File.self, from: data)
        return ControlRegistry(controls: file.controls)
    }

    public enum RegistryError: Error {
        case missingFile
    }
}
