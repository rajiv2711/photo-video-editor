import Foundation

/// Heal and the source spot of the copying tools. Heal copies the texture of a source spot and
/// matches it to the colours around the destination: a smooth "membrane" (the harmonic function that
/// meets the difference between destination and source along the spot's edge, as in Poisson
/// blending, Pérez et al. 2003) is added to the copied pixels, so no seam shows.
enum Healing {
    /// A source spot for a step whose source was not chosen: the nearby place (in 24 directions, a
    /// few brush widths away) whose surroundings look most like the destination's (its ring of
    /// pixels around the spot), not overlapping the spot, not busier than the surroundings.
    /// `brightness`: whether a brightness difference counts (clone) or not (heal fixes it).
    /// Returns the offset in pixels (source = destination + offset), or nil when nothing fits.
    static func pickSource(hole: [Bool], box: PixelBox, image: RGBBuffer, diameter: Double, brightness: Bool) -> (dx: Int, dy: Int)? {
        let w = box.width, h = box.height
        guard w > 0, h > 0, hole.count == w * h else { return nil }
        // The ring: pixels near the hole (within a third of the brush), but not in it.
        let reach = Swift.max(2, Int(diameter / 6))
        var ring: [(x: Int, y: Int)] = []
        var inner: [(x: Int, y: Int)] = []
        let near = Healing.dilate(hole, width: w, height: h, radius: reach)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if hole[i] { inner.append((box.x0 + x, box.y0 + y)) } else if near[i] { ring.append((box.x0 + x, box.y0 + y)) }
            }
        }
        guard !ring.isEmpty, !inner.isEmpty else { return nil }
        // At most a few hundred samples of each (spread evenly), so long strokes stay quick.
        func thin(_ list: [(x: Int, y: Int)], _ count: Int) -> [(x: Int, y: Int)] {
            list.count <= count ? list : (0..<count).map { list[$0 * list.count / count] }
        }
        let ringSamples = thin(ring, 400), innerSamples = thin(inner, 400)
        let holeSet = Set(inner.map { $0.y * image.width + $0.x })
        // How busy the destination's surroundings are (variance of brightness on the ring).
        func luma(_ c: (Float, Float, Float)) -> Float { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }
        func variance(_ values: [Float]) -> Float {
            let mean = values.reduce(0, +) / Float(values.count)
            return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        }
        let ringBusy = variance(ringSamples.map { luma(image.color($0.x, $0.y)) })

        let step = Swift.max(diameter, 4)
        var best: (cost: Float, dx: Int, dy: Int)?
        for factor in [1.1, 1.4, 1.8, 2.3, 3.0, 4.0] {
            for k in 0..<24 {
                let angle = Double(k) * Double.pi / 12
                let dx = Int((cos(angle) * step * factor).rounded()), dy = Int((sin(angle) * step * factor).rounded())
                // The whole source box inside the picture, and none of the source on the spot itself.
                guard box.x0 + dx - reach >= 0, box.y0 + dy - reach >= 0,
                      box.x1 + dx + reach <= image.width, box.y1 + dy + reach <= image.height else { continue }
                if innerSamples.contains(where: { holeSet.contains(($0.y + dy) * image.width + $0.x + dx) }) { continue }
                // Surroundings alike (brightness difference removed for heal), source no busier than them.
                var diffs: [(Float, Float, Float)] = []
                diffs.reserveCapacity(ringSamples.count)
                for p in ringSamples {
                    let a = image.color(p.x, p.y), b = image.color(p.x + dx, p.y + dy)
                    diffs.append((a.0 - b.0, a.1 - b.1, a.2 - b.2))
                }
                var mean: (Float, Float, Float) = (0, 0, 0)
                if !brightness {
                    for d in diffs { mean = (mean.0 + d.0, mean.1 + d.1, mean.2 + d.2) }
                    let n = Float(diffs.count)
                    mean = (mean.0 / n, mean.1 / n, mean.2 / n)
                }
                var cost: Float = 0
                for d in diffs {
                    let e = (d.0 - mean.0, d.1 - mean.1, d.2 - mean.2)
                    cost += e.0 * e.0 + e.1 * e.1 + e.2 * e.2
                }
                cost /= Float(diffs.count)
                let sourceBusy = variance(innerSamples.map { luma(image.color($0.x + dx, $0.y + dy)) })
                cost += 3 * Swift.max(0, sourceBusy - ringBusy)
                cost *= Float(1 + 0.04 * factor)
                if best == nil || cost < best!.cost { best = (cost, dx, dy) }
            }
        }
        return best.map { ($0.dx, $0.dy) }
    }

    /// Cells within `radius` (a square) of a true cell.
    static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var table = [Int32](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row: Int32 = 0
            for x in 0..<width {
                row += mask[y * width + x] ? 1 : 0
                table[(y + 1) * (width + 1) + x + 1] = table[y * (width + 1) + x + 1] + row
            }
        }
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                let x0 = Swift.max(0, x - radius), x1 = Swift.min(width, x + radius + 1)
                let y0 = Swift.max(0, y - radius), y1 = Swift.min(height, y + radius + 1)
                let n = table[y1 * (width + 1) + x1] - table[y0 * (width + 1) + x1] - table[y1 * (width + 1) + x0] + table[y0 * (width + 1) + x0]
                out[y * width + x] = n > 0
            }
        }
        return out
    }

    /// Inside the hole, the smooth surface that meets `edge` (3 numbers per pixel) on the pixels
    /// around it: the solution of Laplace's equation, found by spreading the edge values inwards over
    /// a pyramid (pull-push) and then relaxing (over-relaxed Gauss-Seidel). Outside the hole, `edge`.
    static func membrane(_ edge: [Float], hole: [Bool], width w: Int, height h: Int, iterations: Int = 80) -> [Float] {
        var out = edge
        guard hole.contains(true) else { return out }
        // The known pixels next to the hole are the edge; the rest of the box doesn't count.
        let rim = dilate(hole, width: w, height: h, radius: 1).enumerated().map { $0.element && !hole[$0.offset] }

        // Pull: averages of the rim over ever coarser cells; push: fill each level from the coarser one.
        var levels: [(w: Int, h: Int, v: [Float], k: [Float])] = []
        var k = rim.map { $0 ? Float(1) : 0 }
        var v = (0..<(w * h * 3)).map { rim[$0 / 3] ? edge[$0] : 0 }
        var lw = w, lh = h
        levels.append((lw, lh, v, k))
        while lw > 1 || lh > 1 {
            let nw = (lw + 1) / 2, nh = (lh + 1) / 2
            var nv = [Float](repeating: 0, count: nw * nh * 3), nk = [Float](repeating: 0, count: nw * nh)
            for y in 0..<nh {
                for x in 0..<nw {
                    var sum: (Float, Float, Float) = (0, 0, 0)
                    var weight: Float = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let sx = 2 * x + dx, sy = 2 * y + dy
                        guard sx < lw, sy < lh else { continue }
                        let i = sy * lw + sx, c = k[i]
                        sum = (sum.0 + c * v[3 * i], sum.1 + c * v[3 * i + 1], sum.2 + c * v[3 * i + 2])
                        weight += c
                    }
                    let o = y * nw + x
                    if weight > 0 {
                        nv[3 * o] = sum.0 / weight
                        nv[3 * o + 1] = sum.1 / weight
                        nv[3 * o + 2] = sum.2 / weight
                    }
                    nk[o] = Swift.min(1, weight)
                }
            }
            lw = nw
            lh = nh
            v = nv
            k = nk
            levels.append((lw, lh, v, k))
        }
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[l + 1]
            var level = levels[l]
            for y in 0..<level.h {
                for x in 0..<level.w {
                    let i = y * level.w + x, c = level.k[i]
                    guard c < 1 else { continue }
                    let p = Swift.min(coarse.h - 1, y / 2) * coarse.w + Swift.min(coarse.w - 1, x / 2)
                    for ch in 0..<3 { level.v[3 * i + ch] = c * level.v[3 * i + ch] + (1 - c) * coarse.v[3 * p + ch] }
                    level.k[i] = 1
                }
            }
            levels[l] = level
        }
        for i in 0..<(w * h) where hole[i] {
            for ch in 0..<3 { out[3 * i + ch] = levels[0].v[3 * i + ch] }
        }

        // Relax towards the exact solution: each hole pixel the average of its four neighbours.
        let holes = (0..<(w * h)).filter { hole[$0] }
        let omega: Float = 1.8
        for _ in 0..<iterations {
            for i in holes {
                let x = i % w, y = i / w
                var sum: (Float, Float, Float) = (0, 0, 0)
                var n: Float = 0
                for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1] where j >= 0 {
                    sum = (sum.0 + out[3 * j], sum.1 + out[3 * j + 1], sum.2 + out[3 * j + 2])
                    n += 1
                }
                guard n > 0 else { continue }
                out[3 * i] += omega * (sum.0 / n - out[3 * i])
                out[3 * i + 1] += omega * (sum.1 / n - out[3 * i + 1])
                out[3 * i + 2] += omega * (sum.2 / n - out[3 * i + 2])
            }
        }
        return out
    }
}
