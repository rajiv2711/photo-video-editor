import Foundation

/// The current value of every control. Missing entries are at their default.
public struct EditState: Equatable {
    public private(set) var values: [String: Double] = [:]

    public init() {}

    public func value(of control: Control) -> Double {
        values[control.id] ?? control.defaultValue
    }

    /// Sets a control, clamped to its range and rounded to remove floating-point drift
    /// (0.1 + 0.1 + 0.1 stays 0.3). Returns the stored value.
    @discardableResult
    public mutating func set(_ control: Control, to value: Double) -> Double {
        let stored = Self.tidy(control.clamp(value))
        values[control.id] = stored
        return stored
    }

    public func isDefault(_ control: Control) -> Bool {
        value(of: control) == control.defaultValue
    }

    static func tidy(_ value: Double) -> Double {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        return rounded == 0 ? 0 : rounded  // no "-0"
    }
}
