import CommandEngine
import SwiftUI
import UIKit

/// The Retouch panel: a button per tool (the one in use is filled), the brush and the tool's
/// settings, the list of spots (tap one to select it, then change its opacity or delete it) and the
/// panel's other switches. Every button has a spoken name too ("remove brush", "spot 2", "undo last spot").
struct RetouchPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>

    private var controls: [Control] { model.registry.controls(inGroup: "retouch") }
    private var tools: [Control] { controls.filter { $0.tool != nil } }

    /// Controls shown in their own place (tool buttons, the spot list): the rest are listed at the end.
    private var placed: Set<String> {
        var ids: Set<String> = [EditState.retouchToolID, EditState.spotSelectorID, "spotOpacity"]
        for tool in RetouchTools.ids { ids.formUnion(RetouchTools.settings(for: tool)) }
        return ids
    }

    var body: some View {
        DisclosureGroup(isExpanded: isOpen("retouch")) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(tools) { tool in
                        toolButton(tool)
                    }
                }
                .padding(.horizontal, 10)

                if let tool = model.state.retouchTool {
                    if let hint = EditorModel.toolHints[tool] {
                        Text(hint.prefix(1).uppercased() + String(hint.dropFirst()) + ".")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                    }
                    // The brush (shared with the mask brush) and this tool's settings for new spots.
                    ForEach(["brushSize", "brushFeather"] + RetouchTools.settings(for: tool).filter { $0 != "spotOpacity" },
                            id: \.self) { id in
                        if let control = model.registry.control(id: id) { ControlRow(model: model, control: control) }
                    }
                }

                spots

                ForEach(controls.filter { $0.kind != .action && !placed.contains($0.id) }) { control in
                    ControlRow(model: model, control: control)
                }
            }
            .padding(.top, 6)
        } label: {
            PanelTitle(model: model, title: "Retouch", group: "retouch")
        }
    }

    @ViewBuilder
    private func toolButton(_ tool: Control) -> some View {
        if model.state.retouchTool == tool.tool {
            Button(tool.label) { model.apply([.set(EditState.retouchToolID, 0)]) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(tool.label) { model.runAction(tool) }
                .buttonStyle(.bordered)
        }
    }

    /// The spots in the order they were made; the selected one's opacity and delete button.
    @ViewBuilder
    private var spots: some View {
        if !model.state.retouches.isEmpty {
            Text("Spots").font(.subheadline.weight(.semibold))
            ForEach(Array(model.state.retouches.enumerated()), id: \.offset) { item in
                let isSelected = model.state.selectedRetouch == item.offset
                HStack {
                    Button {
                        model.apply([.set(EditState.spotSelectorID, isSelected ? 0 : Double(item.offset + 1))])
                    } label: {
                        Text("\(item.offset + 1). \(model.label(ofTool: item.element.tool))")
                            .fontWeight(isSelected ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(role: .destructive) {
                        model.apply([.run("deleteSpot", value: Double(item.offset + 1))])
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
            if let opacity = model.registry.control(id: "spotOpacity"), model.state.selectedRetouch != nil {
                ControlRow(model: model, control: opacity)
            }
            if let s = model.state.selectedRetouch, RetouchTools.copying.contains(model.state.retouches[s].tool),
               let source = model.registry.control(id: "spotSource") {
                Button("Choose source…") { model.runAction(source) }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                    .padding(.horizontal, 10)
            }
            Button("Undo last spot") { model.apply([.run("undoSpot")]) }
                .buttonStyle(.bordered)
                .font(.footnote)
                .padding(.horizontal, 10)
        }
    }

    private func isOpen(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { open in
                if open { expanded.insert(key) } else { expanded.remove(key) }
            }
        )
    }
}

/// Touches on the photo for the retouch tool in use (finger or Pencil, with the Pencil's pressure):
/// the stroke is drawn as it goes and becomes a spot when the finger lifts. The spots made so far
/// show as outlines, the selected one brighter.
struct RetouchCanvasView: View {
    @ObservedObject var model: EditorModel
    let tool: String
    @State private var points: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Spots are drawn on the photo's own shape and follow its crop and turns.
                SourceSpace(model: model) { size in outlines(size) }
                Path { path in path.addLines(points) }
                    .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: liveWidth(geo.size), lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                PencilTouches(
                    onMove: { points = $0 },
                    onEnd: { stroke, pressure, _ in
                        model.draw(stroke.map { MaskCanvas.unit($0, in: geo.size) }, pressure: pressure)
                        points = []
                    }
                )
            }
        }
        .onChange(of: tool) { _, _ in points = [] }
    }

    /// The spots made so far: a ring for a tap, the stroke's band for a stroke; the selected one's
    /// source (copying tools) dashed, with a line to it.
    private func outlines(_ size: CGSize) -> some View {
        ZStack {
            ForEach(Array(model.state.retouches.enumerated()).filter { RetouchTools.spots.contains($0.element.tool) }, id: \.offset) { item in
                let selected = model.state.selectedRetouch == item.offset
                let closed = RetouchTools.outlined.contains(item.element.tool)
                outline(item.element.points, width: brushWidth(item.element.size, size), size: size, selected: selected, dashed: false,
                        closed: closed, eye: RetouchTools.eyes.contains(item.element.tool))
                if selected, let offset = item.element.offset {
                    let moved = item.element.points.map { MaskPoint($0.x + offset.x, $0.y + offset.y) }
                    outline(moved, width: brushWidth(item.element.size, size), size: size, selected: true, dashed: true, closed: closed)
                    Path { path in
                        let c = item.element.centre
                        path.move(to: CGPoint(x: CGFloat(c.x) * size.width, y: CGFloat(c.y) * size.height))
                        path.addLine(to: CGPoint(x: CGFloat(c.x + offset.x) * size.width, y: CGFloat(c.y + offset.y) * size.height))
                    }
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// One spot's outline: a ring for a tap, a band for a stroke, the line around a Patch or Move area.
    @ViewBuilder
    private func outline(_ points: [MaskPoint], width: CGFloat, size: CGSize, selected: Bool, dashed: Bool, closed: Bool,
                         eye: Bool = false) -> some View {
        let line = points.map { CGPoint(x: CGFloat($0.x) * size.width, y: CGFloat($0.y) * size.height) }
        if eye, line.count > 1 {
            // An eye drawn around: the circle around the line.
            let xs = line.map(\.x), ys = line.map(\.y)
            let side = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
            Circle()
                .stroke(Color.white.opacity(selected ? 0.95 : 0.5), lineWidth: selected ? 2 : 1)
                .frame(width: side, height: side)
                .position(x: (xs.max()! + xs.min()!) / 2, y: (ys.max()! + ys.min()!) / 2)
        } else if closed {
            Path { path in
                path.addLines(line)
                path.closeSubpath()
            }
            .stroke(Color.white.opacity(selected ? 0.95 : 0.5), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: dashed ? [5, 4] : []))
        } else if line.count == 1, let centre = line.first {
            Circle()
                .stroke(Color.white.opacity(selected ? 0.95 : 0.5),
                        style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: dashed ? [5, 4] : []))
                .frame(width: width, height: width)
                .position(centre)
        } else {
            Path { path in path.addLines(line) }
                .stroke(Color.white.opacity(dashed ? 0.6 : selected ? 0.35 : 0.15),
                        style: StrokeStyle(lineWidth: dashed ? 1.5 : width, lineCap: .round, lineJoin: .round, dash: dashed ? [5, 4] : []))
        }
    }

    /// The stroke being drawn: as wide as the brush, or a thin line for an outline (or around an eye).
    private func liveWidth(_ size: CGSize) -> CGFloat {
        if RetouchTools.outlined.contains(tool) || RetouchTools.eyes.contains(tool) { return 2 }
        return brushWidth(model.registry.control(id: "brushSize").map { model.value(of: $0) } ?? 10, size)
    }

    /// A brush diameter (% of the photo's long side) on screen.
    private func brushWidth(_ percent: Double, _ size: CGSize) -> CGFloat {
        max(2, CGFloat(percent / 100) * max(size.width, size.height))
    }
}

/// Finger and Pencil strokes with the Pencil's pressure and tilt (SwiftUI's drag gesture doesn't report
/// them). `onMove` gets the stroke so far, `onEnd` the whole stroke, the pressure at each point (0…1;
/// fingers press fully) and the tilt (0 upright … 1 lying flat; fingers stand upright).
struct PencilTouches: UIViewRepresentable {
    var onMove: ([CGPoint]) -> Void
    var onEnd: ([CGPoint], [Double], [Double]) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.onMove = onMove
        view.onEnd = onEnd
    }

    final class TouchView: UIView {
        var onMove: (([CGPoint]) -> Void)?
        var onEnd: (([CGPoint], [Double], [Double]) -> Void)?
        private var points: [CGPoint] = []
        private var pressures: [Double] = []
        private var tilts: [Double] = []

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            points = []
            pressures = []
            tilts = []
            add(touches, event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            add(touches, event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            add(touches, event)
            onEnd?(points, pressures, tilts)
            points = []
            pressures = []
            tilts = []
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            points = []
            pressures = []
            onMove?([])
        }

        /// Every point the touch passed (the Pencil reports more than one per screen frame).
        private func add(_ touches: Set<UITouch>, _ event: UIEvent?) {
            guard let touch = touches.first else { return }
            for t in event?.coalescedTouches(for: touch) ?? [touch] {
                let p = t.location(in: self)
                if let last = points.last, last == p { continue }
                points.append(p)
                pressures.append(Self.pressure(of: t))
                tilts.append(Self.tilt(of: t))
            }
            onMove?(points)
        }

        /// How far the Pencil leans over: 0 upright … 1 lying flat; fingers stand upright.
        static func tilt(of touch: UITouch) -> Double {
            guard touch.type == .pencil else { return 0 }
            return min(1, max(0, 1 - Double(touch.altitudeAngle) / (Double.pi / 2)))
        }

        /// Pencil pressure 0…1 (a firm press reaches 1); fingers count as full pressure.
        static func pressure(of touch: UITouch) -> Double {
            guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
            return min(1, max(0.05, Double(touch.force / (touch.maximumPossibleForce * 0.6))))
        }
    }
}
