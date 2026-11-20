import Foundation

/// A 3D colour lookup table read from an Adobe `.cube` file (the common LUT format), shared by the
/// iPad renderer and the Linux tests. Entries are on sRGB levels, red varying fastest — the layout
/// Core Image's CIColorCube expects.
///
///     let lut = try CubeLUT.bundled("tealOrange")
///     lut.cubeData(amount: 0.5)   // RGBA floats, half way between no change and the LUT
public struct CubeLUT: Equatable {
    public let title: String
    public let size: Int
    /// size³ output colours, red varying fastest, then green, then blue.
    public let entries: [RGB]

    public enum ParseError: Error, Equatable {
        case missingSize
        case badLine(Int)
        case wrongCount(expected: Int, found: Int)
    }

    /// Option ids of the LUT choice (controls.json order, "none" first) and their bundled files.
    public static let options = ["none", "tealOrange", "warmFilm", "bleachBypass"]
    static let files = ["tealOrange": "TealOrange", "warmFilm": "WarmFilm", "bleachBypass": "BleachBypass"]

    /// Reads `.cube` text: TITLE, LUT_3D_SIZE, optional DOMAIN_MIN/MAX, then one "r g b" line per entry.
    public static func parse(_ text: String) throws -> CubeLUT {
        var title = "", size = 0
        var lo = RGB(0, 0, 0), hi = RGB(1, 1, 1)
        var entries: [RGB] = []
        for (n, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch parts[0] {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            case "LUT_3D_SIZE":
                size = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let v = parts.dropFirst().compactMap(Double.init)
                guard v.count == 3 else { throw ParseError.badLine(n + 1) }
                if parts[0] == "DOMAIN_MIN" { lo = RGB(v[0], v[1], v[2]) } else { hi = RGB(v[0], v[1], v[2]) }
            case "LUT_1D_SIZE", "LUT_3D_INPUT_RANGE":
                continue
            default:
                let v = parts.compactMap(Double.init)
                guard v.count == 3, parts.count == 3 else { throw ParseError.badLine(n + 1) }
                // Outputs are scaled from the file's domain to 0…1.
                entries.append(RGB((v[0] - lo.r) / (hi.r - lo.r), (v[1] - lo.g) / (hi.g - lo.g), (v[2] - lo.b) / (hi.b - lo.b)))
            }
        }
        guard size >= 2 else { throw ParseError.missingSize }
        guard entries.count == size * size * size else {
            throw ParseError.wrongCount(expected: size * size * size, found: entries.count)
        }
        return CubeLUT(title: title, size: size, entries: entries)
    }

    /// One of the LUTs that ship with the app, by option id.
    public static func bundled(_ option: String) throws -> CubeLUT {
        guard let file = files[option], let url = Bundle.module.url(forResource: file, withExtension: "cube") else {
            throw ControlRegistry.RegistryError.missingFile
        }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// RGBA floats for CIColorCube, mixed with "no change" by `amount` (0…1).
    public func cubeData(amount: Double) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(entries.count * 4)
        let n = Double(size - 1)
        for (i, entry) in entries.enumerated() {
            let identity = RGB(Double(i % size) / n, Double((i / size) % size) / n, Double(i / (size * size)) / n)
            let c = identity.mixed(with: entry, amount).clamped()
            out += [Float(c.r), Float(c.g), Float(c.b), 1]
        }
        return out
    }

    /// The LUT's output for a colour, with trilinear interpolation (what Core Image does).
    public func lookup(_ c: RGB) -> RGB {
        let n = Double(size - 1)
        func split(_ x: Double) -> (Int, Double) {
            let t = Swift.min(Swift.max(x, 0), 1) * n
            let i = Swift.min(Int(t), size - 2)
            return (i, t - Double(i))
        }
        let (ri, rt) = split(c.r), (gi, gt) = split(c.g), (bi, bt) = split(c.b)
        func at(_ r: Int, _ g: Int, _ b: Int) -> RGB { entries[(b * size + g) * size + r] }
        func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a.mixed(with: b, t) }
        let c00 = lerp(at(ri, gi, bi), at(ri + 1, gi, bi), rt), c10 = lerp(at(ri, gi + 1, bi), at(ri + 1, gi + 1, bi), rt)
        let c01 = lerp(at(ri, gi, bi + 1), at(ri + 1, gi, bi + 1), rt)
        let c11 = lerp(at(ri, gi + 1, bi + 1), at(ri + 1, gi + 1, bi + 1), rt)
        return lerp(lerp(c00, c10, gt), lerp(c01, c11, gt), bt)
    }
}
