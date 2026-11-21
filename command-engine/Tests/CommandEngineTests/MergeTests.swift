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
