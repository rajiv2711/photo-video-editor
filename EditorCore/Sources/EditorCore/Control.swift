import Foundation

/// One user-facing editing control (a slider). Its label and synonyms are the words a user can
/// say or type to reach it; `step` is how far one "more" or "less" moves it.
public struct Control: Codable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let synonyms: [String]
    public let min: Double
    public let max: Double
    public let defaultValue: Double
    public let step: Double

    enum CodingKeys: String, CodingKey {
        case id, label, synonyms, min, max, step
        case defaultValue = "default"
    }

    public init(id: String, label: String, synonyms: [String] = [], min: Double, max: Double, defaultValue: Double, step: Double) {
        self.id = id
        self.label = label
        self.synonyms = synonyms
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.step = step
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
