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

    func testHDRRangeContinuesAboveWhite() {
        XCTAssertEqual(out(["whites": 100], 1, maxInput: 4), 1.25, accuracy: 0.01, "HDR keeps whites above 1")
        XCTAssertEqual(out([:], 2.5, maxInput: 4), 2.5, accuracy: 0.01)
        XCTAssertEqual(out(["highlights": 100], 3, maxInput: 4), 3, accuracy: 0.01)
    }
}
