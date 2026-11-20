import Dispatch
import Foundation

/// The Optics panel's geometry, worked out on the CPU (Core Image has no general lens warp). For every
/// pixel of the corrected photo it finds where that point was in the photo as shot, per colour channel,
/// reads the colour there (bilinear) and undoes the profile's vignetting. The corrected photo is scaled
/// to fill the frame, so no empty corners show.
///
///     LensWarp(profile: correction).apply(pixels, width: 3000, height: 2000)   // RGBA floats in, RGBA floats out
public struct LensWarp: Equatable {
    /// Lens profile correction (distortion, colour fringing, vignetting), when on.
    public var profile: LensCorrection?
    /// Chromatic aberration: red and blue are read this many times further out than green (1 = as shot).
    public var redScale: Double
    public var blueScale: Double
    /// Manual distortion, −1…1: positive straightens barrel distortion (lines bowing out), negative
    /// straightens pincushion distortion (lines bowing in).
    public var distortion: Double
    /// Fisheye correction, 0…1: shows a fisheye photo (up to 120° across the diagonal) as a normal,
    /// straight-lined one. Negative values do the opposite, a fisheye look (for test pictures).
    public var fisheye: Double

    public init(profile: LensCorrection? = nil, redScale: Double = 1, blueScale: Double = 1, distortion: Double = 0,
                fisheye: Double = 0) {
        self.profile = profile
        self.redScale = redScale
        self.blueScale = blueScale
        self.distortion = distortion
        self.fisheye = fisheye
    }

    /// Nothing to do.
    public var isIdentity: Bool {
        profile == nil && redScale == 1 && blueScale == 1 && distortion == 0 && fisheye == 0
    }

    /// A position in pixels from the photo's centre.
    public struct Point: Equatable {
        public var x, y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        var length: Double { (x * x + y * y).squareRoot() }

        func scaled(_ k: Double) -> Point { Point(x: x * k, y: y * k) }
    }

    /// Where a point of the corrected photo (pixels from the centre, before the fill scaling) was in
    /// the photo as shot, for red, green and blue. `width`, `height`: the photo's size in pixels.
    public func source(of p: Point, width: Double, height: Double) -> (red: Point, green: Point, blue: Point) {
        var q = p
        let corner = (width * width + height * height).squareRoot() / 2
        // Fisheye correction: an equidistant fisheye puts a ray at angle a at radius a ÷ θ (r = 1 at the
        // corner, θ the corner's angle); a normal lens at tan a ÷ tan θ. So a corrected point at r is
        // read from atan(r·tan θ) ÷ θ, and the fisheye look the other way round.
        if fisheye != 0 {
            let theta = Swift.min(1, abs(fisheye)) * Double.pi / 3
            let r = q.length / corner
            if r > 0 {
                let to = fisheye > 0 ? atan(r * tan(theta)) / theta
                    : tan(Swift.min(r * theta, Double.pi / 2 - 1e-6)) / tan(theta)
                q = q.scaled(to / r)
            }
        }
        // Manual distortion: read from r·(1 + k r²), r = 1 at the corner. k < 0 pulls the corners in
        // (a pincushion warp, which straightens barrel distortion).
        if distortion != 0 {
            let r = q.length / corner
            q = q.scaled(1 - 0.25 * distortion * r * r)
        }
        var red = 1.0, blue = 1.0
        if let lens = profile {
            let short = Swift.min(width, height) / 2
            let r = q.length / short
            q = q.scaled(lens.a * r * r * r + lens.b * r * r + lens.c * r + 1 - lens.a - lens.b - lens.c)
            let rg = q.length / short
            red = lens.red.b * rg * rg + lens.red.c * rg + lens.red.v
            blue = lens.blue.b * rg * rg + lens.blue.c * rg + lens.blue.v
        }
        return (q.scaled(red * redScale), q, q.scaled(blue * blueScale))
    }

    /// Brightness gain for a point of the photo as shot: the profile's vignetting, undone.
    public func gain(at q: Point, width: Double, height: Double) -> Double {
        guard let lens = profile, lens.k1 != 0 || lens.k2 != 0 || lens.k3 != 0 else { return 1 }
        let r2 = (q.x * q.x + q.y * q.y) / ((width * width + height * height) / 4)
        let c = 1 + lens.k1 * r2 + lens.k2 * r2 * r2 + lens.k3 * r2 * r2 * r2
        return 1 / Swift.max(c, 0.2)
    }

    /// The largest scale (corrected point × scale → lookup), at most 1, at which every point on the
    /// frame's edge still finds its colour inside the photo as shot, so the frame stays filled. Never
    /// more than 1: zooming out past the original frame could fold a strong warp back on itself.
    public func fillScale(width: Double, height: Double) -> Double {
        func fits(_ s: Double) -> Bool {
            let n = 32
            for i in 0...n {
                let t = Double(i) / Double(n) * 2 - 1
                let edge = [Point(x: t * width / 2, y: height / 2), Point(x: t * width / 2, y: -height / 2),
                            Point(x: width / 2, y: t * height / 2), Point(x: -width / 2, y: t * height / 2)]
                for p in edge {
                    let src = source(of: p.scaled(s), width: width, height: height)
                    for q in [src.red, src.green, src.blue]
                    where abs(q.x) > width / 2 + 1e-6 || abs(q.y) > height / 2 + 1e-6 {
                        return false
                    }
                }
            }
            return true
        }
        var lo = 0.25, hi = 1.0
        if !fits(lo) { return lo }
        if fits(hi) { return hi }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return abs(lo - 1) < 1e-4 ? 1 : lo
    }

    /// The corrected picture. `pixels`: RGBA floats, row by row (`width` × `height`), linear light.
    public func apply(_ pixels: [Float], width: Int, height: Int) -> [Float] {
        guard !isIdentity, width > 1, height > 1, pixels.count >= width * height * 4 else { return pixels }
        let w = Double(width), h = Double(height)
        let scale = fillScale(width: w, height: h)
        var out = [Float](repeating: 1, count: width * height * 4)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: height) { row in
                    for column in 0..<width {
                        let p = Point(x: (Double(column) + 0.5 - w / 2) * scale, y: (Double(row) + 0.5 - h / 2) * scale)
                        let at = source(of: p, width: w, height: h)
                        let g = Float(gain(at: at.green, width: w, height: h))
                        let i = (row * width + column) * 4
                        base[i] = Self.sample(src, width, height, at.red, 0) * g
                        base[i + 1] = Self.sample(src, width, height, at.green, 1) * g
                        base[i + 2] = Self.sample(src, width, height, at.blue, 2) * g
                    }
                }
            }
        }
        return out
    }

    /// One channel at a point (pixels from the centre), bilinear; points outside take the edge.
    static func sample(_ p: UnsafeBufferPointer<Float>, _ width: Int, _ height: Int, _ at: Point, _ channel: Int) -> Float {
        let x = Swift.min(Swift.max(at.x + Double(width) / 2 - 0.5, 0), Double(width - 1))
        let y = Swift.min(Swift.max(at.y + Double(height) / 2 - 0.5, 0), Double(height - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = Swift.min(x0 + 1, width - 1), y1 = Swift.min(y0 + 1, height - 1)
        let tx = Float(x - Double(x0)), ty = Float(y - Double(y0))
        let top = p[(y0 * width + x0) * 4 + channel] * (1 - tx) + p[(y0 * width + x1) * 4 + channel] * tx
        let bottom = p[(y1 * width + x0) * 4 + channel] * (1 - tx) + p[(y1 * width + x1) * 4 + channel] * tx
        return top * (1 - ty) + bottom * ty
    }
}
