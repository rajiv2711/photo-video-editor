import Foundation

/// A colour as red, green and blue numbers (0…1 = black…white), shared by the Color panel's math.
public struct RGB: Equatable, CustomStringConvertible {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let white = RGB(1, 1, 1)

    /// Rec. 709 luma (the brightness the eye sees).
    public var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    public var max: Double { Swift.max(r, g, b) }
    public var min: Double { Swift.min(r, g, b) }

    public static func * (a: RGB, b: RGB) -> RGB { RGB(a.r * b.r, a.g * b.g, a.b * b.b) }
    public static func / (a: RGB, b: RGB) -> RGB { RGB(a.r / b.r, a.g / b.g, a.b / b.b) }
    public static func + (a: RGB, b: RGB) -> RGB { RGB(a.r + b.r, a.g + b.g, a.b + b.b) }
    public static func - (a: RGB, b: RGB) -> RGB { RGB(a.r - b.r, a.g - b.g, a.b - b.b) }
    public static func * (a: RGB, k: Double) -> RGB { RGB(a.r * k, a.g * k, a.b * k) }

    /// Each channel kept inside lo…hi.
    public func clamped(_ lo: Double = 0, _ hi: Double = 1) -> RGB {
        RGB(Swift.min(Swift.max(r, lo), hi), Swift.min(Swift.max(g, lo), hi), Swift.min(Swift.max(b, lo), hi))
    }

    /// Straight-line mix: t = 0 gives self, t = 1 gives other.
    public func mixed(with other: RGB, _ t: Double) -> RGB { self + (other - self) * t }

    /// Linear light → sRGB levels (each channel clipped to 0…1).
    public var encoded: RGB { RGB(AutoTone.encoded(r), AutoTone.encoded(g), AutoTone.encoded(b)) }

    /// sRGB levels → linear light.
    public var linear: RGB { RGB(AutoTone.linear(r), AutoTone.linear(g), AutoTone.linear(b)) }

    public var description: String { String(format: "(%.4f, %.4f, %.4f)", r, g, b) }
}
