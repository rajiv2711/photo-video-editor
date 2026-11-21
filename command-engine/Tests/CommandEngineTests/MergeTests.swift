import XCTest
@testable import CommandEngine

/// The Merge panel: names, what merge actions do to the edit, and the maths on small made-up
/// pictures (a scene with a wide brightness range seen through brackets, shifted copies, …).
final class MergeTests: XCTestCase {
    private var registry: ControlRegistry!
    private var parser: CommandParser!
    private var interpreter: CommandInterpreter!
    private var state: EditState!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        parser = CommandParser(registry: registry)
        interpreter = CommandInterpreter(registry: registry)
        state = EditState()
    }

    @discardableResult
    private func run(_ text: String) -> [CommandOutcome] {
        interpreter.interpret(text, state: &state)
    }

    private func value(_ id: String) -> Double {
        state.value(of: registry.control(id: id)!)
    }

    // MARK: - Pictures

    /// A cheap repeatable pseudo-random number in 0…1 for a cell.
    static func hash(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Float((h ^ (h >> 16)) & 0xFFFF) / 65535
    }

    /// Linear brightness of a scene: a left-to-right ramp from deep shadow to 3 × white, with 5-pixel
    /// cells of random texture on it (so lining up has something to hold on to).
    static func scene(_ x: Int, _ y: Int, width: Int) -> Float {
        let ramp = 0.02 + 2.98 * Float(x) / Float(width - 1)
        let texture = 0.6 + 0.4 * hash(x / 5, y / 5)
        return ramp * texture
    }

    /// The scene seen at `exposure` (× linear light), clipped at white, on sRGB levels; optionally
    /// moved by `shift` and with a square `object` of sRGB level `objectLevel` painted over it.
    static func bracket(_ exposure: Float, width: Int = 96, height: Int = 64, shift: Align.Shift = .zero,
                        object: (x: Int, y: Int, size: Int)? = nil, objectLevel: Float = 0.6) -> FloatImage {
        var image = FloatImage(width: width, height: height, channels: 3)
        for y in 0..<height {
            for x in 0..<width {
                let sx = min(max(x - shift.dx, 0), width - 1), sy = min(max(y - shift.dy, 0), height - 1)
                let linear = scene(sx, sy, width: width) * exposure
                // A slight colour, so saturation has something to measure.
                let rgb = [linear * 1.05, linear, linear * 0.9].map { SRGB.encoded(min(1, $0)) }
                for c in 0..<3 { image[x, y, c] = rgb[c] }
                if let o = object, x >= o.x, x < o.x + o.size, y >= o.y, y < o.y + o.size {
                    for c in 0..<3 { image[x, y, c] = objectLevel }
                }
            }
        }
        return image
    }

    /// Mean absolute difference of two pictures inside a box (all channels).
    static func difference(_ a: FloatImage, _ b: FloatImage, x0: Int, y0: Int, x1: Int, y1: Int) -> Float {
        var sum: Float = 0, n: Float = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                for c in 0..<a.channels {
                    sum += abs(a[x, y, c] - b[x, y, c])
                    n += 1
                }
            }
        }
        return sum / max(n, 1)
    }

    /// Standard deviation of the green channel inside a box (detail left there).
    static func spread(_ a: FloatImage, x0: Int, y0: Int, x1: Int, y1: Int) -> Float {
        var values: [Float] = []
        for y in y0..<y1 { for x in x0..<x1 { values.append(a[x, y, 1]) } }
        let mean = values.reduce(0, +) / Float(values.count)
        return sqrtf(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count))
    }

    // MARK: - Names and the edit

    func testMergeNamesParse() {
        XCTAssertEqual(parser.parse("hdr merge"), [.run("hdrMerge")])
        XCTAssertEqual(parser.parse("hdr merge 3"), [.run("hdrMerge", value: 3)])
        XCTAssertEqual(parser.parse("hdr on"), [.set("hdr", 1)], "the HDR switch keeps its name")
        XCTAssertEqual(parser.parse("deghost medium"), [.set("deghost", 2)])
        XCTAssertEqual(parser.parse("hdr output radiance"), [.set("hdrOutput", 1)])
        XCTAssertEqual(parser.parse("photos to merge 3"), [.set("mergeCount", 3)])
    }

    func testMergeActionsNeedTheirExactName() {
        // A near-miss must never start a merge.
        XCTAssertNotEqual(parser.parse("hdr merg"), [.run("hdrMerge")])
        if case .found(let c) = NameMatcher(registry: registry).match("hdrmerge") { XCTAssertNotEqual(c.id, "hdrMerge") }
    }

    func testMergeActionRunsAndANumberSaysHowManyPhotos() {
        XCTAssertEqual(run("hdr merge"), [.ran(controlID: "hdrMerge")])
        XCTAssertEqual(run("hdr merge 3"), [.ran(controlID: "hdrMerge"), .changed(controlID: "mergeCount", from: 0, to: 3)])
        XCTAssertEqual(value("mergeCount"), 3)
        XCTAssertEqual(MergeTools.chosen([1, 2, 3, 4, 5], count: 3), [3, 4, 5])
        XCTAssertEqual(MergeTools.chosen([1, 2, 3], count: 0), [1, 2, 3])
        XCTAssertEqual(MergeTools.chosen([1, 2, 3], count: 9), [1, 2, 3])
    }

    func testOptionIdsMatchControls() {
        XCTAssertEqual(registry.control(id: "deghost")!.options.map(\.id), HDRMerge.deghostLevels)
        XCTAssertEqual(registry.control(id: "hdrOutput")!.options.map(\.id), HDRMerge.outputs)
        XCTAssertEqual(registry.control(id: "panoramaProjection")!.options.map(\.id), Panorama.projections)
        for (id, _) in MergeTools.actions {
            XCTAssertEqual(registry.control(id: id)?.group, "merge", id)
            for setting in MergeTools.settings(for: MergeTools.actions[id]!) { XCTAssertNotNil(registry.control(id: setting), setting) }
        }
    }

    // MARK: - Pyramids

    func testLaplacianPyramidGivesThePictureBack() {
        let image = Self.bracket(1, width: 37, height: 23)
        let bands = Pyramid.laplacian(image, levels: Pyramid.levels(width: 37, height: 23))
        XCTAssertGreaterThan(bands.count, 1)
        let back = Pyramid.collapse(bands)
        XCTAssertEqual(back.width, 37)
        XCTAssertLessThan(Self.difference(back, image, x0: 0, y0: 0, x1: 37, y1: 23), 1e-5)
    }

    func testExpandKeepsAFlatPictureFlat() {
        let flat = FloatImage(width: 9, height: 5, channels: 1, value: 0.3)
        let big = Pyramid.expand(Pyramid.reduce(flat), width: 9, height: 5)
        XCTAssertTrue(big.data.allSatisfy { abs($0 - 0.3) < 1e-5 })
    }

    func testBlendWithOneSidedWeightsGivesThatPicture() {
        let a = Self.bracket(1, width: 40, height: 30), b = Self.bracket(0.25, width: 40, height: 30)
        let ones = [Float](repeating: 1, count: 1200), zeros = [Float](repeating: 0, count: 1200)
        let out = Pyramid.blend([a, b], weights: [ones, zeros])
        XCTAssertLessThan(Self.difference(out, a, x0: 0, y0: 0, x1: 40, y1: 30), 1e-4)
    }

    // MARK: - Lining up

    func testTranslationFindsTheShiftAcrossExposures() {
        // Over half of the middle bracket is clipped white: thresholds move off the median.
        let reference = Self.bracket(1, width: 192, height: 128).luma
        let moved = Self.bracket(0.4, width: 192, height: 128, shift: Align.Shift(4, -3)).luma
        XCTAssertEqual(Align.translation(reference: reference, image: moved), Align.Shift(-4, 3))
        let bright = Self.bracket(2, width: 192, height: 128, shift: Align.Shift(-5, 2)).luma
        XCTAssertEqual(Align.translation(reference: reference, image: bright), Align.Shift(5, -2))
        let brighter = Self.bracket(4, width: 192, height: 128, shift: Align.Shift(3, 3)).luma
        XCTAssertEqual(Align.translation(reference: reference, image: brighter), Align.Shift(-3, -3), "85 % clipped")
        let (back, valid) = Align.shifted(Self.bracket(1, shift: Align.Shift(4, -3)), by: Align.Shift(-4, 3))
        XCTAssertLessThan(Self.difference(back, Self.bracket(1), x0: 6, y0: 6, x1: 88, y1: 58), 1e-6)
        XCTAssertEqual(valid[30 * 96 + 50], 1)
        XCTAssertEqual(valid[30 * 96 + 95], 0, "the right edge came from outside")
    }

    // MARK: - HDR merge

    func testExposureRatiosAreMeasured() {
        let brackets = [Self.bracket(0.25), Self.bracket(1), Self.bracket(4)]
        let linear = brackets.map { $0.luma.map(SRGB.linear) }, encoded = brackets.map { $0.luma }
        let valid = [Float](repeating: 1, count: brackets[0].count)
        let low = HDRMerge.exposureRatio(linear[0], encoded[0], reference: linear[1], encoded[1], valid: valid)
        let high = HDRMerge.exposureRatio(linear[2], encoded[2], reference: linear[1], encoded[1], valid: valid)
        XCTAssertEqual(low, 0.25, accuracy: 0.03)
        XCTAssertEqual(high, 4, accuracy: 0.4)
    }

    func testRadianceRecoversHighlightsAboveWhite() {
        let width = 96
        let brackets = [Self.bracket(4), Self.bracket(0.25), Self.bracket(1)]  // any order
        let out = HDRMerge.merge(brackets, output: .radiance)
        // Where the scene is over 1.5 × white the middle bracket clipped; the merge knows the level.
        var checked = 0
        for y in stride(from: 0, to: 64, by: 7) {
            for x in stride(from: 0, to: width, by: 5) {
                let truth = Self.scene(x, y, width: width)
                guard truth > 1.5 || (truth < 0.3 && truth > 0.03) else { continue }
                XCTAssertEqual(out[x, y, 1], truth, accuracy: truth * 0.12, "at \(x), \(y)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 20)
        XCTAssertGreaterThan(out.data.max() ?? 0, 1.5, "levels above white survive")
    }

    func testFusionKeepsDetailInHighlightsAndShadows() {
        let dark = Self.bracket(0.25), mid = Self.bracket(1), bright = Self.bracket(4)
        let fused = HDRMerge.merge([dark, mid, bright])
        XCTAssertEqual(fused.width, 96)
        // The right third is clipped flat in the middle bracket; the fusion shows its texture.
        let clipped = (x0: 72, y0: 0, x1: 96, y1: 64)
        XCTAssertLessThan(Self.spread(mid, x0: clipped.x0, y0: clipped.y0, x1: clipped.x1, y1: clipped.y1), 0.03)
        XCTAssertGreaterThan(Self.spread(fused, x0: clipped.x0, y0: clipped.y0, x1: clipped.x1, y1: clipped.y1), 0.04)
        // The deep shadows on the left are brighter than in the dark bracket.
        let shadows = (x0: 0, y0: 0, x1: 12, y1: 64)
        XCTAssertGreaterThan(Self.difference(fused, dark, x0: shadows.x0, y0: shadows.y0, x1: shadows.x1, y1: shadows.y1), 0.05)
        XCTAssertTrue(fused.data.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testFusionLinesUpAShiftedBracket() {
        let clean = HDRMerge.merge([Self.bracket(0.25), Self.bracket(1), Self.bracket(4)])
        let shaky = HDRMerge.merge([Self.bracket(0.25, shift: Align.Shift(3, 2)), Self.bracket(1), Self.bracket(4, shift: Align.Shift(-2, 1))])
        XCTAssertLessThan(Self.difference(shaky, clean, x0: 8, y0: 8, x1: 88, y1: 56), 0.01)
    }

    func testDeghostLeavesOutWhatMovedInOneBracket() {
        // A pale object passes through the dark bracket only, where the middle one is well exposed.
        let object = (x: 4, y: 20, size: 14)
        let clean = HDRMerge.merge([Self.bracket(0.25), Self.bracket(1), Self.bracket(4)])
        let ghosted = [Self.bracket(0.25, object: object), Self.bracket(1), Self.bracket(4)]
        let off = HDRMerge.merge(ghosted, deghost: 0)
        let high = HDRMerge.merge(ghosted, deghost: 3)
        let box = (x0: object.x, y0: object.y, x1: object.x + object.size, y1: object.y + object.size)
        let ghostOff = Self.difference(off, clean, x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1)
        let ghostHigh = Self.difference(high, clean, x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1)
        XCTAssertGreaterThan(ghostOff, 0.04, "without deghosting the object shows")
        XCTAssertLessThan(ghostHigh, ghostOff / 3, "deghosting leaves it out")
    }
}

/// Panorama: matching, the stitch, projections, edges.
final class PanoramaTests: XCTestCase {
    /// A textured scene (smoothed random cells and a few soft blobs), RGB on sRGB levels.
    static func scene(width: Int, height: Int) -> FloatImage {
        var image = FloatImage(width: width, height: height, channels: 3)
        for y in 0..<height {
            for x in 0..<width {
                let cell = MergeTests.hash(x / 6, y / 6)
                let blob = 0.25 * sinf(Float(x) * 0.07) * cosf(Float(y) * 0.09)
                let v = 0.2 + 0.5 * cell + blob
                image[x, y, 0] = min(1, max(0, v * 1.1))
                image[x, y, 1] = min(1, max(0, v))
                image[x, y, 2] = min(1, max(0, v * 0.8 + 0.1))
            }
        }
        let blurred = (0..<3).map { c in
            Grid.blur((0..<(width * height)).map { image.data[$0 * 3 + c] }, width: width, height: height, radius: 1)
        }
        for i in 0..<(width * height) { for c in 0..<3 { image.data[i * 3 + c] = blurred[c][i] } }
        return image
    }

    /// The part of a picture from (x, y), `width` × `height`, its linear light × `gain`.
    static func crop(_ image: FloatImage, x: Int, y: Int, width: Int, height: Int, gain: Float = 1) -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: 3)
        for j in 0..<height {
            for i in 0..<width {
                for c in 0..<3 {
                    let v = image[min(image.width - 1, x + i), min(image.height - 1, y + j), c]
                    out[i, j, c] = gain == 1 ? v : SRGB.encoded(min(1, SRGB.linear(v) * gain))
                }
            }
        }
        return out
    }

    func testFeaturesFindTheShiftBetweenTwoCrops() {
        let scene = Self.scene(width: 260, height: 140)
        let a = Self.crop(scene, x: 0, y: 0, width: 160, height: 120).luma
        let b = Self.crop(scene, x: 70, y: 12, width: 160, height: 120).luma
        let ca = Features.corners(a), cb = Features.corners(b)
        XCTAssertGreaterThan(ca.count, 50)
        let matches = Features.match(Features.describe(a, ca), Features.describe(b, cb))
        XCTAssertGreaterThan(matches.count, 20)
        let from = matches.map { Vec2(cb[$0.1].x, cb[$0.1].y) }, to = matches.map { Vec2(ca[$0.0].x, ca[$0.0].y) }
        let found = Features.homography(from: from, to: to, size: (160, 120), threshold: 2)
        XCTAssertNotNil(found)
        // b's (0, 0) is a's (70, 12).
        let p = found!.h.apply(Vec2(0, 0))
        XCTAssertEqual(p.x, 70, accuracy: 0.7)
        XCTAssertEqual(p.y, 12, accuracy: 0.7)
    }

    func testFitRecoversAHomographyDespiteOutliers() {
        let truth = Homography([1.05, 0.03, 12, -0.02, 0.98, -7, 0.0002, -0.0001, 1])
        var from: [Vec2] = [], to: [Vec2] = []
        for k in 0..<80 {
            let p = Vec2(Double((k * 37) % 200), Double((k * 53) % 150))
            from.append(p)
            to.append(k % 5 == 0 ? Vec2(Double((k * 91) % 200), Double((k * 17) % 150)) : truth.apply(p))  // every fifth is wrong
        }
        let found = Features.homography(from: from, to: to, size: (200, 150), threshold: 1)
        XCTAssertNotNil(found)
        XCTAssertEqual(found!.inliers.count, 64)
        let q = found!.h.apply(Vec2(100, 75)), t = truth.apply(Vec2(100, 75))
        XCTAssertLessThan((q - t).length, 0.01)
    }

    func testFocalFromATurningCamera() {
        // H = K R K⁻¹ for a 20° turn about the upright axis, f = 500, centred coordinates.
        let f = 500.0, a = 20 * Double.pi / 180
        let k = Homography([f, 0, 0, 0, f, 0, 0, 0, 1])
        let r = Homography([cos(a), 0, sin(a), 0, 1, 0, -sin(a), 0, cos(a)])
        let h = (k * r * k.inverse).normalized
        XCTAssertEqual(Panorama.focal(from: h) ?? 0, f, accuracy: 5)
        XCTAssertNil(Panorama.focal(from: Homography.translation(40, 3)), "a sideways shift says nothing")
    }

    /// Three overlapping crops of a scene, a little higher or lower each, at different exposures.
    static func crops(_ scene: FloatImage) -> [FloatImage] {
        [crop(scene, x: 0, y: 6, width: 150, height: 110, gain: 0.85),
         crop(scene, x: 90, y: 0, width: 150, height: 110),
         crop(scene, x: 180, y: 10, width: 150, height: 110, gain: 1.15)]
    }

    func testPerspectivePanoramaRebuildsTheScene() {
        let scene = Self.scene(width: 330, height: 120)
        let photos = Self.crops(scene)
        let result = Panorama.stitch([photos[2], photos[0], photos[1]], settings: .init(projection: .perspective))  // any order
        XCTAssertNotNil(result)
        guard let r = result else { return }
        XCTAssertEqual(r.used, 3)
        XCTAssertEqual(Double(r.image.width), 330, accuracy: 3)
        XCTAssertEqual(Double(r.image.height), 120, accuracy: 3)
        // Covered pixels match the scene (the middle photo is the reference: its top is the scene's row 0).
        var diff: Float = 0, n: Float = 0
        for y in 12..<100 {
            for x in 10..<(min(r.image.width, 330) - 10) where r.coverage[y * r.image.width + x] > 0 {
                for c in 0..<3 { diff += abs(r.image[x, y, c] - scene[x, y, c]) }
                n += 3
            }
        }
        XCTAssertGreaterThan(n, 20000)
        XCTAssertLessThan(diff / n, 0.035, "seams and exposures hidden")
        // The top-left corner was never photographed (the left photo starts lower).
        XCTAssertEqual(r.coverage[2 * r.image.width + 2], 0)
    }

    func testCylindricalAndSphericalAreNarrower() {
        let photos = Self.crops(Self.scene(width: 330, height: 120))
        let flat = Panorama.stitch(photos, settings: .init(projection: .perspective))!
        let cylinder = Panorama.stitch(photos, settings: .init(projection: .cylindrical), focal: 150)!
        let sphere = Panorama.stitch(photos, settings: .init(projection: .spherical), focal: 150)!
        XCTAssertLessThan(cylinder.image.width, flat.image.width - 10)
        XCTAssertLessThan(sphere.image.height, cylinder.image.height)
    }

    func testBoundaryWarpAndFillEdgesFillTheFrame() {
        let photos = Self.crops(Self.scene(width: 330, height: 120))
        let plain = Panorama.stitch(photos, settings: .init(projection: .perspective))!
        let empty = plain.coverage.filter { $0 < 0.5 }.count
        XCTAssertGreaterThan(empty, 500)
        let warped = Panorama.stitch(photos, settings: .init(projection: .perspective, boundaryWarp: 1))!
        XCTAssertLessThan(warped.coverage.filter { $0 < 0.5 }.count, empty / 10)
        let filled = Panorama.stitch(photos, settings: .init(projection: .perspective, fillEdges: true))!
        XCTAssertTrue(filled.coverage.allSatisfy { $0 == 1 })
        // The made-up corner looks like the picture nearby, not black.
        XCTAssertGreaterThan(filled.image[2, 2, 1], 0.1)
    }

    func testUnrelatedPhotosAreNotJoined() {
        let a = Self.scene(width: 150, height: 110)
        var b = FloatImage(width: 150, height: 110, channels: 3)
        for y in 0..<110 { for x in 0..<150 { for c in 0..<3 { b[x, y, c] = MergeTests.hash(x / 4 + 999, y / 4 + 77) } } }
        XCTAssertNil(Panorama.stitch([a, b], settings: .init()))
    }
}

/// HDR panorama: telling the brackets apart, and the whole merge on a small scene.
final class HDRPanoramaTests: XCTestCase {
    func testBracketSizeFromTheExposurePattern() {
        XCTAssertEqual(HDRPanorama.bracketSize([0.05, 0.2, 0.8, 0.06, 0.22, 0.75]), 3)
        XCTAssertEqual(HDRPanorama.bracketSize([0.05, 0.2, 0.06, 0.25, 0.04, 0.18]), 2)
        XCTAssertEqual(HDRPanorama.bracketSize([0.05, 0.2, 0.8, 0.05, 0.2, 0.8, 0.06, 0.21, 0.7]), 3)
        XCTAssertNil(HDRPanorama.bracketSize([0.2, 0.21, 0.19, 0.2]), "no brackets: one exposure")
        XCTAssertNil(HDRPanorama.bracketSize([0.05, 0.2, 0.8]), "one position is not a panorama")
    }

    func testMergesEachPositionThenStitches() {
        // The bracket scene (shadows to 3 × white) made wider, seen from two overlapping positions.
        let width = 240, height = 100
        func shot(_ x0: Int, _ exposure: Float) -> FloatImage {
            let full = MergeTests.bracket(exposure, width: width, height: height)
            return PanoramaTests.crop(full, x: x0, y: 0, width: 150, height: height)
        }
        let photos = [shot(0, 0.25), shot(0, 1), shot(0, 4), shot(90, 0.25), shot(90, 1), shot(90, 4)]
        guard let (result, linear) = HDRPanorama.merge(photos, deghost: 0, output: .fusion, settings: .init(projection: .perspective)) else {
            return XCTFail("no panorama")
        }
        XCTAssertFalse(linear)
        XCTAssertEqual(Double(result.image.width), Double(width), accuracy: 3)
        // The bright right end, clipped flat in the middle brackets, keeps its texture.
        XCTAssertGreaterThan(MergeTests.spread(result.image, x0: 200, y0: 10, x1: 235, y1: 90), 0.04)
        guard let (radiance, isLinear) = HDRPanorama.merge(photos, deghost: 0, output: .radiance, settings: .init(projection: .perspective)) else {
            return XCTFail("no radiance panorama")
        }
        XCTAssertTrue(isLinear)
        XCTAssertGreaterThan(radiance.image.data.max() ?? 0, 1.5, "levels above white survive the stitch")
    }
}

/// Focus stacking and stack averaging on small made-up pictures.
final class StackTests: XCTestCase {
    /// The textured panorama scene, blurred (by about `radius` pixels) where `blurred` says so.
    static func slice(_ scene: FloatImage, radius: Int, blurred: (Int, Int) -> Bool) -> FloatImage {
        let w = scene.width, h = scene.height
        var soft = scene
        for c in 0..<3 {
            let channel = Grid.blur((0..<(w * h)).map { scene.data[$0 * 3 + c] }, width: w, height: h, radius: radius)
            for i in 0..<(w * h) { soft.data[i * 3 + c] = channel[i] }
        }
        var out = scene
        for y in 0..<h { for x in 0..<w where blurred(x, y) { for c in 0..<3 { out[x, y, c] = soft[x, y, c] } } }
        return out
    }

    /// Mean |Laplacian| of brightness in a box (fine detail left).
    static func detail(_ image: FloatImage, x0: Int, y0: Int, x1: Int, y1: Int) -> Float {
        let lap = Grid.laplacian(image.luma.data, width: image.width, height: image.height)
        var sum: Float = 0
        for y in y0..<y1 { for x in x0..<x1 { sum += lap[y * image.width + x] } }
        return sum / Float((x1 - x0) * (y1 - y0))
    }

    func testFocusStackIsSharpEverywhere() {
        let scene = PanoramaTests.scene(width: 160, height: 100)
        let near = Self.slice(scene, radius: 3) { x, _ in x >= 80 }   // sharp on the left
        let far = Self.slice(scene, radius: 3) { x, _ in x < 80 }     // sharp on the right
        let stacked = FocusStack.merge([near, far])
        for (x0, x1) in [(10, 70), (90, 150)] {
            let sharp = Self.detail(scene, x0: x0, y0: 10, x1: x1, y1: 90)
            XCTAssertGreaterThan(Self.detail(stacked, x0: x0, y0: 10, x1: x1, y1: 90), 0.85 * sharp, "\(x0)")
        }
        XCTAssertLessThan(MergeTests.difference(stacked, scene, x0: 10, y0: 10, x1: 150, y1: 90), 0.01)
    }

    func testFocusStackLinesUpShiftedSlices() {
        let scene = PanoramaTests.scene(width: 170, height: 110)
        let a = Self.slice(PanoramaTests.crop(scene, x: 0, y: 0, width: 160, height: 100), radius: 3) { x, _ in x >= 80 }
        let b = Self.slice(PanoramaTests.crop(scene, x: 4, y: 3, width: 160, height: 100), radius: 3) { x, _ in x < 80 }
        let stacked = FocusStack.merge([a, b])
        // b is the reference (the middle of two): both halves sharp in its frame.
        let reference = PanoramaTests.crop(scene, x: 4, y: 3, width: 160, height: 100)
        XCTAssertLessThan(MergeTests.difference(stacked, reference, x0: 10, y0: 10, x1: 150, y1: 90), 0.015)
    }
}

extension StackTests {
    /// The scene with noise (seeded per frame) and a dark square at a frame's own place.
    static func frame(_ scene: FloatImage, seed: Int, square x0: Int?) -> FloatImage {
        var out = scene
        for y in 0..<scene.height {
            for x in 0..<scene.width {
                for c in 0..<3 {
                    var v = scene[x, y, c] + 0.16 * (MergeTests.hash(x * 3 + c, y + 1000 * seed) - 0.5)
                    if let x0, x >= x0, x < x0 + 12, y >= 20, y < 32 { v = 0.05 }
                    out[x, y, c] = min(1, max(0, v))
                }
            }
        }
        return out
    }

    func testMedianRemovesWhatPassesAndMeanLowersNoise() {
        let scene = PanoramaTests.scene(width: 120, height: 80)
        let frames = [Self.frame(scene, seed: 1, square: 10), Self.frame(scene, seed: 2, square: 40),
                      Self.frame(scene, seed: 3, square: 70), Self.frame(scene, seed: 4, square: 95), Self.frame(scene, seed: 5, square: nil)]
        let median = Stack.merge(frames, mode: .median)
        let mean = Stack.merge(frames, mode: .mean)
        // The square that was in the first frame only is gone in the median.
        XCTAssertLessThan(MergeTests.difference(median, scene, x0: 10, y0: 20, x1: 22, y1: 32), 0.05)
        XCTAssertGreaterThan(MergeTests.difference(frames[0], scene, x0: 10, y0: 20, x1: 22, y1: 32), 0.2)
        // Noise: the mean is closer to the clean scene than any one frame.
        let noisy = MergeTests.difference(frames[4], scene, x0: 0, y0: 40, x1: 120, y1: 80)
        XCTAssertLessThan(MergeTests.difference(mean, scene, x0: 0, y0: 40, x1: 120, y1: 80), 0.6 * noisy)
        // The mean keeps a faint trace of each square.
        XCTAssertGreaterThan(MergeTests.difference(mean, scene, x0: 10, y0: 20, x1: 22, y1: 32), 0.04)
    }

    func testStackModesMatchControls() throws {
        let registry = try ControlRegistry.bundled()
        XCTAssertEqual(registry.control(id: "stackMode")!.options.map(\.id), Stack.modes)
        XCTAssertEqual(registry.control(id: "stackAverage")!.options.map(\.id), Stack.modes)
        XCTAssertEqual(MergeTools.optionSetting["stackAverage"], "stackMode")
        var state = EditState()
        var interpreter = CommandInterpreter(registry: registry)
        XCTAssertEqual(CommandParser(registry: registry).parse("stack mean"), [.run("stackAverage", value: 1)])
        XCTAssertEqual(interpreter.interpret("stack mean", state: &state),
                       [.ran(controlID: "stackAverage"), .changed(controlID: "stackMode", from: 0, to: 1)])
    }
}
