import Foundation

/// Colour tools that change each colour by its own rule (Color mixer, …), shared by the iPad
/// renderer and the Linux tests.
///
/// Together they become one 3D lookup table (a colour cube) that Core Image applies in a single
/// pass (CIColorCubeWithColorSpace) on sRGB-encoded levels, i.e. what the eye sees.
///
///     ColorLook.cube(value, size: 33)   // RGBA floats, red varying fastest
///
/// `value` returns a control's current value, or nil when the control isn't in controls.json
/// (it then counts as untouched).
public enum ColorLook {
    // MARK: - Controls

    /// Color mixer bands and the hue each is centred on (degrees).
    public static let mixerBands = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
    static let mixerHues: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]
    public static let mixerProperties = ["Hue", "Saturation", "Luminance"]

    /// "mixerRedHue", "mixerAquaLuminance", … (see controls.json).
    public static func mixerID(_ band: String, _ property: String) -> String {
        "mixer" + band.prefix(1).uppercased() + band.dropFirst() + property
    }

    /// Point color: the picked hue, the shifts for colours near it, and how near counts.
    public static let pointIDs = ["pointHue", "pointHueShift", "pointSaturationShift", "pointLuminanceShift", "pointRange",
                                  "pointVariance"]

    /// Color grading: a hue, saturation and luminance per tonal zone (and one for the whole photo).
    public static let gradingZones = ["Shadows", "Midtones", "Highlights", "Global"]
    public static let gradingIDs = gradingZones.flatMap { zone in mixerProperties.map { "grading" + zone + $0 } }
        + ["gradingBlending", "gradingBalance"]

    /// Calibration: hue and saturation of the red, green and blue primaries, and a shadow tint.
    public static let calibrationIDs = ["calibrationShadowsTint"]
        + ["Red", "Green", "Blue"].flatMap { ["calibration" + $0 + "Hue", "calibration" + $0 + "Saturation"] }

    /// Black & white: on/off and how bright each colour band turns.
    public static let bwIDs = ["bw"] + mixerBands.map { "bw" + $0.prefix(1).uppercased() + $0.dropFirst() }

    /// Toning: option ids of the Toning choice, in controls.json order, and its palettes.
    public static let toningOptions = ["none", "sepia", "duotone", "tritone"]

    /// Channel mixer: "channelRedFromGreen" is how much of the green channel goes into red (%).
    public static let channelIDs: [String] = ["Red", "Green", "Blue"].flatMap { out in
        ["Red", "Green", "Blue"].map { "channel" + out + "From" + $0 }
    }

    /// Selective color: per colour family, how much cyan, magenta, yellow or black ink to add (%).
    public static let selectiveFamilies = ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas", "Whites", "Neutrals", "Blacks"]
    public static let selectiveInks = ["Cyan", "Magenta", "Yellow", "Black"]
    public static let selectiveIDs: [String] = selectiveFamilies.flatMap { family in selectiveInks.map { "selective" + family + $0 } }

    public static let mixerIDs: [String] = mixerBands.flatMap { band in mixerProperties.map { mixerID(band, $0) } }

    /// Control ids that feed the cube, in the order the steps run.
    public static let controlIDs: [String] = [
        calibrationIDs, mixerIDs, pointIDs, bwIDs, gradingIDs, selectiveIDs, channelIDs, ["toning", "toningAmount"],
        ["photoFilter", "photoFilterDensity"],
    ].flatMap { $0 }

    /// Controls that only say how another control acts (which hue, how wide): on their own they
    /// change nothing, so they don't count when deciding whether the cube is needed.
    static let modifierIDs: Set<String> = Set([
        ["pointHue", "pointRange", "gradingBlending", "gradingBalance", "toningAmount", "photoFilterDensity"],
        gradingZones.map { "grading" + $0 + "Hue" },
        Array(bwIDs.dropFirst()),
    ].flatMap { $0 })

    /// The value of each control that leaves the picture untouched (or its default, for modifiers).
    public static func neutral(_ id: String) -> Double {
        switch id {
        case "pointRange", "gradingBlending": return 50
        case "photoFilterDensity": return 25
        case "toningAmount", "channelRedFromRed", "channelGreenFromGreen", "channelBlueFromBlue": return 100
        default: return 0
        }
    }

    /// Whether every cube control is at its neutral value, so the cube can be skipped.
    public static func isIdentity(_ value: (String) -> Double?) -> Bool {
        controlIDs.allSatisfy { modifierIDs.contains($0) || (value($0) ?? neutral($0)) == neutral($0) }
    }

    /// The current values of the cube's controls.
    public struct Values {
        let values: [String: Double]
        // Worked out once per cube, not per colour (the cube has 36 000 colours).
        var calibration = ColorLook.identity3
        /// Per mixer band: hue, saturation, luminance.
        var mixer: [[Double]] = []
        var bwMix: [Double] = []
        /// Per grading zone: tint colour (already scaled by saturation) and luminance shift.
        var grading: [(tint: RGB, lum: Double)] = []
        /// Per selective family: cyan, magenta, yellow, black (already scaled); empty when all are 0.
        var selective: [[Double]] = []
        var channel: [[Double]] = []

        public init(_ value: (String) -> Double?) {
            var snapshot: [String: Double] = [:]
            for id in ColorLook.controlIDs { snapshot[id] = value(id) ?? ColorLook.neutral(id) }
            values = snapshot
            calibration = ColorLook.calibrationMatrix(self)
            let v = self
            mixer = ColorLook.mixerBands.map { band in ColorLook.mixerProperties.map { v[ColorLook.mixerID(band, $0)] } }
            bwMix = ColorLook.bwIDs.dropFirst().map { v[$0] }
            grading = ColorLook.gradingZones.map { zone in
                (ColorLook.tintDirection(hue: v["grading" + zone + "Hue"]) * (v["grading" + zone + "Saturation"] / 100 * 0.25),
                 v["grading" + zone + "Luminance"] / 100 * 0.15)
            }
            let families = ColorLook.selectiveFamilies.map { family in
                ColorLook.selectiveInks.map { v["selective" + family + $0] / 100 * 0.5 }
            }
            selective = families.contains { $0.contains { $0 != 0 } } ? families : []
            channel = ["Red", "Green", "Blue"].map { out in
                ["Red", "Green", "Blue"].map { v["channel" + out + "From" + $0] / 100 }
            }
        }

        subscript(_ id: String) -> Double { values[id] ?? ColorLook.neutral(id) }
    }

    // MARK: - The cube

    /// The lookup table for the current values: size³ RGBA entries (alpha 1), red varying fastest,
    /// then green, then blue, inputs and outputs on sRGB levels 0…1.
    public static func cube(_ value: (String) -> Double?, size: Int = 33) -> [Float] {
        let v = Values(value)
        var out: [Float] = []
        out.reserveCapacity(size * size * size * 4)
        let n = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let c = transform(RGB(Double(r) / n, Double(g) / n, Double(b) / n), v).clamped()
                    out += [Float(c.r), Float(c.g), Float(c.b), 1]
                }
            }
        }
        return out
    }

    /// Every cube step, in order, for one colour (sRGB levels).
    public static func transform(_ color: RGB, _ v: Values) -> RGB {
        var c = calibration(color, v)
        c = mixer(c, v)
        c = pointColor(c, v)
        c = blackAndWhite(c, v)
        c = grading(c, v)
        c = selectiveColor(c, v)
        c = channelMixer(c, v)
        c = toning(c, v)
        c = photoFilter(c, v)
        return c
    }

    // MARK: - Calibration

    /// Moves the red, green and blue primaries (Lightroom's Calibration), in linear light: Hue ±100
    /// turns a primary by up to 30° (red towards yellow or magenta, green towards aqua or yellow,
    /// blue towards purple or aqua); Saturation −100…100 takes its colour out or doubles it.
    /// White stays white. Shadows Tint adds magenta (+) or green (−) to the dark tones.
    static func calibration(_ color: RGB, _ v: Values) -> RGB {
        var out = color
        let m = v.calibration
        if m != identity3 {
            let lin = out.linear
            out = RGB(m[0][0] * lin.r + m[0][1] * lin.g + m[0][2] * lin.b,
                      m[1][0] * lin.r + m[1][1] * lin.g + m[1][2] * lin.b,
                      m[2][0] * lin.r + m[2][1] * lin.g + m[2][2] * lin.b).encoded
        }
        let tint = v["calibrationShadowsTint"] / 100
        if tint != 0 {
            let w = (1 - smoothstep(0, 0.5, out.luma)) * 0.08 * tint
            out = out + RGB(0.5 * w, -w, 0.5 * w)
        }
        return out
    }

    static let identity3: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

    /// The 3 × 3 matrix whose columns are the moved primaries; each row adds up to 1 (white stays).
    public static func calibrationMatrix(_ v: Values) -> [[Double]] {
        let names = ["Red", "Green", "Blue"]
        guard names.contains(where: { v["calibration" + $0 + "Hue"] != 0 || v["calibration" + $0 + "Saturation"] != 0 }) else {
            return identity3
        }
        var m = identity3
        for (j, name) in names.enumerated() {
            let angle = v["calibration" + name + "Hue"] / 100 * 30 * .pi / 180
            let scale = 1 + v["calibration" + name + "Saturation"] / 100
            // The primary = a grey part (1/3 each) + a colour part; turn the colour part about the grey axis.
            var q = [-1.0 / 3, -1.0 / 3, -1.0 / 3]
            q[j] += 1
            let rotated = rotateAboutGrey(q, angle)
            for i in 0..<3 { m[i][j] = 1.0 / 3 + scale * rotated[i] }
        }
        for i in 0..<3 {
            let excess = (m[i][0] + m[i][1] + m[i][2] - 1) / 3
            for j in 0..<3 { m[i][j] -= excess }
        }
        return m
    }

    /// Rotates a vector about the grey axis (1, 1, 1) by an angle (radians); positive turns red towards green.
    static func rotateAboutGrey(_ v: [Double], _ angle: Double) -> [Double] {
        let k = 1 / 3.0.squareRoot()
        let n = [k, k, k]
        let c = cos(angle), s = sin(angle)
        let dot = n[0] * v[0] + n[1] * v[1] + n[2] * v[2]
        let cross = [n[1] * v[2] - n[2] * v[1], n[2] * v[0] - n[0] * v[2], n[0] * v[1] - n[1] * v[0]]
        return (0..<3).map { v[$0] * c + cross[$0] * s + n[$0] * dot * (1 - c) }
    }

    // MARK: - Color mixer

    /// Hue, saturation and luminance per colour band. Each colour belongs to its two nearest bands
    /// (by hue). Hue ±100 turns it by up to 30°; Saturation −100 makes it grey, +100 doubles it;
    /// Luminance ±100 moves it halfway to white or black. Greys are left alone.
    static func mixer(_ color: RGB, _ v: Values) -> RGB {
        let chroma = color.max - color.min
        guard chroma > 1e-6 else { return color }
        var (h, s, l) = hsl(color)
        var dh = 0.0, ds = 0.0, dl = 0.0
        for (band, w) in bandWeights(hue: h) {
            dh += w * v.mixer[band][0] / 100 * 30
            ds += w * v.mixer[band][1] / 100
            dl += w * v.mixer[band][2] / 100
        }
        if dh == 0 && ds == 0 && dl == 0 { return color }
        h += dh
        s = Swift.min(Swift.max(s * (1 + ds), 0), 1)
        // Luminance acts on clearly coloured pixels; near-greys barely move.
        dl *= smoothstep(0, 0.25, chroma) * 0.5
        l = dl > 0 ? l + (1 - l) * dl : l * (1 + dl)
        return rgb(hue: h, saturation: s, lightness: l)
    }

    /// The two mixer bands (as indexes into `mixerBands`) a hue sits between and how much it
    /// belongs to each (they add up to 1).
    static func bandWeights(hue: Double) -> [(Int, Double)] {
        let h = wrap(hue)
        for i in mixerHues.indices {
            let lo = mixerHues[i]
            let hi = i + 1 < mixerHues.count ? mixerHues[i + 1] : 360
            if h >= lo && h < hi {
                let t = (h - lo) / (hi - lo)
                return [(i, 1 - t), ((i + 1) % mixerBands.count, t)]
            }
        }
        return [(0, 1)]
    }

    // MARK: - Point color

    /// Shifts the colours close to one picked hue. Point Range 0…100 sets how close: up to 10°…60°
    /// away (35° by default), fading out towards the edge; greys are never picked.
    /// Variance first evens out (−100: every picked colour takes the target hue) or spreads (+100:
    /// twice as far from it) the hues; then the shifts act as in the Color mixer: hue up to 30°,
    /// saturation to grey or double, luminance halfway.
    static func pointColor(_ color: RGB, _ v: Values) -> RGB {
        let hueShift = v["pointHueShift"], satShift = v["pointSaturationShift"], lumShift = v["pointLuminanceShift"]
        let variance = v["pointVariance"]
        guard hueShift != 0 || satShift != 0 || lumShift != 0 || variance != 0 else { return color }
        let w = pointWeight(color, v)
        guard w > 0 else { return color }
        var (h, s, l) = hsl(color)
        h += hueDifference(h, v["pointHue"]) * w * variance / 100
        h += w * hueShift / 100 * 30
        s = Swift.min(Swift.max(s * (1 + w * satShift / 100), 0), 1)
        let dl = w * lumShift / 100 * 0.5
        l = dl > 0 ? l + (1 - l) * dl : l * (1 + dl)
        return rgb(hue: h, saturation: s, lightness: l)
    }

    /// How much a colour belongs to the picked one (0…1).
    static func pointWeight(_ color: RGB, _ v: Values) -> Double {
        let chroma = color.max - color.min
        guard chroma > 1e-6 else { return 0 }
        let width = 10 + v["pointRange"] / 100 * 50
        let distance = abs(hueDifference(hsl(color).h, v["pointHue"]))
        guard distance < width else { return 0 }
        return smoothstep(0, 1, 1 - distance / width) * smoothstep(0.02, 0.12, chroma)
    }

    /// The hue to pick from a tapped colour (linear light), or nil for a grey with no clear hue.
    public static func pickedHue(linear color: RGB) -> Double? {
        let c = color.encoded
        guard c.max - c.min > 0.04 else { return nil }
        return hsl(c).h
    }

    /// a − b as an angle in −180…180.
    static func hueDifference(_ a: Double, _ b: Double) -> Double {
        let d = wrap(a - b)
        return d > 180 ? d - 360 : d
    }

    // MARK: - Black & white

    /// Grey from the colour's luma; each band's slider (±100) brightens or darkens the grey of
    /// colours in that band by up to about a stop, more for stronger colours.
    static func blackAndWhite(_ color: RGB, _ v: Values) -> RGB {
        guard v["bw"] != 0 else { return color }
        var grey = color.luma
        let chroma = color.max - color.min
        if chroma > 1e-6 {
            var stops = 0.0
            for (band, w) in bandWeights(hue: hsl(color).h) {
                stops += w * v.bwMix[band] / 100
            }
            grey *= pow(2, stops * chroma * 1.5)
        }
        return RGB(grey, grey, grey)
    }

    // MARK: - Color grading

    /// Tints and brightens shadows, midtones and highlights (by the pixel's luma), plus the whole
    /// photo. Saturation 100 adds a colour of that hue worth a quarter of the level range;
    /// Luminance ±100 moves the zone's levels by ±0.15. Balance −100…100 hands more of the tones to
    /// the shadows or the highlights; Blending 0…100 makes the zones overlap less or more.
    static func grading(_ color: RGB, _ v: Values) -> RGB {
        let y = color.luma
        let shifted = Swift.min(Swift.max(y + 0.25 * v["gradingBalance"] / 100, 0), 1)
        let e = pow(4, (50 - v["gradingBlending"]) / 50)
        let shadows = pow(Swift.min(Swift.max(1 - 2 * shifted, 0), 1), e)
        let highlights = pow(Swift.min(Swift.max(2 * shifted - 1, 0), 1), e)
        let weights = [shadows, 1 - shadows - highlights, highlights, 1]  // gradingZones order
        var out = color
        for (zone, w) in weights.enumerated() where w > 0 {
            let (tint, lum) = v.grading[zone]
            out = out + tint * w + RGB(1, 1, 1) * (w * lum)
        }
        return out
    }

    /// The pure colour of a hue with its luma taken out: adding it tints without brightening.
    static func tintDirection(hue: Double) -> RGB {
        let c = rgb(hue: hue, saturation: 1, lightness: 0.5)
        return c - RGB(1, 1, 1) * c.luma
    }

    // MARK: - Selective color

    /// Photoshop's Selective Color (absolute): each family's ink sliders add (+) or take away (−)
    /// cyan, magenta, yellow (the opposites of red, green, blue) or black, up to half the level
    /// range, in the pixels that belong to that family.
    static func selectiveColor(_ color: RGB, _ v: Values) -> RGB {
        guard !v.selective.isEmpty else { return color }
        var dc = 0.0, dm = 0.0, dy = 0.0, dk = 0.0
        for (i, family) in selectiveFamilies.enumerated() {
            let amounts = v.selective[i]
            guard amounts.contains(where: { $0 != 0 }) else { continue }
            let w = selectiveWeight(color, family: family)
            guard w > 0 else { continue }
            dc += w * amounts[0]
            dm += w * amounts[1]
            dy += w * amounts[2]
            dk += w * amounts[3]
        }
        if dc == 0 && dm == 0 && dy == 0 && dk == 0 { return color }
        var out = RGB(color.r - dc, color.g - dm, color.b - dy)
        out = dk > 0 ? out * (1 - Swift.min(dk, 1)) : out + (RGB(1, 1, 1) - out) * Swift.min(-dk, 1)
        return out
    }

    /// How much a colour belongs to a Selective color family (0…1).
    static func selectiveWeight(_ c: RGB, family: String) -> Double {
        let chroma = c.max - c.min
        let whites = Swift.min(Swift.max((c.min - 0.5) * 2, 0), 1)
        let blacks = Swift.min(Swift.max((0.5 - c.max) * 2, 0), 1)
        switch family {
        case "Whites": return whites
        case "Blacks": return blacks
        case "Neutrals": return (1 - chroma) * Swift.max(0, 1 - whites - blacks)
        default:
            let centres = ["Reds": 0.0, "Yellows": 60, "Greens": 120, "Cyans": 180, "Blues": 240, "Magentas": 300]
            guard let centre = centres[family], chroma > 1e-6 else { return 0 }
            let distance = abs(hueDifference(hsl(c).h, centre))
            return Swift.max(0, 1 - distance / 60) * chroma
        }
    }

    // MARK: - Channel mixer

    /// Rebuilds each channel from the three (on sRGB levels, like Photoshop): red = red-from-red %
    /// of red + red-from-green % of green + red-from-blue % of blue, and so on.
    static func channelMixer(_ color: RGB, _ v: Values) -> RGB {
        let m = v.channel
        return RGB(m[0][0] * color.r + m[0][1] * color.g + m[0][2] * color.b,
                   m[1][0] * color.r + m[1][1] * color.g + m[1][2] * color.b,
                   m[2][0] * color.r + m[2][1] * color.g + m[2][2] * color.b)
    }

    // MARK: - Toning

    /// Colours (from black to white) that each toning style gives the photo's tones.
    static let toningPalettes: [String: [(Double, RGB)]] = [
        "sepia": [(0, RGB(0.08, 0.05, 0.02)), (0.5, RGB(0.62, 0.47, 0.30)), (1, RGB(1, 0.96, 0.88))],
        "duotone": [(0, RGB(0, 0, 0)), (0.5, RGB(0.30, 0.53, 0.66)), (1, RGB(1, 1, 1))],
        "tritone": [(0, RGB(0, 0, 0)), (0.33, RGB(0.35, 0.22, 0.30)), (0.66, RGB(0.85, 0.60, 0.35)), (1, RGB(1, 1, 1))],
    ]

    /// Replaces each colour by the style's colour for its brightness, mixed in by Toning Amount.
    static func toning(_ color: RGB, _ v: Values) -> RGB {
        let index = Int(v["toning"])
        guard toningOptions.indices.contains(index), let stops = toningPalettes[toningOptions[index]] else { return color }
        return color.mixed(with: gradient(stops, color.luma), v["toningAmount"] / 100)
    }

    /// The colour at position t (0…1) along a gradient of (position, colour) stops.
    static func gradient(_ stops: [(Double, RGB)], _ t: Double) -> RGB {
        guard let first = stops.first, let last = stops.last else { return RGB(t, t, t) }
        if t <= first.0 { return first.1 }
        for i in 1..<stops.count where t <= stops[i].0 {
            let (p0, c0) = stops[i - 1], (p1, c1) = stops[i]
            return c0.mixed(with: c1, (t - p0) / (p1 - p0))
        }
        return last.1
    }

    // MARK: - Photo filter

    /// Option ids of the Photo Filter choice (controls.json order) and their colours (Photoshop's).
    public static let photoFilterOptions = ["none", "warming", "cooling", "red", "orange", "yellow", "green", "cyan",
                                            "blue", "violet", "magenta", "sepia", "underwater"]
    static let photoFilterColors: [String: RGB] = [
        "warming": hex(0xEC8A00), "cooling": hex(0x006DFF), "red": hex(0xEA1A1A), "orange": hex(0xF38417),
        "yellow": hex(0xF9E31C), "green": hex(0x19C919), "cyan": hex(0x1DCBEA), "blue": hex(0x1D35EA),
        "violet": hex(0x9B1DEA), "magenta": hex(0xE318E3), "sepia": hex(0xAC7A33), "underwater": hex(0x00C1B1),
    ]

    /// A coloured filter in front of the lens: the photo multiplied by the filter colour, mixed in by
    /// Density (0…100 %), with the brightness kept as it was.
    static func photoFilter(_ color: RGB, _ v: Values) -> RGB {
        let index = Int(v["photoFilter"])
        guard photoFilterOptions.indices.contains(index), let filter = photoFilterColors[photoFilterOptions[index]] else {
            return color
        }
        let filtered = color.mixed(with: color * filter, v["photoFilterDensity"] / 100)
        let luma = filtered.luma
        return luma > 1e-6 ? filtered * (color.luma / luma) : filtered
    }

    static func hex(_ value: Int) -> RGB {
        RGB(Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    // MARK: - Colour helpers

    /// Hue (degrees 0…360), saturation and lightness (0…1) of an RGB colour.
    public static func hsl(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let mx = c.max, mn = c.min
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 1e-9 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if mx == c.r {
            h = (c.g - c.b) / d
        } else if mx == c.g {
            h = (c.b - c.r) / d + 2
        } else {
            h = (c.r - c.g) / d + 4
        }
        return (wrap(h * 60), Swift.min(s, 1), l)
    }

    /// The RGB colour for a hue (degrees), saturation and lightness (0…1).
    public static func rgb(hue: Double, saturation s: Double, lightness l: Double) -> RGB {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = wrap(hue) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGB(r + m, g + m, b + m)
    }

    /// An angle in 0..<360.
    static func wrap(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// 0 below `lo`, 1 above `hi`, a smooth S in between.
    static func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
        let t = Swift.min(Swift.max((x - lo) / (hi - lo), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
