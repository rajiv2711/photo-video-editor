import Foundation

// Presets (the Presets panel), as in Lightroom: a named bundle of settings saved from an edit and
// applied to any photo, with an Amount that makes it weaker or stronger. The same bundle carries
// copied settings (Copy / Paste) and the last photo's edit (Previous).
//
// Which settings a bundle takes is chosen by panel with the Include switches (Include Light, Include
// Color, …): every control of an included panel is saved, at its value or its default, so applying
// it puts that panel exactly as it was. The touch-made parts of the edit come along with their panel:
// the masks (Masks), the spots (Retouch), guides, perspective corners and warp pins (Geometry), the
// layers and the watermark's words (Layers).
//
// Built-in presets (Resources/presets.json, grouped in packs: Film, Portrait, …) set a few values and
// put the rest of the "look" (colour treatment, curves, effects) back to its defaults, so they don't
// pile up on each other and never touch exposure or white balance.

/// A named bundle of settings.
public struct Preset: Codable, Equatable {
    public var name: String
    /// The built-in pack it comes from ("Film", …); nil for the user's own.
    public var pack: String?
    /// Panels (control groups, or "look") whose controls go back to their default unless `values` has them.
    public var groups: [String]
    /// The values it sets, by control id.
    public var values: [String: Double]
    /// Whole parts of the edit it replaces (nil: left as they are).
    public var masks: [Mask]?
    public var retouches: [Retouch]?
    public var geometry: GeometryEdits?
    public var layers: [Layer]?
    public var watermarkText: String?

    public init(name: String, pack: String? = nil, groups: [String] = [], values: [String: Double] = [:], masks: [Mask]? = nil,
                retouches: [Retouch]? = nil, geometry: GeometryEdits? = nil, layers: [Layer]? = nil, watermarkText: String? = nil) {
        self.name = name
        self.pack = pack
        self.groups = groups
        self.values = values
        self.masks = masks
        self.retouches = retouches
        self.geometry = geometry
        self.layers = layers
        self.watermarkText = watermarkText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pack = try c.decodeIfPresent(String.self, forKey: .pack)
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        values = try c.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        masks = try c.decodeIfPresent([Mask].self, forKey: .masks)
        retouches = try c.decodeIfPresent([Retouch].self, forKey: .retouches)
        geometry = try c.decodeIfPresent(GeometryEdits.self, forKey: .geometry)
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers)
        watermarkText = try c.decodeIfPresent(String.self, forKey: .watermarkText)
    }

    /// The bundle of an edit's settings in `groups` (panel names, e.g. ["light", "color"]): every
    /// control of those panels that isn't at its default, and the touch-made parts of the included panels.
    public static func capture(_ state: EditState, name: String, groups: [String], registry: ControlRegistry) -> Preset {
        var preset = Preset(name: name, groups: groups)
        for control in registry.controls where Presets.isSaved(control) && groups.contains(control.group) && !state.isDefault(control) {
            preset.values[control.id] = state.value(of: control)
        }
        if groups.contains("masks") { preset.masks = state.masks }
        if groups.contains("retouch") { preset.retouches = state.retouches }
        if groups.contains("geometry") { preset.geometry = state.geometry }
        if groups.contains("layers") {
            preset.layers = state.layers
            preset.watermarkText = state.watermarkText
        }
        return preset
    }

    /// The same bundle with only the panels in `groups` (Previous and Paste keep what the Include
    /// switches say now).
    public func only(_ groups: [String], registry: ControlRegistry) -> Preset {
        var out = Preset(name: name, pack: pack, groups: self.groups.filter { groups.contains($0) })
        for (id, v) in values {
            if let c = registry.control(id: id), groups.contains(c.group) { out.values[id] = v }
        }
        if groups.contains("masks") { out.masks = masks }
        if groups.contains("retouch") { out.retouches = retouches }
        if groups.contains("geometry") { out.geometry = geometry }
        if groups.contains("layers") {
            out.layers = layers
            out.watermarkText = watermarkText
        }
        return out
    }

    /// The value each control gets at `amount` (1 = as saved, 0.5 = half way from the defaults, 2 =
    /// twice as far): sliders move from their default by `amount` × the saved change (hue angles are
    /// directions and stay); switches and choices take the saved one unless the amount is 0.
    public func targets(amount: Double, registry: ControlRegistry) -> [String: Double] {
        var out: [String: Double] = [:]
        for control in registry.controls where Presets.isSaved(control) {
            let inGroup = groups.contains(control.group) || (groups.contains("look") && Presets.isLook(control))
            guard let saved = values[control.id] ?? (inGroup ? control.defaultValue : nil) else { continue }
            let d = control.defaultValue
            switch control.kind {
            case .slider, .curvePoint:
                out[control.id] = Presets.isAngle(control) ? (amount > 0 ? saved : d) : control.clamp(d + (saved - d) * amount)
            default:
                out[control.id] = amount > 0 ? saved : d
            }
        }
        return out
    }

    /// Applies it at `amount` (see `targets`): returns how many controls changed (whole masks, spots,
    /// geometry and layers count one each).
    @discardableResult
    public func apply(to state: inout EditState, amount: Double = 1, registry: ControlRegistry) -> Int {
        var changed = 0
        for (id, v) in targets(amount: amount, registry: registry) {
            guard let control = registry.control(id: id) else { continue }
            let from = state.value(of: control)
            if state.set(control, to: v) != from { changed += 1 }
        }
        if let masks, masks != state.masks {
            state.masks = masks
            state.selectMask(nil)
            changed += 1
        }
        if let retouches, retouches != state.retouches {
            state.retouches = retouches
            state.selectRetouch(nil)
            changed += 1
        }
        if let geometry, geometry != state.geometry {
            state.geometry = geometry
            changed += 1
        }
        if let layers, layers != state.layers {
            state.layers = layers
            state.selectLayer(nil)
            changed += 1
        }
        if let watermarkText, watermarkText != state.watermarkText {
            state.watermarkText = watermarkText
            changed += 1
        }
        return changed
    }
}

