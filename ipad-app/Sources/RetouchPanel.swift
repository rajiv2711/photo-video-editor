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
            Text("Retouch").font(.headline)
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
                outlines(geo.size)
                Path { path in path.addLines(points) }
                    .stroke(Color.white.opacity(0.45),
                            style: StrokeStyle(lineWidth: brushWidth(model.registry.control(id: "brushSize").map { model.value(of: $0) } ?? 10,
                                                                     geo.size),
                                               lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                PencilTouches(
                    onMove: { points = $0 },
                    onEnd: { stroke, pressure in
                        model.draw(stroke.map { MaskCanvas.unit($0, in: geo.size) }, pressure: pressure)
                        points = []
                    }
                )
            }
        }
        .onChange(of: tool) { _, _ in points = [] }
    }

    /// The spots made so far: a ring for a tap, the stroke's band for a stroke.
    private func outlines(_ size: CGSize) -> some View {
        ZStack {
            ForEach(Array(model.state.retouches.enumerated()), id: \.offset) { item in
                let step = item.element
                let selected = model.state.selectedRetouch == item.offset
                let width = brushWidth(step.size, size)
                let line = step.points.map { CGPoint(x: CGFloat($0.x) * size.width, y: CGFloat($0.y) * size.height) }
                if line.count == 1, let centre = line.first {
                    Circle()
                        .stroke(Color.white.opacity(selected ? 0.95 : 0.5), lineWidth: selected ? 2 : 1)
                        .frame(width: width, height: width)
                        .position(centre)
                } else {
                    Path { path in path.addLines(line) }
                        .stroke(Color.white.opacity(selected ? 0.35 : 0.15),
                                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// A brush diameter (% of the photo's long side) on screen.
    private func brushWidth(_ percent: Double, _ size: CGSize) -> CGFloat {
        max(2, CGFloat(percent / 100) * max(size.width, size.height))
    }
}

/// Finger and Pencil strokes with the Pencil's pressure (SwiftUI's drag gesture doesn't report it).
/// `onMove` gets the stroke so far, `onEnd` the whole stroke and the pressure at each point (0…1;
/// fingers press fully).
struct PencilTouches: UIViewRepresentable {
    var onMove: ([CGPoint]) -> Void
    var onEnd: ([CGPoint], [Double]) -> Void

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
        var onEnd: (([CGPoint], [Double]) -> Void)?
        private var points: [CGPoint] = []
        private var pressures: [Double] = []

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            points = []
            pressures = []
            add(touches, event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            add(touches, event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            add(touches, event)
            onEnd?(points, pressures)
            points = []
            pressures = []
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
            }
            onMove?(points)
        }

        /// Pencil pressure 0…1 (a firm press reaches 1); fingers count as full pressure.
        static func pressure(of touch: UITouch) -> Double {
            guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
            return min(1, max(0.05, Double(touch.force / (touch.maximumPossibleForce * 0.6))))
        }
    }
}
