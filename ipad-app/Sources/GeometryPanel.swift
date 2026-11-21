import CommandEngine
import SwiftUI

/// The Geometry panel: crop, straighten, rotate and flip, upright, transform, … as fold-out sections
/// of plain controls (sliders, switches, menus, buttons). While a touch tool is in use (the crop
/// tool, …) it says what to do on the photo and offers Done.
struct GeometryPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>

    private var controls: [Control] { model.registry.controls(inGroup: "geometry") }

    var body: some View {
        DisclosureGroup(isExpanded: isOpen("geometry")) {
            VStack(alignment: .leading, spacing: 6) {
                if let tool = model.geometryTool {
                    if let hint = EditorModel.geometryHints[tool] {
                        Text(hint.prefix(1).uppercased() + String(hint.dropFirst()) + ".")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                    }
                    Button("Done") { model.apply([.run("maskDone")]) }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal, 10)
                }
                ForEach(controls.filter { $0.section == nil }) { ControlRow(model: model, control: $0) }
                ForEach(sections, id: \.self) { section in
                    DisclosureGroup(isExpanded: isOpen("geometry/" + section)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(controls.filter { $0.section == section }) { ControlRow(model: model, control: $0) }
                        }
                    } label: {
                        Text(section).font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Geometry").font(.headline)
        }
    }

    private var sections: [String] {
        var out: [String] = []
        for control in controls {
            if let section = control.section, !out.contains(section) { out.append(section) }
        }
        return out
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

/// Touches on the photo for the Geometry panel's tool. The crop tool shows the whole frame with the
/// crop box on it: drag a corner or an edge, or inside the box to move it. The straighten tool takes
/// a line drawn along something that should be level or upright.
struct GeometryCanvas: View {
    @ObservedObject var model: EditorModel
    let tool: String
    /// A line being drawn (straighten), on screen.
    @State private var line: (CGPoint, CGPoint)?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear.contentShape(Rectangle())
                if tool == "crop" { cropBox(geo.size).allowsHitTesting(false) }
                if tool == "guides" {
                    // The guides drawn so far, where they now show.
                    Path { path in
                        for (a, b) in model.shownGuides {
                            path.move(to: CGPoint(x: CGFloat(a.x) * geo.size.width, y: CGFloat(a.y) * geo.size.height))
                            path.addLine(to: CGPoint(x: CGFloat(b.x) * geo.size.width, y: CGFloat(b.y) * geo.size.height))
                        }
                    }
                    .stroke(Color.cyan, lineWidth: 2)
                    .allowsHitTesting(false)
                }
                if let line {
                    Path { path in
                        path.move(to: line.0)
                        path.addLine(to: line.1)
                    }
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if Self.lines.contains(tool) {
                            line = (drag.startLocation, drag.location)
                        } else {
                            model.draw([MaskCanvas.unit(drag.startLocation, in: geo.size), MaskCanvas.unit(drag.location, in: geo.size)],
                                       finished: false)
                        }
                    }
                    .onEnded { drag in
                        line = nil
                        model.draw([MaskCanvas.unit(drag.startLocation, in: geo.size), MaskCanvas.unit(drag.location, in: geo.size)])
                    }
            )
        }
    }

    /// Tools that take a line drawn on the photo (handed over when the finger lifts).
    static let lines: Set<String> = ["straighten", "guides"]

    /// The crop box: the outside dimmed, thirds lines inside, handles at the corners.
    private func cropBox(_ size: CGSize) -> some View {
        let b = model.cropBox
        let rect = CGRect(x: CGFloat(b.x0) * size.width, y: CGFloat(b.y0) * size.height,
                          width: CGFloat(b.x1 - b.x0) * size.width, height: CGFloat(b.y1 - b.y0) * size.height)
        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            Path { path in
                for i in 1...2 {
                    let f = CGFloat(i) / 3
                    path.move(to: CGPoint(x: rect.minX + f * rect.width, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + f * rect.width, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + f * rect.height))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f * rect.height))
                }
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            ForEach(0..<4, id: \.self) { i in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .position(x: i == 0 || i == 3 ? rect.minX : rect.maxX, y: i < 2 ? rect.minY : rect.maxY)
            }
        }
    }
}

/// Draws outlines made on the photo itself (mask handles, retouch spots) over the edited preview,
/// which may be cropped or turned: the content is laid out at the photo's own shape and projected
/// onto the preview with the geometry's transform (`size` is the photo's size on screen).
struct SourceSpace<Content: View>: View {
    @ObservedObject var model: EditorModel
    let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geo in
            let layout = model.sourceLayout(shown: geo.size)
            content(layout.size)
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                .projectionEffect(layout.projection)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}
