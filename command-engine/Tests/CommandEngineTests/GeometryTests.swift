import XCTest
@testable import CommandEngine

/// Geometry: the transforms, the crop box and its handles, how points on the edited picture map back
/// to the photo, and the Geometry panel's names.
final class GeometryTests: XCTestCase {
    private var registry: ControlRegistry!

    override func setUpWithError() throws {
        registry = try ControlRegistry.bundled()
    }

    private func parse(_ text: String) -> [Command] {
        CommandParser(registry: registry).parse(text)
    }

    private func control(_ id: String) -> Control {
        registry.control(id: id)!
    }

    private func assertClose(_ a: Vec2, _ b: Vec2, _ tolerance: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: tolerance, file: file, line: line)
    }

    // MARK: - Transforms

    func testQuarterTurnsAreExactAndClockwise() {
        let r = Homography.rotation(degrees: 90)
        XCTAssertEqual(r.apply(Vec2(1, 0)), Vec2(0, 1), "x → down: clockwise on screen")
        XCTAssertEqual(Homography.rotation(degrees: 180).apply(Vec2(2, 3)), Vec2(-2, -3))
        XCTAssertEqual(Homography.rotation(degrees: -90).apply(Vec2(1, 0)), Vec2(0, -1))
    }

    func testInverseAndComposition() {
        let h = Homography.translation(10, -4) * Homography.rotation(degrees: 17) * Homography.scale(2, 0.5)
        let p = Vec2(3, 7)
        assertClose(h.inverse.apply(h.apply(p)), p)
        assertClose((h * h.inverse).apply(p), p)
        XCTAssertTrue(h.isAffine)
    }

    func testFourPointMappingIsExact() throws {
        let from = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 50), Vec2(0, 50)]
        let to = [Vec2(10, 5), Vec2(90, 0), Vec2(110, 60), Vec2(-5, 55)]
        let h = try XCTUnwrap(Homography.mapping(from, to: to))
        for (p, q) in zip(from, to) { assertClose(h.apply(p), q, 1e-6) }
        XCTAssertFalse(h.isAffine)
        XCTAssertNil(Homography.mapping([Vec2(0, 0), Vec2(1, 1), Vec2(2, 2), Vec2(3, 3)], to: to), "points in a line")
    }

    // MARK: - Crop

    func testAspectOptionsMirrorControls() {
        XCTAssertEqual(control("cropAspect").options.map(\.id), Crop.aspects)
        XCTAssertEqual(Crop.ratio("16:9", original: 1.5)!, 16.0 / 9, accuracy: 1e-12)
        XCTAssertEqual(Crop.ratio("original", original: 1.5), 1.5)
        XCTAssertNil(Crop.ratio("free", original: 1.5))
        for id in GeometryTools.cropIDs + Array(GeometryTools.actions.keys) { XCTAssertNotNil(registry.control(id: id), id) }
        for id in GeometryTools.actions.keys { XCTAssertEqual(control(id).kind, .action, id) }
    }

    func testNoCropIsTheWholePhotoAndSkipsTheStep() {
        let plan = GeometryPlan(settings: GeometrySettings(), width: 533, height: 800)
        XCTAssertEqual(plan.crop, GeoRect(x: 0, y: 0, width: 533, height: 800))
        XCTAssertTrue(plan.isIdentity)
        let fractional = GeometryPlan(settings: GeometrySettings(), width: 533.3, height: 800)
        XCTAssertEqual(fractional.crop.width, 533, "whole pixels")
    }

    func testAspectPresetIsCentredAndAsLargeAsFits() {
        let plan = GeometryPlan(settings: GeometrySettings(aspect: "16:9"), width: 533, height: 800)
        XCTAssertEqual(plan.crop.width, 533)
        XCTAssertEqual(plan.crop.height, 299, accuracy: 1)
        XCTAssertEqual(plan.crop.centre.y, 400, accuracy: 1)
        XCTAssertFalse(plan.isIdentity)
        let square = GeometryPlan(settings: GeometrySettings(aspect: "1:1"), width: 800, height: 533)
        XCTAssertEqual(square.crop.width, square.crop.height, accuracy: 1)
        XCTAssertEqual(square.crop.height, 533)
    }

    func testEdgesCutEachSide() {
        let s = GeometrySettings(aspect: "free", cropLeft: 0.1, cropTop: 0.2, cropRight: 0.3, cropBottom: 0)
        let plan = GeometryPlan(settings: s, width: 1000, height: 500)
        XCTAssertEqual(plan.crop, GeoRect(x: 100, y: 100, width: 600, height: 400))
        // With an aspect the box narrows inside the edges, centred.
        let locked = GeometryPlan(settings: GeometrySettings(aspect: "1:1", cropLeft: 0.1, cropTop: 0.2, cropRight: 0.3),
                                  width: 1000, height: 500)
        XCTAssertEqual(locked.crop, GeoRect(x: 200, y: 100, width: 400, height: 400))
    }

    func testSettingsReadTheControls() {
        let values: [String: Double] = ["cropAspect": 10, "cropLeft": 12.5, "cropBottom": 120]
        let s = GeometrySettings(value: { values[$0] })
        XCTAssertEqual(s.aspect, "16:9")
        XCTAssertEqual(s.cropLeft, 0.125)
        XCTAssertEqual(s.cropBottom, 0.95, "at most 95 %")
    }

    func testConstrainShrinksTheBoxInsideATurnedPhoto() {
        // A 100 × 100 photo turned 10° about its centre: the full box would show empty corners.
        let turn = Homography.translation(50, 50) * Homography.rotation(degrees: 10) * Homography.translation(-50, -50)
        let valid = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)].map { turn.apply($0) }
        let box = Crop.constrained(GeoRect(x: 0, y: 0, width: 100, height: 100), inside: valid, width: 100, height: 100)
        // The largest centred square inside a square turned by θ has side s / (cos θ + sin θ).
        let expected = 100 / (cos(10 * Double.pi / 180) + sin(10 * Double.pi / 180))
        XCTAssertEqual(box.width, expected, accuracy: 0.01)
        XCTAssertEqual(box.centre.x, 50, accuracy: 1e-9)
        for corner in [Vec2(box.x, box.y), Vec2(box.maxX, box.maxY)] { XCTAssertTrue(Crop.inside(corner, valid)) }
        XCTAssertFalse(Crop.inside(Vec2(0.5, 0.5), valid), "the frame's corner is empty")
    }

    func testPointsOnTheCroppedPictureMapBackToThePhoto() {
        let s = GeometrySettings(aspect: "free", cropLeft: 0.25, cropTop: 0.5)
        let plan = GeometryPlan(settings: s, width: 800, height: 400)
        let p = plan.toSource(MaskPoint(0, 0))
        XCTAssertEqual(p.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
        let q = plan.toSource(MaskPoint(1, 1))
        XCTAssertEqual(q.x, 1, accuracy: 1e-9)
        XCTAssertEqual(q.y, 1, accuracy: 1e-9)
        let back = plan.toShown(MaskPoint(0.625, 0.75))
        XCTAssertEqual(back.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(back.y, 0.5, accuracy: 1e-9)
        // The crop tool shows the whole frame: its points are the photo's.
        let frame = GeometryPlan(settings: s, width: 800, height: 400, stage: .frame)
        XCTAssertEqual(frame.crop, GeoRect(x: 0, y: 0, width: 800, height: 400))
        XCTAssertEqual(frame.toSource(MaskPoint(0.3, 0.6)), MaskPoint(0.3, 0.6))
    }

    func testHandlesAreFoundNearCornersEdgesAndInside() {
        let box = (x0: 0.2, y0: 0.2, x1: 0.8, y1: 0.8)
        XCTAssertEqual(Crop.handle(at: MaskPoint(0.21, 0.19), box: box), .corner(0))
        XCTAssertEqual(Crop.handle(at: MaskPoint(0.8, 0.8), box: box), .corner(2))
        XCTAssertEqual(Crop.handle(at: MaskPoint(0.5, 0.18), box: box), .edge(1))
        XCTAssertEqual(Crop.handle(at: MaskPoint(0.82, 0.5), box: box), .edge(2))
        XCTAssertEqual(Crop.handle(at: MaskPoint(0.5, 0.5), box: box), .move)
        XCTAssertEqual(Crop.handle(at: MaskPoint(0.05, 0.95), box: box), .new)
    }

    func testDraggingTheCropBox() {
        let box = (x0: 0.0, y0: 0.0, x1: 1.0, y1: 1.0)
        // A free corner follows the finger.
        let free = Crop.drag(.corner(0), box: box, from: MaskPoint(0, 0), to: MaskPoint(0.2, 0.1), aspect: nil, width: 200, height: 100)
        XCTAssertEqual(free.x0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(free.y0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(free.x1, 1)
        // A locked corner keeps the aspect (2:1 in pixels here), the opposite corner stays.
        let locked = Crop.drag(.corner(0), box: box, from: MaskPoint(0, 0), to: MaskPoint(0.5, 0.1), aspect: 2, width: 200, height: 100)
        XCTAssertEqual((locked.x1 - locked.x0) * 200 / ((locked.y1 - locked.y0) * 100), 2, accuracy: 1e-9)
        XCTAssertEqual(locked.x1, 1)
        XCTAssertEqual(locked.y1, 1)
        // Moving keeps the size and stays on the frame.
        let moved = Crop.drag(.move, box: (0.1, 0.1, 0.5, 0.5), from: MaskPoint(0.3, 0.3), to: MaskPoint(0.9, 0.2), aspect: nil,
                              width: 100, height: 100)
        XCTAssertEqual(moved.x1, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.x0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(moved.y0, 0.0, accuracy: 1e-9)
        // An edge with a lock: the other side follows, centred.
        let edge = Crop.drag(.edge(2), box: (0.0, 0.0, 1.0, 1.0), from: MaskPoint(1, 0.5), to: MaskPoint(0.5, 0.5), aspect: 1,
                             width: 100, height: 100)
        XCTAssertEqual(edge.x1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(edge.y1 - edge.y0, 0.5, accuracy: 1e-9)
        XCTAssertEqual((edge.y0 + edge.y1) / 2, 0.5, accuracy: 1e-9)
        // A new box from a drag outside.
        let new = Crop.drag(.new, box: (0.4, 0.4, 0.6, 0.6), from: MaskPoint(0.9, 0.9), to: MaskPoint(0.1, 0.2), aspect: nil,
                            width: 100, height: 100)
        XCTAssertEqual(new.x0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(new.y1, 0.9, accuracy: 1e-9)
        XCTAssertEqual(Crop.edges(of: (0.1, 0.2, 0.75, 1)), ["cropLeft": 10, "cropTop": 20, "cropRight": 25, "cropBottom": 0])
    }

    // MARK: - Straighten

    /// A light grey picture with dark lines (2 px wide, soft-edged) between the given ends, in pixels.
    static func picture(width: Int, height: Int, lines: [(Vec2, Vec2)]) -> [Float] {
        var pixels = [Float](repeating: 0.8, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = Vec2(Double(x) + 0.5, Double(y) + 0.5)
                var near = Double.infinity
                for (a, b) in lines {
                    let ab = b - a, ap = p - a
                    let t = Swift.min(1, Swift.max(0, (ap.x * ab.x + ap.y * ab.y) / (ab.x * ab.x + ab.y * ab.y)))
                    near = Swift.min(near, (p - (a + ab * t)).length)
                }
                let ink = Swift.min(1, Swift.max(0, 1.5 - near))
                pixels[y * width + x] = Float(0.8 - 0.65 * ink)
            }
        }
        return pixels
    }

    /// Lines of a grid turned `degrees` clockwise about the middle of a `width` × `height` picture.
    static func turnedGrid(width: Double, height: Double, degrees: Double, spacing: Double = 40) -> [(Vec2, Vec2)] {
        let turn = Homography.translation(width / 2, height / 2) * Homography.rotation(degrees: degrees)
            * Homography.translation(-width / 2, -height / 2)
        var lines: [(Vec2, Vec2)] = []
        var v = -width
        while v <= 2 * width {
            lines.append((turn.apply(Vec2(v, -height)), turn.apply(Vec2(v, 2 * height))))
            lines.append((turn.apply(Vec2(-width, v)), turn.apply(Vec2(2 * width, v))))
            v += spacing
        }
        return lines
    }

    func testLineDetectorFindsLinesAndTheirAngles() {
        let w = 320, h = 240
        let lines = [(Vec2(20, 40), Vec2(300, 70)), (Vec2(160, 100), Vec2(150, 230)), (Vec2(30, 200), Vec2(120, 120))]
        let found = LineDetector.detect(Self.picture(width: w, height: h, lines: lines), width: w, height: h)
        XCTAssertGreaterThanOrEqual(found.count, 3)
        for (a, b) in lines {
            let want = atan2(b.y - a.y, b.x - a.x)
            let hit = found.contains { s in
                let (p, q) = s.ends(width: Double(w), height: Double(h))
                var diff = abs(atan2(q.y - p.y, q.x - p.x) - want).truncatingRemainder(dividingBy: .pi)
                diff = Swift.min(diff, .pi - diff)
                return diff < 0.6 * .pi / 180 && s.length > 0.5 * (b - a).length
            }
            XCTAssertTrue(hit, "no segment along \(a) → \(b)")
        }
        XCTAssertTrue(LineDetector.detect([Float](repeating: 0.5, count: w * h), width: w, height: h).isEmpty, "a flat picture has no lines")
    }

    func testAutoStraightenLevelsATurnedGrid() throws {
        let w = 400, h = 300
        let pixels = Self.picture(width: w, height: h, lines: Self.turnedGrid(width: Double(w), height: Double(h), degrees: -6))
        let segments = LineDetector.detect(pixels, width: w, height: h)
        let angle = try XCTUnwrap(Straighten.autoAngle(segments, width: Double(w), height: Double(h)))
        XCTAssertEqual(angle, 6, accuracy: 0.3, "turned 6° anticlockwise: straighten 6° clockwise")
        XCTAssertNil(Straighten.autoAngle([], width: 10, height: 10))
    }

    func testDrawnLineGivesTheAngleThatLevelsIt() {
        XCTAssertEqual(Straighten.angle(levelling: Vec2(0, 0), Vec2(100, 10)), -atan(0.1) * 180 / .pi, accuracy: 1e-9)
        XCTAssertEqual(Straighten.angle(levelling: Vec2(100, 10), Vec2(0, 0)), -atan(0.1) * 180 / .pi, accuracy: 1e-9, "either way")
        XCTAssertEqual(Straighten.angle(levelling: Vec2(0, 0), Vec2(5, 100)), atan(0.05) * 180 / .pi, accuracy: 1e-9, "near upright")
        // A line drawn on the straightened frame: measured before the turn, so it gives the whole angle.
        let s = GeometrySettings(straighten: 4)
        let plan = GeometryPlan(settings: s, width: 400, height: 300, stage: .frame)
        let turn = Homography.translation(200, 150) * Homography.rotation(degrees: 4 + 3) * Homography.translation(-200, -150)
        let a = turn.apply(Vec2(50, 150)), b = turn.apply(Vec2(350, 150))
        let p = plan.frameToPreStraighten(MaskPoint(a.x / 400, a.y / 300)), q = plan.frameToPreStraighten(MaskPoint(b.x / 400, b.y / 300))
        XCTAssertEqual(Straighten.angle(levelling: p, q), -3, accuracy: 1e-6, "a line 3° past level → straighten −3")
    }

    func testStraightenTurnsTheFrameAndShrinksTheCrop() {
        let plan = GeometryPlan(settings: GeometrySettings(straighten: 10), width: 400, height: 300)
        XCTAssertFalse(plan.isIdentity)
        XCTAssertLessThan(plan.crop.width, 400)
        XCTAssertEqual(plan.crop.width / plan.crop.height, 4.0 / 3, accuracy: 0.02, "keeps the box's shape")
        for c in [Vec2(plan.crop.x, plan.crop.y), Vec2(plan.crop.maxX, plan.crop.maxY)] { XCTAssertTrue(Crop.inside(c, plan.photoCorners)) }
        // The middle stays the middle; a point maps back through the turn.
        let mid = plan.toSource(MaskPoint(0.5, 0.5))
        XCTAssertEqual(mid.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(mid.y, 0.5, accuracy: 0.01)
        let shown = plan.toShown(MaskPoint(0.3, 0.4))
        let back = plan.toSource(shown)
        XCTAssertEqual(back.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(back.y, 0.4, accuracy: 1e-9)
        XCTAssertEqual(GeometrySettings(value: { $0 == "straighten" ? 60 : nil }).straighten, 45)
    }

    func testStraightenNames() {
        XCTAssertEqual(parse("straighten 5"), [.set("straighten", 5)])
        XCTAssertEqual(parse("auto straighten"), [.run("autoStraighten")])
        XCTAssertEqual(parse("auto level"), [.run("autoStraighten")])
        XCTAssertEqual(parse("auto"), [.run("auto")], "Auto alone is still Auto")
        XCTAssertEqual(parse("straighten tool"), [.run("straightenTool")])
        // Auto Straighten comes back from the app's handler as a Straighten value.
        var interpreter = CommandInterpreter(registry: registry)
        interpreter.actionHandler = { id in id == "autoStraighten" ? [.set("straighten", 6)] : [] }
        var state = EditState()
        XCTAssertEqual(interpreter.interpret("auto straighten", state: &state),
                       [.ran(controlID: "autoStraighten"), .changed(controlID: "straighten", from: 0, to: 6)])
    }

    // MARK: - Rotate and flip

    func testQuarterTurnsSwapTheFrameAndFlipsMirror() {
        let turned = GeometryPlan(settings: GeometrySettings(quarterTurns: 1), width: 400, height: 300)
        XCTAssertEqual(turned.frameWidth, 300)
        XCTAssertEqual(turned.frameHeight, 400)
        XCTAssertEqual(turned.crop, GeoRect(x: 0, y: 0, width: 300, height: 400))
        // Clockwise: the photo's top-left corner ends up top-right.
        assertClose(turned.transform.apply(Vec2(0, 0)), Vec2(300, 0))
        assertClose(turned.transform.apply(Vec2(400, 300)), Vec2(0, 400))
        let mirrored = GeometryPlan(settings: GeometrySettings(flipHorizontal: true), width: 400, height: 300)
        assertClose(mirrored.transform.apply(Vec2(10, 20)), Vec2(390, 20))
        XCTAssertFalse(mirrored.isIdentity)
        let flipped = GeometryPlan(settings: GeometrySettings(flipVertical: true), width: 400, height: 300)
        assertClose(flipped.transform.apply(Vec2(10, 20)), Vec2(10, 280))
        // Both flips are a half turn.
        let both = GeometryPlan(settings: GeometrySettings(flipHorizontal: true, flipVertical: true), width: 400, height: 300)
        let half = GeometryPlan(settings: GeometrySettings(quarterTurns: 2), width: 400, height: 300)
        XCTAssertTrue(both.transform.isClose(to: half.transform))
        // A tap on the turned picture lands on the right spot of the photo.
        let p = turned.toSource(MaskPoint(1, 0))
        XCTAssertEqual(p.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0, accuracy: 1e-9)
        // "Original" crop aspect follows the turned frame.
        let original = GeometryPlan(settings: GeometrySettings(aspect: "original", quarterTurns: 1), width: 400, height: 300)
        XCTAssertEqual(original.crop, GeoRect(x: 0, y: 0, width: 300, height: 400))
    }

    func testRotateActionsStepTheTurnAndTheCropFollows() {
        var interpreter = CommandInterpreter(registry: registry)
        var state = EditState()
        _ = interpreter.interpret("crop left 10 crop 16 by 9", state: &state)
        XCTAssertEqual(interpreter.interpret("rotate right", state: &state),
                       [.ran(controlID: "rotateRight"), .changed(controlID: "rotation", from: 0, to: 1)])
        XCTAssertEqual(state.value(of: control("cropTop")), 10, "what was cut on the left is now cut at the top")
        XCTAssertEqual(state.value(of: control("cropLeft")), 0)
        XCTAssertEqual(state.value(of: control("cropAspect")), Double(Crop.aspects.firstIndex(of: "9:16")!))
        _ = interpreter.interpret("rotate left rotate left", state: &state)
        XCTAssertEqual(state.value(of: control("rotation")), 3)
        XCTAssertEqual(state.value(of: control("cropBottom")), 10)
        _ = interpreter.interpret("rotation 0", state: &state)
        XCTAssertEqual(state.value(of: control("cropLeft")), 10, "back where it was")
        _ = interpreter.interpret("flip horizontal", state: &state)
        XCTAssertEqual(state.value(of: control("cropRight")), 10)
        XCTAssertEqual(state.value(of: control("cropLeft")), 0)
        _ = interpreter.interpret("flip horizontal off", state: &state)
        XCTAssertEqual(state.value(of: control("cropLeft")), 10)
    }

    func testRotateNames() {
        XCTAssertEqual(parse("rotate left"), [.run("rotateLeft")])
        XCTAssertEqual(parse("rotate 90"), [.run("rotateRight")])
        XCTAssertEqual(parse("rotate 180"), [.set("rotation", 2)])
        XCTAssertEqual(parse("rotation upside down"), [.set("rotation", 2)])
        XCTAssertEqual(parse("flip"), [.set("flipHorizontal", 1)])
        XCTAssertEqual(parse("flip vertical"), [.set("flipVertical", 1)])
        XCTAssertFalse(parse("rotat left").contains(.run("rotateLeft")), "actions only by their exact name")
    }

    // MARK: - Upright

    /// A camera turn (pitch about x, then yaw about y, then roll about z, degrees) as a picture transform.
    static func cameraTurn(pitch: Double, yaw: Double = 0, roll: Double = 0, width: Double, height: Double) -> Homography {
        let f = Upright.defaultFocal(width: width, height: height)
        let (p, y, r) = (pitch * .pi / 180, yaw * .pi / 180, roll * .pi / 180)
        let rx = Homography([1, 0, 0, 0, cos(p), -sin(p), 0, sin(p), cos(p)])
        let ry = Homography([cos(y), 0, sin(y), 0, 1, 0, -sin(y), 0, cos(y)])
        let rz = Homography([cos(r), -sin(r), 0, sin(r), cos(r), 0, 0, 0, 1])
        let k = Homography([f, 0, width / 2, 0, f, height / 2, 0, 0, 1])
        return k * rz * ry * rx * k.inverse
    }

    /// A grid's lines (every 100 px inside the frame) as seen through `g`, as segments.
    static func gridSegments(through g: Homography, width: Double, height: Double) -> [LineSegment] {
        var out: [LineSegment] = []
        func add(_ a: Vec2, _ b: Vec2) {
            let p = g.apply(a), q = g.apply(b)
            out.append(LineSegment(MaskPoint(p.x / width, p.y / height), MaskPoint(q.x / width, q.y / height), length: (q - p).length))
        }
        var x = 100.0
        while x < width { add(Vec2(x, 80), Vec2(x, height - 80)); x += 100 }
        var y = 100.0
        while y < height { add(Vec2(80, y), Vec2(width - 80, y)); y += 100 }
        return out
    }

    /// The largest tilt from upright among the nearly upright segments after `h`, and from level among the rest.
    static func worstTilts(_ segments: [LineSegment], after h: Homography, width: Double, height: Double) -> (upright: Double, level: Double) {
        var up = 0.0, flat = 0.0
        for s in segments {
            let (a, b) = s.ends(width: width, height: height)
            let p = h.apply(a), q = h.apply(b)
            let fromUpright = Upright.angleFromUpright(p, q)
            if abs(fromUpright) < 45 { up = max(up, abs(fromUpright)) } else { flat = max(flat, abs(Straighten.deviation(p, q))) }
        }
        return (up, flat)
    }

    func testUprightVerticalMakesConvergingLinesUpright() {
        let w = 600.0, h = 800.0
        let segments = Self.gridSegments(through: Self.cameraTurn(pitch: 15, width: w, height: h), width: w, height: h)
        let before = Self.worstTilts(segments, after: .identity, width: w, height: h)
        XCTAssertGreaterThan(before.upright, 3, "looking up: the uprights lean in")
        let fix = Upright.transform(mode: "vertical", segments: segments, width: w, height: h)
        let after = Self.worstTilts(segments, after: fix, width: w, height: h)
        XCTAssertLessThan(after.upright, 0.2)
        XCTAssertLessThan(after.level, 0.2)
        assertClose(fix.apply(Vec2(w / 2, h / 2)), Vec2(w / 2, h / 2), 1e-6)
        XCTAssertEqual(Upright.transform(mode: "off", segments: segments, width: w, height: h), .identity)
        XCTAssertEqual(Upright.transform(mode: "vertical", segments: [], width: w, height: h), .identity, "no lines: nothing to do")
    }

    func testUprightFullAlsoSquaresTheHorizontals() {
        let w = 800.0, h = 600.0
        let segments = Self.gridSegments(through: Self.cameraTurn(pitch: 10, yaw: 12, width: w, height: h), width: w, height: h)
        let vertical = Self.worstTilts(segments, after: Upright.transform(mode: "vertical", segments: segments, width: w, height: h),
                                       width: w, height: h)
        XCTAssertLessThan(vertical.upright, 0.3)
        XCTAssertGreaterThan(vertical.level, 2, "vertical leaves the receding horizontals")
        let full = Self.worstTilts(segments, after: Upright.transform(mode: "full", segments: segments, width: w, height: h), width: w, height: h)
        XCTAssertLessThan(full.upright, 0.3)
        XCTAssertLessThan(full.level, 0.3)
    }

    func testUprightLevelOnlyTurnsAndAutoStaysModerate() {
        let w = 600.0, h = 800.0
        let turned = Self.gridSegments(through: Self.cameraTurn(pitch: 0, roll: -4, width: w, height: h), width: w, height: h)
        let level = Upright.transform(mode: "level", segments: turned, width: w, height: h)
        XCTAssertTrue(level.isAffine)
        XCTAssertLessThan(Self.worstTilts(turned, after: level, width: w, height: h).level, 0.2)
        // A strong lean (35°) is too much for Auto: it only levels.
        let steep = Self.gridSegments(through: Self.cameraTurn(pitch: 35, width: w, height: h), width: w, height: h)
        XCTAssertTrue(Upright.transform(mode: "auto", segments: steep, width: w, height: h).isAffine)
        let mild = Self.gridSegments(through: Self.cameraTurn(pitch: 12, width: w, height: h), width: w, height: h)
        XCTAssertLessThan(Self.worstTilts(mild, after: Upright.transform(mode: "auto", segments: mild, width: w, height: h),
                                          width: w, height: h).upright, 0.2)
    }

    func testUprightFromADrawnPicture() {
        let w = 300, h = 400
        let g = Self.cameraTurn(pitch: 14, width: Double(w), height: Double(h))
        var lines: [(Vec2, Vec2)] = []
        for x in stride(from: -100.0, through: 400, by: 40) { lines.append((g.apply(Vec2(x, -200)), g.apply(Vec2(x, 600)))) }
        for y in stride(from: -100.0, through: 500, by: 40) { lines.append((g.apply(Vec2(-200, y)), g.apply(Vec2(500, y)))) }
        let pixels = Self.picture(width: w, height: h, lines: lines)
        let segments = LineDetector.detect(pixels, width: w, height: h)
        let fix = Upright.transform(mode: "vertical", segments: segments, width: Double(w), height: Double(h))
        XCTAssertLessThan(Self.worstTilts(Self.gridSegments(through: g, width: Double(w), height: Double(h)), after: fix,
                                          width: Double(w), height: Double(h)).upright, 0.7)
        // The plan crops inside the corrected photo.
        let plan = GeometryPlan(settings: GeometrySettings(upright: "vertical"), width: Double(w), height: Double(h), segments: segments)
        XCTAssertFalse(plan.isIdentity)
        for c in [Vec2(plan.crop.x, plan.crop.y), Vec2(plan.crop.maxX, plan.crop.maxY)] { XCTAssertTrue(Crop.inside(c, plan.photoCorners)) }
    }

    func testUprightNames() {
        XCTAssertEqual(control("upright").options.map(\.id), Upright.modes)
        XCTAssertEqual(parse("upright vertical"), [.set("upright", 3)])
        XCTAssertEqual(parse("auto upright"), [.set("upright", 1)], "the option before the name")
        XCTAssertEqual(parse("auto white balance"), [.set("whiteBalance", 1)])
        XCTAssertEqual(parse("patch tool"), [.run("patchTool")], "a name of its own wins")
        XCTAssertEqual(parse("auto"), [.run("auto")])
    }

    // MARK: - Names and actions

    func testCropNames() {
        XCTAssertEqual(parse("crop 16 by 9"), [.set("cropAspect", 10)])
        XCTAssertEqual(parse("crop 16:9"), [.set("cropAspect", 10)])
        XCTAssertEqual(parse("crop to 4 by 5"), [.set("cropAspect", 3)])
        XCTAssertEqual(parse("crop square"), [.set("cropAspect", 2)])
        XCTAssertEqual(parse("aspect ratio free"), [.set("cropAspect", 1)])
        XCTAssertEqual(parse("crop original"), [.set("cropAspect", 0)])
        XCTAssertEqual(parse("crop left 10"), [.set("cropLeft", 10)])
        XCTAssertEqual(parse("crop from top 5"), [.set("cropTop", 5)])
        XCTAssertEqual(parse("reset crop"), [.run("resetCrop")])
        XCTAssertEqual(parse("reset the crop"), [.run("resetCrop")])
        XCTAssertEqual(parse("reset crop left"), [.reset("cropLeft")], "a longer name after reset is the one reset")
        XCTAssertEqual(parse("reset contrast"), [.reset("contrast")])
        XCTAssertEqual(parse("crop tool"), [.run("cropTool")])
    }

    func testResetCropPutsTheBoxBack() {
        var interpreter = CommandInterpreter(registry: registry)
        var state = EditState()
        _ = interpreter.interpret("crop 16 by 9 crop left 10", state: &state)
        XCTAssertEqual(state.value(of: control("cropAspect")), 10)
        let outcomes = interpreter.interpret("reset crop", state: &state)
        XCTAssertEqual(outcomes.first, .ran(controlID: "resetCrop"))
        XCTAssertTrue(outcomes.contains(.changed(controlID: "cropLeft", from: 10, to: 0)))
        XCTAssertEqual(state.value(of: control("cropAspect")), 1, "free, the default")
    }

    func testPickingACropToolPutsMasksAndRetouchToolsAway() {
        var interpreter = CommandInterpreter(registry: registry)
        var state = EditState()
        _ = interpreter.interpret("brush mask", state: &state)
        XCTAssertNotNil(state.selectedMask)
        XCTAssertEqual(interpreter.interpret("crop tool", state: &state).first, .ran(controlID: "cropTool"))
        XCTAssertNil(state.selectedMask)
        _ = interpreter.interpret("heal", state: &state)
        _ = interpreter.interpret("crop tool", state: &state)
        XCTAssertNil(state.retouchTool)
    }

    func testResetAllClearsGeometryEdits() {
        var interpreter = CommandInterpreter(registry: registry)
        var state = EditState()
        state.geometry.quad = [MaskPoint(0, 0), MaskPoint(1, 0), MaskPoint(1, 1), MaskPoint(0, 1)]
        _ = interpreter.interpret("reset all", state: &state)
        XCTAssertEqual(state.geometry, GeometryEdits())
    }
}
