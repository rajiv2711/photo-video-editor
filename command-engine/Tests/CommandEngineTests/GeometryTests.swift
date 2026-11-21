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