/// Which controls presets keep, the built-in packs and finding a preset by name.
public enum Presets {
    /// The value of "Preset Amount" (0…200 %): how strongly the last preset applied shows.
    public static let amountID = "presetAmount"

    /// The Include switches: the panel each one adds to a saved preset, copied settings and Previous.
    public static let includes: [(group: String, id: String)] = [
        ("light", "includeLight"), ("color", "includeColor"), ("effects", "includeEffects"), ("detail", "includeDetail"),
        ("optics", "includeOptics"), ("geometry", "includeGeometry"), ("creative", "includeCreative"), ("masks", "includeMasks"),
        ("retouch", "includeRetouch"), ("layers", "includeLayers"),
    ]

    /// Every panel a bundle can hold.
    public static var allGroups: [String] { includes.map(\.group) }

    /// The panels whose Include switch is on.
    public static func included(_ state: EditState, registry: ControlRegistry) -> [String] {
        includes.filter { item in registry.control(id: item.id).map { state.value(of: $0) != 0 } ?? false }.map(\.group)
    }

    /// Selectors and tools in use are where the user is, not part of the look.
    static let selectors: Set<String> = [EditState.maskSelectorID, EditState.componentSelectorID, EditState.spotSelectorID,
                                         EditState.layerSelectorID, EditState.retouchToolID]

    /// Whether a control's value belongs in a saved bundle: a slider, switch or choice of an editing
    /// panel (not an action, a mask's or layer's own setting, a selector, the View panel or the
    /// Presets panel's own switches, or a merge's settings, which belong to the photos merged).
    public static func isSaved(_ control: Control) -> Bool {
        control.kind != .action && control.scope == nil && !selectors.contains(control.id)
            && !["view", "presets", "history", "merge"].contains(control.group)
    }

    /// The "look" of a photo, which built-in presets set as a whole: the colour treatment (not white
    /// balance, point colour, match colour or the negative/invert switches), the tone curves, Fade and
    /// the Effects panel.
    public static func isLook(_ control: Control) -> Bool {
        switch control.group {
        case "color":
            return !["whiteBalance", "temperature", "tint", "wbPicker", "matchColor", "matchAmount", "invert", "filmNegative"].contains(control.id)
                && control.section != "Point color"
        case "light":
            return control.section == "Tone curve" || control.section == "Point curve" || control.id == "fade"
        case "effects":
            return true
        default:
            return false
        }
    }

