import Foundation

/// Content-aware fill without AI, for the Remove brush: the hole is made up from patches of the rest of
/// the picture. Multi-scale PatchMatch (Barnes et al. 2009) with Wexler-style voting (2007): on a
/// pyramid from small to full size, every 7 × 7 patch touching the hole finds the most similar whole
/// patch outside it, and each hole pixel becomes the weighted average of what those patches say it
/// should be. Small pictures (the box around a stroke), deterministic (fixed random seed).
enum Inpaint {
    /// Patches are (2r + 1)² pixels.
    static let r = 3

    /// `image` with the pixels where `hole` is true made up from the rest of it.
    static func fill(_ image: RGBBuffer, hole: [Bool], seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> RGBBuffer {
        guard hole.count == image.width * image.height, hole.contains(true) else { return image }
        guard hole.contains(false) else { return image }
        var random = Random(seed: seed)

        // Pyramid: each level half the size; a coarse pixel is part of the hole when any of its four is.
        var levels: [Level] = [Level(image: image, hole: hole)]
        while let top = levels.last, top.holeSpan > 8, Swift.min(top.image.width, top.image.height) >= 2 * (4 * r + 2) {
            let next = top.halved()
            if next.validCount < 16 { break }
            levels.append(next)
        }

        // The coarsest level starts from a smooth fill (the edge colours spread inwards).
        var current = levels[levels.count - 1].image
        diffuse(&current, hole: levels[levels.count - 1].hole)
        var nnf: [Int32] = []
        for index in stride(from: levels.count - 1, through: 0, by: -1) {
            let level = levels[index]
            if index != levels.count - 1 {
                current = level.upsampled(current, from: levels[index + 1])
                nnf = level.upsampledField(nnf, from: levels[index + 1], random: &random)
            } else {
                nnf = level.randomField(random: &random)
            }
            guard level.validCount > 0 else { continue }
            // Fewer rounds on big levels (the large-hole case stays quick); more at the coarse ones.
            let rounds = level.targets.count > 120_000 ? 1 : index == 0 ? 3 : index == levels.count - 1 ? 8 : 5
            var distance = level.distances(current, nnf)
            for round in 0..<rounds {
                level.search(current, &nnf, &distance, forward: round % 2 == 0, random: &random)
                level.search(current, &nnf, &distance, forward: round % 2 != 0, random: &random)
                level.vote(&current, nnf, distance)
                if round + 1 < rounds { distance = level.distances(current, nnf) }
            }
        }
        return current
    }

    /// Fills the hole from its edge inwards, each ring the average of its filled neighbours, then
    /// smooths it a little.
    static func diffuse(_ image: inout RGBBuffer, hole: [Bool]) {
        let w = image.width, h = image.height
        var filled = hole.map { !$0 }
        var todo = (0..<(w * h)).filter { hole[$0] }
        while !todo.isEmpty {
            var next: [Int] = []
            var ring: [(Int, Float, Float, Float)] = []
            for i in todo {
                let x = i % w, y = i / w
                var sum: (Float, Float, Float) = (0, 0, 0)
                var n: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h, filled[ny * w + nx] else { continue }
                        let j = 3 * (ny * w + nx)
                        sum = (sum.0 + image.pixels[j], sum.1 + image.pixels[j + 1], sum.2 + image.pixels[j + 2])
                        n += 1
                    }
                }
                if n > 0 { ring.append((i, sum.0 / n, sum.1 / n, sum.2 / n)) } else { next.append(i) }
            }
            if ring.isEmpty { break }
            for (i, r, g, b) in ring {
                image.pixels[3 * i] = r
                image.pixels[3 * i + 1] = g
                image.pixels[3 * i + 2] = b
                filled[i] = true
            }
            todo = next
        }
    }

    /// A small fast random number generator (xorshift64*), seeded so fills come out the same every time.
    struct Random {
        var state: UInt64

        init(seed: UInt64) { state = seed == 0 ? 1 : seed }

        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }

        /// A whole number in -n...n.
        mutating func offset(_ n: Int) -> Int {
            Int(next() % UInt64(2 * n + 1)) - n
        }

        mutating func below(_ n: Int) -> Int {
            Int(next() % UInt64(Swift.max(1, n)))
        }
    }

    /// One size of the picture: its pixels, its hole, the patches that touch the hole (targets) and
    /// the patch centres that may be copied from (whole patch inside the picture, none of it in the hole).
    struct Level {
        let image: RGBBuffer
        let hole: [Bool]
        let targets: [Int32]
        let valid: [Bool]
        let validList: [Int32]
        /// The hole's bounding box, largest side.
        let holeSpan: Int

        var validCount: Int { validList.count }
        var width: Int { image.width }
        var height: Int { image.height }

        init(image: RGBBuffer, hole: [Bool]) {
            self.image = image
            self.hole = hole
            let w = image.width, h = image.height
            // Hole pixels within r of each pixel (summed-area table).
            var table = [Int32](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row: Int32 = 0
                for x in 0..<w {
                    row += hole[y * w + x] ? 1 : 0
                    table[(y + 1) * (w + 1) + x + 1] = table[y * (w + 1) + x + 1] + row
                }
            }
            func near(_ x: Int, _ y: Int) -> Int32 {
                let x0 = Swift.max(0, x - Inpaint.r), x1 = Swift.min(w, x + Inpaint.r + 1)
                let y0 = Swift.max(0, y - Inpaint.r), y1 = Swift.min(h, y + Inpaint.r + 1)
                return table[y1 * (w + 1) + x1] - table[y0 * (w + 1) + x1] - table[y1 * (w + 1) + x0] + table[y0 * (w + 1) + x0]
            }
            var targets: [Int32] = []
            var valid = [Bool](repeating: false, count: w * h)
            var validList: [Int32] = []
            var box = (x0: w, y0: h, x1: -1, y1: -1)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    if hole[i] { box = (Swift.min(box.x0, x), Swift.min(box.y0, y), Swift.max(box.x1, x), Swift.max(box.y1, y)) }
                    let count = near(x, y)
                    if count > 0 { targets.append(Int32(i)) }
                    if count == 0, x >= Inpaint.r, y >= Inpaint.r, x < w - Inpaint.r, y < h - Inpaint.r {
                        valid[i] = true
                        validList.append(Int32(i))
                    }
                }
            }
            self.targets = targets
            self.valid = valid
            self.validList = validList
            self.holeSpan = box.x1 < 0 ? 0 : Swift.max(box.x1 - box.x0 + 1, box.y1 - box.y0 + 1)
        }

        /// Half the size: each pixel the average of its four (of the known ones where some are in the hole).
        func halved() -> Level {
            let w = width, h = height
            let hw = (w + 1) / 2, hh = (h + 1) / 2
            var pixels = [Float](repeating: 0, count: hw * hh * 3)
            var small = [Bool](repeating: false, count: hw * hh)
            for y in 0..<hh {
                for x in 0..<hw {
                    var sum: (Float, Float, Float) = (0, 0, 0)
                    var all: (Float, Float, Float) = (0, 0, 0)
                    var n: Float = 0, m: Float = 0
                    var inHole = false
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let sx = Swift.min(w - 1, 2 * x + dx), sy = Swift.min(h - 1, 2 * y + dy)
                        let i = sy * w + sx
                        let c = (image.pixels[3 * i], image.pixels[3 * i + 1], image.pixels[3 * i + 2])
                        all = (all.0 + c.0, all.1 + c.1, all.2 + c.2)
                        m += 1
                        if hole[i] {
                            inHole = true
                        } else {
                            sum = (sum.0 + c.0, sum.1 + c.1, sum.2 + c.2)
                            n += 1
                        }
                    }
                    let o = 3 * (y * hw + x)
                    let pick = n > 0 ? (sum.0 / n, sum.1 / n, sum.2 / n) : (all.0 / m, all.1 / m, all.2 / m)
                    pixels[o] = pick.0
                    pixels[o + 1] = pick.1
                    pixels[o + 2] = pick.2
                    small[y * hw + x] = inHole
                }
            }
            return Level(image: RGBBuffer(width: hw, height: hh, pixels: pixels), hole: small)
        }

        /// This level's picture with its hole taken from the (filled) coarser picture, smoothly enlarged.
        func upsampled(_ coarse: RGBBuffer, from: Level) -> RGBBuffer {
            var out = image
            let w = width
            for i in 0..<(width * height) where hole[i] {
                let x = Double(i % w), y = Double(i / w)
                let c = coarse.bilinear(x: (x + 0.5) / 2 - 0.5, y: (y + 0.5) / 2 - 0.5)
                out.pixels[3 * i] = c.0
                out.pixels[3 * i + 1] = c.1
                out.pixels[3 * i + 2] = c.2
            }
            return out
        }

        /// A random valid source for every target (−1 elsewhere).
        func randomField(random: inout Random) -> [Int32] {
            var nnf = [Int32](repeating: -1, count: width * height)
            guard !validList.isEmpty else { return nnf }
            for t in targets { nnf[Int(t)] = validList[random.below(validList.count)] }
            return nnf
        }

        /// The coarser level's matches, twice as far, for this level's targets.
        func upsampledField(_ coarse: [Int32], from: Level, random: inout Random) -> [Int32] {
            var nnf = [Int32](repeating: -1, count: width * height)
            guard !validList.isEmpty else { return nnf }
            let w = width, cw = from.width, ch = from.height
            for t in targets {
                let x = Int(t) % w, y = Int(t) / w
                let q = Swift.min(ch - 1, y / 2) * cw + Swift.min(cw - 1, x / 2)
                var pick: Int32 = -1
                if q < coarse.count, coarse[q] >= 0 {
                    let s = Int(coarse[q])
                    let sx = 2 * (s % cw) + x % 2, sy = 2 * (s / cw) + y % 2
                    if sx < width, sy < height, valid[sy * w + sx] { pick = Int32(sy * w + sx) }
                }
                nnf[Int(t)] = pick >= 0 ? pick : validList[random.below(validList.count)]
            }
            return nnf
        }

        /// Mean squared colour difference between the patch around `p` (pixels inside the picture) and
        /// the one around `s`; stops early once it is worse than `limit`.
        @inline(__always)
        func distance(_ p: Int, _ s: Int, _ cur: UnsafeBufferPointer<Float>, limit: Float) -> Float {
            let w = width, h = height, r = Inpaint.r
            let px = p % w, py = p / w, sx = s % w, sy = s / w
            var sum: Float = 0
            var n: Float = 0
            for dy in -r...r {
                let ty = py + dy
                if ty < 0 || ty >= h { continue }
                let rowT = ty * w, rowS = (sy + dy) * w
                for dx in -r...r {
                    let tx = px + dx
                    if tx < 0 || tx >= w { continue }
                    let a = 3 * (rowT + tx), b = 3 * (rowS + sx + dx)
                    let d0 = cur[a] - cur[b], d1 = cur[a + 1] - cur[b + 1], d2 = cur[a + 2] - cur[b + 2]
                    sum += d0 * d0 + d1 * d1 + d2 * d2
                    n += 1
                }
                if sum > limit * Float((2 * r + 1) * (2 * r + 1)) { return .infinity }
            }
            return n > 0 ? sum / n : .infinity
        }

        /// Every target's distance to its current match.
        func distances(_ current: RGBBuffer, _ nnf: [Int32]) -> [Float] {
            var out = [Float](repeating: .infinity, count: width * height)
            current.pixels.withUnsafeBufferPointer { cur in
                for t in targets where nnf[Int(t)] >= 0 {
                    out[Int(t)] = distance(Int(t), Int(nnf[Int(t)]), cur, limit: .infinity)
                }
            }
            return out
        }

        /// One PatchMatch pass: each target tries its neighbours' matches, shifted (propagation), then
        /// random spots around its own at shrinking distances (random search).
        func search(_ current: RGBBuffer, _ nnf: inout [Int32], _ distance: inout [Float], forward: Bool, random: inout Random) {
            guard !validList.isEmpty else { return }
            let w = width, h = height, r = Inpaint.r
            let step = forward ? 1 : -1
            let order = forward ? Array(targets) : Array(targets.reversed())
            current.pixels.withUnsafeBufferPointer { cur in
                for t in order {
                    let p = Int(t)
                    var best = Int(nnf[p])
                    var bestD = distance[p]
                    func attempt(_ s: Int) {
                        guard s >= 0, s < w * h, valid[s], s != best else { return }
                        let d = self.distance(p, s, cur, limit: bestD)
                        if d < bestD {
                            bestD = d
                            best = s
                        }
                    }
                    let px = p % w, py = p / w
                    // Propagation: the match of the neighbour before this one, moved along by one.
                    if px - step >= 0, px - step < w, nnf[p - step] >= 0 {
                        let s = Int(nnf[p - step]) + step
                        if (s % w) == (Int(nnf[p - step]) % w) + step { attempt(s) }
                    }
                    if py - step >= 0, py - step < h, nnf[p - step * w] >= 0 {
                        attempt(Int(nnf[p - step * w]) + step * w)
                    }
                    // Random search around the best so far.
                    var reach = Swift.max(w, h)
                    while reach >= 1 {
                        let bx = best % w, by = best / w
                        let x = Swift.min(w - 1 - r, Swift.max(r, bx + random.offset(reach)))
                        let y = Swift.min(h - 1 - r, Swift.max(r, by + random.offset(reach)))
                        attempt(y * w + x)
                        reach /= 2
                    }
                    nnf[p] = Int32(best)
                    distance[p] = bestD
                }
            }
        }

        /// Each hole pixel becomes the average of what the patches over it say, closer matches counting more.
        func vote(_ current: inout RGBBuffer, _ nnf: [Int32], _ distance: [Float]) {
            let w = width, h = height, r = Inpaint.r
            let known = targets.compactMap { t -> Float? in
                let d = distance[Int(t)]
                return d.isFinite ? d : nil
            }.sorted()
            guard !known.isEmpty else { return }
            let sigma2 = Swift.max(1e-6, known[Swift.min(known.count - 1, known.count * 3 / 4)])
            var sum = [Float](repeating: 0, count: w * h * 3)
            var weight = [Float](repeating: 0, count: w * h)
            current.pixels.withUnsafeBufferPointer { cur in
                for t in targets {
                    let p = Int(t), s = Int(nnf[p])
                    guard s >= 0, distance[p].isFinite else { continue }
                    let k = expf(-distance[p] / (2 * sigma2))
                    let px = p % w, py = p / w, sx = s % w, sy = s / w
                    for dy in -r...r {
                        let ty = py + dy
                        if ty < 0 || ty >= h { continue }
                        for dx in -r...r {
                            let tx = px + dx
                            if tx < 0 || tx >= w { continue }
                            let q = ty * w + tx
                            guard hole[q] else { continue }
                            let b = 3 * ((sy + dy) * w + sx + dx)
                            sum[3 * q] += k * cur[b]
                            sum[3 * q + 1] += k * cur[b + 1]
                            sum[3 * q + 2] += k * cur[b + 2]
                            weight[q] += k
                        }
                    }
                }
            }
            for q in 0..<(w * h) where hole[q] && weight[q] > 0 {
                current.pixels[3 * q] = sum[3 * q] / weight[q]
                current.pixels[3 * q + 1] = sum[3 * q + 1] / weight[q]
                current.pixels[3 * q + 2] = sum[3 * q + 2] / weight[q]
            }
        }
    }
}
