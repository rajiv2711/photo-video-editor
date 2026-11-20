import XCTest
@testable import CommandEngine

/// The Optics panel: names that reach its controls, lens profiles and the CPU lens warp.
final class OpticsTests: XCTestCase {
    private var registry: ControlRegistry!
    private var parser: CommandParser!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
        parser = CommandParser(registry: registry)
    }

    private func parse(_ text: String) -> [Command] {
        parser.parse(text)
    }

    func testOpticsControlsAreInTheOpticsPanel() {
        for id in ["lensProfile", "removeCA", "caRedCyan", "caBlueYellow"] {
            XCTAssertEqual(registry.control(id: id)?.group, "optics", id)
        }
    }

    // MARK: - Lens profile

    func testLensProfileNames() {
        XCTAssertEqual(parse("lens profile correction on"), [.set("lensProfile", 1)])
        XCTAssertEqual(parse("lens correction off"), [.set("lensProfile", 0)])
        XCTAssertEqual(parse("enable profile corrections"), [.set("lensProfile", 1)])
        XCTAssertEqual(parse("profile vivid"), [.set("profile", 1)], "the colour profile stays a choice")
    }

    func testBundledProfilesLoad() {
        XCTAssertGreaterThanOrEqual(LensProfile.bundled.count, 5)
        for lens in LensProfile.bundled {
            XCTAssertFalse(lens.distortion.isEmpty, lens.model)
            XCTAssertFalse(lens.vignetting.isEmpty, lens.model)
        }
    }

    func testExifLensNamesFindTheirProfile() {
        XCTAssertEqual(LensProfile.find(lensModel: "EF-S18-55mm f/3.5-5.6 IS STM")?.model, "Canon EF-S 18-55mm f/3.5-5.6 IS STM")
        XCTAssertEqual(LensProfile.find(lensModel: "EF50mm f/1.8 STM")?.model, "Canon EF 50mm f/1.8 STM")
        XCTAssertEqual(LensProfile.find(lensModel: "E PZ 16-50mm F3.5-5.6 OSS")?.model, "E PZ 16-50mm f/3.5-5.6 OSS I/II")
        XCTAssertEqual(LensProfile.find(lensModel: "XF18-55mmF2.8-4 R LM OIS")?.maker, "Fujifilm")
        XCTAssertNil(LensProfile.find(lensModel: "iPad Pro back camera 6.86mm f/1.8"))
        XCTAssertNil(LensProfile.correction(for: PhotoLens(make: "Apple", lensModel: nil, focal: 6.9, aperture: 1.8)))
    }

    func testCorrectionInterpolatesBetweenFocalLengths() throws {
        let lens = try XCTUnwrap(LensProfile.find(lensModel: "EF-S18-55mm f/3.5-5.6 IS STM"))
        let at18 = lens.correction(focal: 18, aperture: 3.5), at24 = lens.correction(focal: 24, aperture: 3.5)
        let at21 = lens.correction(focal: 21, aperture: 3.5)
        XCTAssertEqual(at18.a, 0.01786, accuracy: 1e-9)
        XCTAssertEqual(at21.b, (at18.b + at24.b) / 2, accuracy: 1e-9)
        XCTAssertEqual(lens.correction(focal: 10, aperture: nil).a, at18.a, "below the range: the nearest end")
        XCTAssertLessThan(at18.k1, 0, "wide open the corners are darker, so the correction brightens them")
        XCTAssertNotEqual(lens.correction(focal: 18, aperture: 11).k1, at18.k1, "stopped down: another vignetting")
    }

    // MARK: - Lens warp

    private func image(width: Int, height: Int, _ f: (Int, Int) -> Float) -> [Float] {
        var out: [Float] = []
        for y in 0..<height { for x in 0..<width { let v = f(x, y); out += [v, v, v, 1] } }
        return out
    }

    func testNoCorrectionLeavesThePictureAlone() {
        let pixels = image(width: 8, height: 6) { x, y in Float(x + 10 * y) }
        XCTAssertTrue(LensWarp().isIdentity)
        XCTAssertEqual(LensWarp().apply(pixels, width: 8, height: 6), pixels)
    }

    func testDistortionModelKeepsHalfTheShortSideInPlace() {
        let warp = LensWarp(profile: LensCorrection(a: 0.02, b: -0.06, c: 0.01))
        let p = warp.source(of: LensWarp.Point(x: 0, y: 100), width: 300, height: 200).green
        XCTAssertEqual(p.y, 100, accuracy: 1e-9, "r = 1 at half the shorter side")
        let corner = warp.source(of: LensWarp.Point(x: 150, y: 100), width: 300, height: 200).green
        let r = (150.0 * 150 + 100 * 100).squareRoot() / 100
        XCTAssertEqual(corner.x, 150 * (0.02 * r * r * r - 0.06 * r * r + 0.01 * r + 1.03), accuracy: 1e-9)
    }

    func testFillScaleKeepsTheFrameFilled() {
        XCTAssertEqual(LensWarp(profile: LensCorrection(k1: -0.5)).fillScale(width: 300, height: 200), 1, "vignetting only")
        // Red spread out by 1 %: the edge would read red from outside, so the picture zooms in a little.
        let fringe = LensWarp(profile: LensCorrection(red: .init(v: 1.01)))
        XCTAssertEqual(fringe.fillScale(width: 300, height: 200), 1 / 1.01, accuracy: 1e-6)
    }

    func testVignettingIsUndoneAtTheCorners() {
        let warp = LensWarp(profile: LensCorrection(k1: -0.5))
        let pixels = image(width: 41, height: 41) { _, _ in 0.4 }
        let out = warp.apply(pixels, width: 41, height: 41)
        XCTAssertEqual(out[(20 * 41 + 20) * 4], 0.4, accuracy: 1e-4, "centre unchanged")
        let corner = out[0]
        XCTAssertGreaterThan(corner, 0.7, "corner brightened by about 1 / (1 − 0.5)")
        XCTAssertEqual(out[3], 1, "opaque")
    }

    func testRemapMovesContentAsTheModelSays() {
        // A horizontal ramp (value = x position). Pincushion-type correction (sampling further out):
        // a pixel right of centre shows what was further right.
        let warp = LensWarp(profile: LensCorrection(a: 0, b: 0.05, c: 0))
        let w = 101, h = 61
        let pixels = image(width: w, height: h) { x, _ in Float(x) }
        let out = warp.apply(pixels, width: w, height: h)
        XCTAssertEqual(out[(30 * w + 50) * 4], 50, accuracy: 1e-3, "centre stays")
        let scale = warp.fillScale(width: Double(w), height: Double(h))
        let expected = warp.source(of: LensWarp.Point(x: 30 * scale, y: 0.5 * scale), width: Double(w), height: Double(h)).green.x
        XCTAssertEqual(Double(out[(30 * w + 80) * 4]), expected + Double(w) / 2 - 0.5, accuracy: 0.05)
    }

    // MARK: - Chromatic aberration

    func testChromaticAberrationNames() {
        XCTAssertEqual(parse("remove chromatic aberration"), [.set("removeCA", 1)])
        XCTAssertEqual(parse("chromatic aberration off"), [.set("removeCA", 0)])
        XCTAssertEqual(parse("red cyan fringe 40"), [.set("caRedCyan", 40)])
        XCTAssertEqual(parse("red cyan 40"), [.set("selectiveRedsCyan", 40)], "Selective color keeps its name")
        XCTAssertEqual(parse("blue fringe down"), [.nudge("caBlueYellow", -1)])
    }

    /// A grey grid of soft dark lines whose red is spread `red` times wider than green, and blue `blue` times.
    private func fringedGrid(width: Int, height: Int, red: Double, blue: Double) -> [Float] {
        func grid(_ p: LensWarp.Point) -> Float {
            let x = p.x + Double(width) / 2, y = p.y + Double(height) / 2
            func near(_ v: Double) -> Double {
                let d = v.truncatingRemainder(dividingBy: 24) - 12
                return exp(-d * d / 4.5)
            }
            return Float(0.8 - 0.75 * max(near(x), near(y)))
        }
        var out: [Float] = []
        for y in 0..<height {
            for x in 0..<width {
                let p = LensWarp.Point(x: Double(x) + 0.5 - Double(width) / 2, y: Double(y) + 0.5 - Double(height) / 2)
                out += [grid(p.scaled(1 / red)), grid(p), grid(p.scaled(1 / blue)), 1]
            }
        }
        return out
    }

    func testEstimateFindsTheFringes() {
        let pixels = fringedGrid(width: 240, height: 160, red: 1.004, blue: 0.996)
        let found = ChromaticAberration.estimate(pixels, width: 240, height: 160)
        XCTAssertEqual(found.red, 1.004, accuracy: 0.0006)
        XCTAssertEqual(found.blue, 0.996, accuracy: 0.0006)
        let clean = ChromaticAberration.estimate(fringedGrid(width: 240, height: 160, red: 1, blue: 1), width: 240, height: 160)
        XCTAssertEqual(clean.red, 1, accuracy: 0.0002)
        XCTAssertEqual(clean.blue, 1, accuracy: 0.0002)
    }

    func testFixingTheScalesLinesTheChannelsUp() {
        let w = 240, h = 160
        let pixels = fringedGrid(width: w, height: h, red: 1.004, blue: 0.996)
        let fixed = LensWarp(redScale: 1.004, blueScale: 0.996).apply(pixels, width: w, height: h)
        func fringe(_ p: [Float]) -> Float {
            var sum: Float = 0
            for i in stride(from: 0, to: p.count, by: 4) {
                sum += abs(p[i] - p[i + 1])
                sum += abs(p[i + 2] - p[i + 1])
            }
            return sum
        }
        XCTAssertLessThan(fringe(fixed), fringe(pixels) / 3)
        XCTAssertEqual(ChromaticAberration.scale(slider: 80), 1.004, accuracy: 1e-12)
        XCTAssertEqual(ChromaticAberration.scale(slider: 0), 1)
    }
}