    /// Hue angles are directions: a weaker preset keeps them (colour grading's hues, Point color's target).
    static func isAngle(_ control: Control) -> Bool {
        (control.id.hasPrefix("grading") && control.id.hasSuffix("Hue")) || control.id == "pointHue"
    }

    /// The built-in presets (Resources/presets.json), pack by pack.
    public static func bundled() -> [Preset] {
        guard let url = Bundle.module.url(forResource: "presets", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decodePacks(data)
    }

    /// Reads a packs file: {"packs": [{"name": "Film", "presets": [{"name": …, "values": {…}}]}]};
    /// every built-in preset sets the whole "look".
    public static func decodePacks(_ data: Data) -> [Preset] {
        struct Pack: Decodable { let name: String; let presets: [Preset] }
        struct File: Decodable { let packs: [Pack] }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.packs.flatMap { pack in
            pack.presets.map { p in
                var preset = p
                preset.pack = pack.name
                if preset.groups.isEmpty { preset.groups = ["look"] }
                return preset
            }
        }
    }

    /// A name as compared: lower case, letters and digits, "&" read as "and", single spaces
    /// ("Black & White:  Noir!" → "black and white noir").
    public static func normalized(_ name: String) -> String {
        let cleaned = name.lowercased().replacingOccurrences(of: "&", with: " and ").map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    public enum Match: Equatable {
        case found(Int)
        /// Several fit as well (their indexes).
        case ambiguous([Int])
        case none
    }

    /// The preset `words` name among `presets` (the user's first, then the packs'): its exact name, or
    /// its pack and name ("film portra"), or a near-miss as the control names allow ("portr", "kodachrom").
    public static func find(_ words: String, in presets: [Preset]) -> Match {
        let phrase = normalized(words)
        guard !phrase.isEmpty else { return .none }
        if let i = presets.firstIndex(where: { normalized($0.name) == phrase }) { return .found(i) }
        if let i = presets.firstIndex(where: { p in p.pack.map { normalized($0 + " " + p.name) == phrase } ?? false }) { return .found(i) }
        var best: [Int] = []
        var bestScore = Int.max
        for (i, preset) in presets.enumerated() {
            guard let score = NameMatcher.score(phrase, against: normalized(preset.name)) else { continue }
            if score < bestScore {
                best = [i]
                bestScore = score
            } else if score == bestScore {
                best.append(i)
            }
        }
        switch best.count {
        case 0: return .none
        case 1: return .found(best[0])
        default: return .ambiguous(best)
        }
    }
}

/// Match Exposures: evens out the brightness of the photos picked, as Lightroom's Match Total Exposures
/// does, from the pictures themselves (no camera data needed): each photo's exposure moves by the
/// stops between its key and the key of the photo being edited, both read before any edit.
public enum MatchExposure {
    /// A picture's key: the log-average of its pixels' luminance (linear light, Rec. 709), as exposure
    /// meters and tone mappers read overall brightness; one bright lamp barely moves it.
    /// `rgba`: linear RGBA floats; see-through pixels don't count.
    public static func key(rgba: [Float]) -> Double {
        var sum = 0.0
        var count = 0
        var i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] > 0.5 {
                let luma = 0.2126 * Double(rgba[i]) + 0.7152 * Double(rgba[i + 1]) + 0.0722 * Double(rgba[i + 2])
                sum += log(1e-4 + Swift.max(0, luma))
                count += 1
            }
            i += 4
        }
        return count == 0 ? 0 : exp(sum / Double(count))
    }

    /// The stops a photo of key `photo` needs to look as bright as one of key `reference` (within ±4).
    public static func stops(reference: Double, photo: Double) -> Double {
        guard reference > 0, photo > 0 else { return 0 }
        return Swift.min(4, Swift.max(-4, log2(reference / photo)))
    }
}
