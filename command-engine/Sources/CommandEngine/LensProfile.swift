import Foundation

/// The lens a photo was taken with, from its EXIF data.
public struct PhotoLens: Equatable {
    public var make: String?
    public var lensModel: String?
    /// Focal length in mm and aperture as an f-number.
    public var focal: Double?
    public var aperture: Double?

    public init(make: String? = nil, lensModel: String? = nil, focal: Double? = nil, aperture: Double? = nil) {
        self.make = make
        self.lensModel = lensModel
        self.focal = focal
        self.aperture = aperture
    }
}

/// One lens correction, in lensfun's models (see LensWarp, which applies it):
/// - distortion (PTLens): a point at radius r in the corrected photo was shot at r·(a r³ + b r² + c r + 1 − a − b − c),
///   r = 1 at half the shorter side;
/// - colour fringing (TCA, poly3): red and blue sit at r·(b r² + c r + v) of where green sits, same r;
/// - vignetting (PA): corrected = shot ÷ (1 + k1 r² + k2 r⁴ + k3 r⁶), r = 1 at the corner.
public struct LensCorrection: Equatable {
    public struct Fringe: Equatable {
        public var b = 0.0, c = 0.0, v = 1.0
        public init(b: Double = 0, c: Double = 0, v: Double = 1) {
            self.b = b
            self.c = c
            self.v = v
        }
    }

    public var a = 0.0, b = 0.0, c = 0.0
    public var red = Fringe(), blue = Fringe()
    public var k1 = 0.0, k2 = 0.0, k3 = 0.0

    public init(a: Double = 0, b: Double = 0, c: Double = 0, red: Fringe = Fringe(), blue: Fringe = Fringe(),
                k1: Double = 0, k2: Double = 0, k3: Double = 0) {
        self.a = a
        self.b = b
        self.c = c
        self.red = red
        self.blue = blue
        self.k1 = k1
        self.k2 = k2
        self.k3 = k3
    }
}

/// Lens profiles for a few common lenses, copied from the lensfun database (Resources/lens-profiles.json,
/// CC BY-SA 3.0, by the lensfun contributors). Photos from Apple devices are corrected by the camera
/// already, and raw files get Apple's own lens correction when they are decoded, so this is for
/// JPEGs from other cameras.
///
///     LensProfile.correction(for: PhotoLens(lensModel: "EF-S18-55mm f/3.5-5.6 IS STM", focal: 18, aperture: 3.5))
public struct LensProfile: Codable, Equatable {
    public struct Distortion: Codable, Equatable {
        public let focal, a, b, c: Double
    }

    public struct TCA: Codable, Equatable {
        public let focal, br, cr, vr, bb, cb, vb: Double
    }

    public struct Vignetting: Codable, Equatable {
        public let focal, aperture, k1, k2, k3: Double
    }

    public let maker: String
    public let model: String
    /// Crop factor of the camera the lens was measured on (the correction assumes the same sensor size).
    public let crop: Double
    public let distortion: [Distortion]
    public let tca: [TCA]
    public let vignetting: [Vignetting]

    /// The bundled profiles.
    public static let bundled: [LensProfile] = {
        struct File: Codable { let lenses: [LensProfile] }
        guard let url = Bundle.module.url(forResource: "lens-profiles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.lenses
    }()

    /// The profile and correction for a photo's lens, or nil when no profile fits (or the lens is unknown).
    public static func correction(for photo: PhotoLens, in profiles: [LensProfile] = bundled) -> (profile: LensProfile, correction: LensCorrection)? {
        guard let model = photo.lensModel, let profile = find(lensModel: model, in: profiles) else { return nil }
        let focal = photo.focal ?? profile.distortion.first?.focal ?? 0
        return (profile, profile.correction(focal: focal, aperture: photo.aperture))
    }

    /// The profile whose lens name matches the EXIF lens model, compared without spaces, punctuation
    /// and maker names ("EF-S18-55mm f/3.5-5.6 IS STM" fits "Canon EF-S 18-55mm f/3.5-5.6 IS STM").
    public static func find(lensModel: String, in profiles: [LensProfile] = bundled) -> LensProfile? {
        let wanted = key(lensModel)
        guard wanted.count >= 6 else { return nil }
        return profiles.first { profile in
            let name = key(profile.model)
            return name == wanted || (wanted.count >= 10 && (name.hasPrefix(wanted) || wanted.hasPrefix(name)))
        }
    }

    static func key(_ name: String) -> String {
        var s = name.lowercased()
        for maker in ["canon", "nikon", "sony", "fujifilm", "fujinon"] {
            s = s.replacingOccurrences(of: maker, with: "")
        }
        return String(s.filter { $0.isLetter || $0.isNumber })
    }

    /// The correction at a focal length (mm) and aperture (f-number; the widest measured when nil),
    /// interpolated between the measured focal lengths.
    public func correction(focal: Double, aperture: Double?) -> LensCorrection {
        var out = LensCorrection()
        let d = Self.interpolate(distortion.map { ($0.focal, [$0.a, $0.b, $0.c]) }, at: focal, neutral: [0, 0, 0])
        (out.a, out.b, out.c) = (d[0], d[1], d[2])
        let t = Self.interpolate(tca.map { ($0.focal, [$0.br, $0.cr, $0.vr, $0.bb, $0.cb, $0.vb]) }, at: focal,
                                 neutral: [0, 0, 1, 0, 0, 1])
        out.red = LensCorrection.Fringe(b: t[0], c: t[1], v: t[2])
        out.blue = LensCorrection.Fringe(b: t[3], c: t[4], v: t[5])
        // Vignetting: at each measured focal length, the aperture nearest the photo's (in stops).
        var nearest: [Double: Vignetting] = [:]
        for entry in vignetting {
            let wanted = aperture ?? 0
            if let current = nearest[entry.focal] {
                let better = aperture == nil ? entry.aperture < current.aperture
                    : abs(log2(entry.aperture / wanted)) < abs(log2(current.aperture / wanted))
                if better { nearest[entry.focal] = entry }
            } else {
                nearest[entry.focal] = entry
            }
        }
        let v = Self.interpolate(nearest.values.map { ($0.focal, [$0.k1, $0.k2, $0.k3]) }, at: focal, neutral: [0, 0, 0])
        (out.k1, out.k2, out.k3) = (v[0], v[1], v[2])
        return out
    }

    /// Straight-line interpolation of coefficient lists between the two nearest focal lengths
    /// (the nearest end beyond the measured range); `neutral` when nothing was measured.
    static func interpolate(_ points: [(focal: Double, values: [Double])], at focal: Double, neutral: [Double]) -> [Double] {
        let sorted = points.sorted { $0.focal < $1.focal }
        guard let first = sorted.first, let last = sorted.last else { return neutral }
        if focal <= first.focal { return first.values }
        if focal >= last.focal { return last.values }
        for (lo, hi) in zip(sorted, sorted.dropFirst()) where focal <= hi.focal {
            let t = (focal - lo.focal) / (hi.focal - lo.focal)
            return zip(lo.values, hi.values).map { $0 + ($1 - $0) * t }
        }
        return last.values
    }
}
