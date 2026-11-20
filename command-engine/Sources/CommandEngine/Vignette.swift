import Foundation

/// Vignette masks, worked out on a small grid that the iPad renderer stretches over the photo
/// (the masks are smooth, so 256 cells on the long side are plenty). 0 = untouched, 1 = full strength.
///
///     Vignette.strength(u: 1, v: 1, aspect: 1.5, midpoint: 0.5, roundness: 0, feather: 0.5)  → 1 (a corner)
public enum Vignette {
    /// Post-crop vignette strength at a point. `u`, `v`: position across the frame, −1…1 (centre 0);
    /// `aspect`: width ÷ height. `midpoint` (0…1): how far in it reaches, 0 = deep, 1 = corners only.
    /// `roundness` (−1…1): −1 rectangular, 0 follows the frame (an ellipse), 1 a circle.
    /// `feather` (0…1): 0 a hard edge, 1 a long soft fade.
    public static func strength(u: Double, v: Double, aspect: Double, midpoint: Double, roundness: Double,
                                feather: Double) -> Double {
        var x = abs(u), y = abs(v)
        var power = 2.0
        if roundness >= 0 {
            // Towards a circle: measure in pixels, scaled so a corner stays at the same distance (√2).
            let diagonal = (aspect * aspect + 1).squareRoot()
            x += (x * 2.0.squareRoot() * aspect / diagonal - x) * roundness
            y += (y * 2.0.squareRoot() / diagonal - y) * roundness
        } else {
            // Towards a rectangle: a squarer superellipse.
            power = 2 + 6 * -roundness
        }
        let distance = pow(pow(x, power) + pow(y, power), 1 / power)
        let edge = 0.4 + 0.9 * midpoint
        let width = 0.02 + feather
        return Effects.smoothstep(edge - width / 2, edge + width / 2, distance)
    }

    /// `strength` on a grid of `width` × `height` cells, row by row from the top, at cell centres.
    public static func mask(width: Int, height: Int, midpoint: Double, roundness: Double, feather: Double) -> [Double] {
        let aspect = Double(width) / Double(height)
        var out: [Double] = []
        out.reserveCapacity(width * height)
        for row in 0..<height {
            let v = (Double(row) + 0.5) / Double(height) * 2 - 1
            for column in 0..<width {
                let u = (Double(column) + 0.5) / Double(width) * 2 - 1
                out.append(strength(u: u, v: v, aspect: aspect, midpoint: midpoint, roundness: roundness, feather: feather))
            }
        }
        return out
    }

    /// Grid size for a photo: `cells` on the long side, the short side in proportion (at least 2).
    public static func gridSize(width: Double, height: Double, cells: Int = 256) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (cells, cells) }
        let scale = Double(cells) / Swift.max(width, height)
        return (Swift.max(2, Int((width * scale).rounded())), Swift.max(2, Int((height * scale).rounded())))
    }
}
