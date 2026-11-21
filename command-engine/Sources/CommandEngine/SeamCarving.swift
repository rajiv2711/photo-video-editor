import Foundation

/// Where each point of a picture comes from in another picture: a grid of positions (normalized,
/// 0…1 from the top-left), one per cell, read between cells by straight-line interpolation. Content-
/// aware scale and warp give their pictures as these; the iPad stretches the grid over the picture
/// and reads each pixel from where it says (a small Core Image kernel).
public struct WarpMap: Equatable {
    public let width: Int
    public let height: Int
    /// x, y of each cell, row by row from the top.
    public var positions: [Float]

    public init(width: Int, height: Int, positions: [Float]) {
        self.width = width
        self.height = height
        self.positions = positions
    }

    /// No change: each cell reads its own place.
    public static func identity(width: Int, height: Int) -> WarpMap {
        var p = [Float](repeating: 0, count: width * height * 2)
        for y in 0..<height {
            for x in 0..<width {
                p[(y * width + x) * 2] = Float((Double(x) + 0.5) / Double(width))
                p[(y * width + x) * 2 + 1] = Float((Double(y) + 0.5) / Double(height))
            }
        }
        return WarpMap(width: width, height: height, positions: p)
    }

    /// Where the point `p` (normalized on the output) reads from (normalized on the input).
    public func lookup(_ p: MaskPoint) -> MaskPoint {
        guard width > 0, height > 0 else { return p }
        let fx = Swift.min(Swift.max(p.x * Double(width) - 0.5, 0), Double(width - 1))
        let fy = Swift.min(Swift.max(p.y * Double(height) - 0.5, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy), x1 = Swift.min(x0 + 1, width - 1), y1 = Swift.min(y0 + 1, height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func at(_ x: Int, _ y: Int, _ c: Int) -> Double { Double(positions[(y * width + x) * 2 + c]) }
        func mix(_ c: Int) -> Double {
            (at(x0, y0, c) * (1 - tx) + at(x1, y0, c) * tx) * (1 - ty) + (at(x0, y1, c) * (1 - tx) + at(x1, y1, c) * tx) * ty
        }
        return MaskPoint(mix(0), mix(1))
    }

    /// How far each cell reads from where a plain stretch would (normalized; x right, y down): the
    /// numbers the iPad's kernel adds, small so they keep their precision.
    public var displacements: [Float] {
        var d = positions
        for y in 0..<height {
            for x in 0..<width {
                d[(y * width + x) * 2] -= Float((Double(x) + 0.5) / Double(width))
                d[(y * width + x) * 2 + 1] -= Float((Double(y) + 0.5) / Double(height))
            }
        }
        return d
    }
}

/// Content-aware scale by seam carving (Avidan & Shamir): to make a picture narrower, the path from
/// top to bottom through the least busy pixels (lowest gradient energy, found by dynamic programming)
/// is taken out, again and again, so busy parts (the subject) keep their shape while plain parts
/// (sky, a backdrop) give way. To widen it, the paths that would have been taken out first are doubled.
/// The same, turned, for the height. It works on a small grid (long side about 256) and gives a
/// WarpMap, which the full picture is read through, so the cuts become smooth squeezes.
public enum SeamCarving {
    /// The grid size for a picture: long side `side`, the picture's shape.
    public static func gridSize(width: Double, height: Double, side: Int = 256) -> (width: Int, height: Int) {
        let s = Double(side) / Swift.max(width, height)
        return (Swift.max(8, Int((width * s).rounded())), Swift.max(8, Int((height * s).rounded())))
    }

    /// Energy of a grey grid: |∂x| + |∂y| (central differences), plus a little so flat areas still
    /// share the cuts evenly.
    public static func energy(_ gray: [Float], width: Int, height: Int) -> [Float] {
        var e = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let l = gray[y * width + Swift.max(x - 1, 0)], r = gray[y * width + Swift.min(x + 1, width - 1)]
                let u = gray[Swift.max(y - 1, 0) * width + x], d = gray[Swift.min(y + 1, height - 1) * width + x]
                e[y * width + x] = abs(r - l) + abs(d - u) + 0.002
            }
        }
        return e
    }

    /// The map that scales a `width` × `height` energy grid to `width × sx` by `height × sy` cells,
    /// content-aware (sx, sy: 0.5…1.5).
    public static func map(energy: [Float], width: Int, height: Int, sx: Double, sy: Double) -> WarpMap {
        let tw = Swift.max(2, Int((Double(width) * sx).rounded())), th = Swift.max(2, Int((Double(height) * sy).rounded()))
        // Width: for each row, the grid column each new column reads.
        let (columns, carved) = resize(energy, width: width, height: height, to: tw)
        // Height: the same on the turned, width-carved grid; for each new column, the row each new row reads.
        let turned = transpose(carved, width: tw, height: height)
        let (rowsByColumn, _) = resize(turned, width: height, height: tw, to: th)
        var positions = [Float](repeating: 0, count: tw * th * 2)
        for y in 0..<th {
            for x in 0..<tw {
                let row = rowsByColumn[x][y]  // a row of the width-carved grid
                let column = columns[Int(row)][x]
                positions[(y * tw + x) * 2] = Float((column + 0.5) / Double(width))
                positions[(y * tw + x) * 2 + 1] = Float((row + 0.5) / Double(height))
            }
        }
        var out = WarpMap(width: tw, height: th, positions: positions)
        smooth(&out)
        return out
    }

