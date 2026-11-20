import XCTest
@testable import CommandEngine

/// The Light panel's tone lookup tables (ToneCurve), checked as numbers: direction, fixed ends,
/// no going down, HDR range.
final class ToneCurveTests: XCTestCase {
    /// A value lookup from a dictionary; ids not listed count as untouched.
    private func values(_ v: [String: Double]) -> (String) -> Double? {
        { v[$0] }
    }

    private func out(_ v: [String: Double], _ x: Double, maxInput: Double = 1) -> Double {
        let table = ToneCurve.table(values(v), maxInput: maxInput)
        return table.lookup(x, channel: table.green)
    }

    private func assertMonotone(_ v: [String: Double], file: StaticString = #filePath, line: UInt = #line) {
        let table = ToneCurve.table(values(v))
        for channel in [table.red, table.green, table.blue] {
            for i in channel.indices.dropFirst() {
                XCTAssertGreaterThanOrEqual(channel[i], channel[i - 1], "\(v) goes down at \(i)", file: file, line: line)
            }
        }
    }

    func testUntouchedIsIdentity() {
        XCTAssertTrue(ToneCurve.isIdentity(values([:])))
        XCTAssertTrue(ToneCurve.isIdentity(values(["highlights": 0, "exposure": 2])))
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(out([:], x), x, accuracy: 1e-6)
        }
    }

    func testHighlightsBrightenTheUpperTonesOnly() {
        XCTAssertFalse(ToneCurve.isIdentity(values(["highlights": 100])))
        XCTAssertEqual(out(["highlights": 100], 0.75), 0.85, accuracy: 0.005)
        XCTAssertEqual(out(["highlights": 100], 0.1), 0.1, accuracy: 0.01)
        XCTAssertEqual(out(["highlights": 100], 1), 1, accuracy: 1e-6)
        XCTAssertEqual(out(["highlights": -100], 0.75), 0.75, accuracy: 1e-6, "darkening is done by CIHighlightShadowAdjust")
        assertMonotone(["highlights": 100])
    }

    func testWhitesMoveTheTopEnd() {
        XCTAssertGreaterThan(out(["whites": 100], 0.9), 1 - 1e-9, "brightest tones clip to white")
        XCTAssertEqual(out(["whites": 100], 0.5), 0.53, accuracy: 0.01)
        XCTAssertEqual(out(["whites": -100], 1), 0.75, accuracy: 0.005)
        XCTAssertEqual(out(["whites": -100], 0), 0, accuracy: 1e-6)
        assertMonotone(["whites": -100])
        assertMonotone(["whites": 100])
    }

    func testBlacksMoveTheBottomEnd() {
        XCTAssertEqual(out(["blacks": -100], 0.1), 0, accuracy: 1e-6, "darkest tones crush to black")
        XCTAssertEqual(out(["blacks": 100], 0), 0.25, accuracy: 0.005)
        XCTAssertEqual(out(["blacks": 100], 1), 1, accuracy: 1e-6)
        XCTAssertEqual(out(["blacks": -100], 0.5), 0.47, accuracy: 0.01)
        assertMonotone(["blacks": -100])
        assertMonotone(["blacks": 100, "whites": -100])
    }

    func testBrightnessMovesMidtonesNotTheEnds() {
        XCTAssertEqual(out(["brightness": 100], 0.5), 0.671, accuracy: 0.005)
        XCTAssertEqual(out(["brightness": -100], 0.5), 0.30, accuracy: 0.005)
        XCTAssertEqual(out(["brightness": 100], 0), 0, accuracy: 1e-6)
        XCTAssertEqual(out(["brightness": 100], 1), 1, accuracy: 1e-6)
        assertMonotone(["brightness": 100, "blacks": -50])
    }

    func testFadeLiftsBlackOnly() {
        XCTAssertEqual(out(["fade": 100], 0), 0.25, accuracy: 0.005)
        XCTAssertEqual(out(["fade": 100], 1), 1, accuracy: 1e-6)
        XCTAssertEqual(out(["fade": 40], 0), 0.1, accuracy: 0.005)
        assertMonotone(["fade": 100, "blacks": -100])
    }

    func testSplinePassesThroughItsPointsWithoutOvershoot() {
        let xs = [0, 0.25, 0.5, 0.75, 1.0], ys = [0, 0.1, 0.9, 0.95, 1.0]
        for (x, y) in zip(xs, ys) { XCTAssertEqual(ToneCurve.spline(xs: xs, ys: ys, at: x), y, accuracy: 1e-9) }
        var last = -1.0
        for x in stride(from: 0.0, through: 1.0, by: 0.01) {
            let y = ToneCurve.spline(xs: xs, ys: ys, at: x)
            XCTAssertGreaterThanOrEqual(y, last - 1e-12)
            XCTAssertLessThanOrEqual(y, 1 + 1e-12)
            last = y
        }
    }

    func testToneCurveRegionsMoveTheirQuarter() {
        XCTAssertEqual(out(["curveShadows": 100], 0.125), 0.245, accuracy: 0.002)
        XCTAssertEqual(out(["curveDarks": 100], 0.375), 0.495, accuracy: 0.002)
        XCTAssertEqual(out(["curveLights": -100], 0.625), 0.505, accuracy: 0.002)
        XCTAssertEqual(out(["curveHighlights": 100], 0.875), 0.995, accuracy: 0.002)
        XCTAssertEqual(out(["curveDarks": 100], 0.9), 0.9, accuracy: 0.02, "far regions barely move")
        for v in [["curveShadows": 100.0, "curveDarks": -100.0], ["curveShadows": -100, "curveDarks": 100, "curveLights": -100, "curveHighlights": 100]] {
            XCTAssertEqual(out(v, 0), 0, accuracy: 1e-6)
            XCTAssertEqual(out(v, 1), 1, accuracy: 1e-6)
            assertMonotone(v)
        }
    }

    func testHDRRangeContinuesAboveWhite() {
        XCTAssertEqual(out(["whites": 100], 1, maxInput: 4), 1.25, accuracy: 0.01, "HDR keeps whites above 1")
        XCTAssertEqual(out([:], 2.5, maxInput: 4), 2.5, accuracy: 0.01)
        XCTAssertEqual(out(["highlights": 100], 3, maxInput: 4), 3, accuracy: 0.01)
    }
}