    /// Each row's source columns after taking seams out (or doubling them) to reach `target` columns,
    /// and the energy grid carved the same way.
    static func resize(_ energy: [Float], width: Int, height: Int, to target: Int) -> (columns: [[Double]], carved: [Float]) {
        if target == width {
            return (Array(repeating: (0..<width).map(Double.init), count: height), energy)
        }
        if target < width {
            var e = energy, w = width
            var index = Array(repeating: (0..<width).map(Double.init), count: height)
            let reach = Swift.max(1, width / Swift.max(1, width - target))
            for _ in 0..<(width - target) {
                let seam = cheapestSeam(e, width: w, height: height)
                var next = [Float](repeating: 0, count: (w - 1) * height)
                for y in 0..<height {
                    let s = seam[y]
                    for x in 0..<(w - 1) { next[y * (w - 1) + x] = e[y * w + (x < s ? x : x + 1)] }
                    index[y].remove(at: s)
                    spread(&next, width: w - 1, row: y, at: s, reach: reach)
                }
                e = next
                w -= 1
            }
            return (index, e)
        }
        // Wider: find the seams a narrowing would take first, then double them (at most every column once).
        let extra = Swift.min(target - width, width)
        var e = energy, w = width
        var index = Array(repeating: (0..<width).map { $0 }, count: height)
        var doubled = Array(repeating: Set<Int>(), count: height)
        let reach = Swift.max(1, width / Swift.max(1, extra))
        for _ in 0..<extra {
            let seam = cheapestSeam(e, width: w, height: height)
            var next = [Float](repeating: 0, count: (w - 1) * height)
            for y in 0..<height {
                let s = seam[y]
                doubled[y].insert(index[y][s])
                for x in 0..<(w - 1) { next[y * (w - 1) + x] = e[y * w + (x < s ? x : x + 1)] }
                index[y].remove(at: s)
                spread(&next, width: w - 1, row: y, at: s, reach: reach)
            }
            e = next
            w -= 1
        }
        var columns: [[Double]] = []
        var carved = [Float](repeating: 0, count: (width + extra) * height)
        for y in 0..<height {
            var row: [Double] = []
            for x in 0..<width {
                row.append(Double(x))
                if doubled[y].contains(x) { row.append(Double(x)) }
            }
            for (i, x) in row.enumerated() { carved[y * (width + extra) + i] = energy[y * width + Int(x)] }
            columns.append(row)
        }
        if width + extra < target {
            // More than doubling: stretch the rest evenly.
            columns = columns.map { row in (0..<target).map { row[Swift.min(row.count - 1, $0 * row.count / target)] } }
            var stretched = [Float](repeating: 0, count: target * height)
            for y in 0..<height { for x in 0..<target { stretched[y * target + x] = energy[y * width + Int(columns[y][x])] } }
            carved = stretched
        }
        return (columns, carved)
    }

    /// After a seam was taken out at column `s` of a row: the columns within `reach` of it cost a little
    /// more, so later seams spread evenly over a plain area instead of piling up on one side (the
    /// subject stays put). `reach` is about the room each seam has.
    static func spread(_ e: inout [Float], width: Int, row: Int, at s: Int, reach: Int) {
        for x in Swift.max(0, s - reach)..<Swift.min(width, s + reach) { e[row * width + x] += 0.02 }
    }

    /// The top-to-bottom path (one column per row, moving at most one column between rows) with the
    /// least total energy.
    static func cheapestSeam(_ e: [Float], width: Int, height: Int) -> [Int] {
        var cost = e
        var from = [Int](repeating: 0, count: width * height)
        for y in 1..<height {
            for x in 0..<width {
                var best = x, bestCost = cost[(y - 1) * width + x]
                if x > 0, cost[(y - 1) * width + x - 1] < bestCost { best = x - 1; bestCost = cost[(y - 1) * width + x - 1] }
                if x < width - 1, cost[(y - 1) * width + x + 1] < bestCost { best = x + 1; bestCost = cost[(y - 1) * width + x + 1] }
                cost[y * width + x] += bestCost
                from[y * width + x] = best
            }
        }
        var x = 0
        for c in 1..<width where cost[(height - 1) * width + c] < cost[(height - 1) * width + x] { x = c }
        var seam = [Int](repeating: 0, count: height)
        for y in stride(from: height - 1, through: 0, by: -1) {
            seam[y] = x
            if y > 0 { x = from[y * width + x] }
        }
        return seam
    }

    static func transpose(_ a: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { out[x * height + y] = a[y * width + x] } }
        return out
    }

    /// A light 3 × 3 average of how far each cell reads from a plain stretch, so cut lines don't zigzag.
    static func smooth(_ map: inout WarpMap) {
        let d = map.displacements
        let w = map.width, h = map.height
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<2 {
                    var sum: Float = 0
                    var n: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let xx = x + dx, yy = y + dy
                            guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                            sum += d[(yy * w + xx) * 2 + c]
                            n += 1
                        }
                    }
                    let plain = c == 0 ? (Double(x) + 0.5) / Double(w) : (Double(y) + 0.5) / Double(h)
                    map.positions[(y * w + x) * 2 + c] = Float(plain) + sum / n
                }
            }
        }
    }
}
