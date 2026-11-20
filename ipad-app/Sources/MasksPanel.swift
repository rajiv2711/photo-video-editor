import CommandEngine
import SwiftUI

/// The Masks panel: a menu to make a mask, the list of masks, and for the selected mask its parts,
/// their settings, the mask's settings and its local sliders. While a mask is selected the other
/// panels are hidden (as in Lightroom): sliders change the mask. "Done" goes back to them.
struct MasksPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>

    private var controls: [Control] { model.registry.controls(inGroup: "masks") }

    /// Actions that make a mask part: Brush, Linear Gradient, …
    private var makers: [Control] { controls.filter { $0.kind == .action && $0.component != nil } }

    var body: some View {
        DisclosureGroup(isExpanded: isOpen("masks")) {
            VStack(alignment: .leading, spacing: 10) {
                Menu {
                    ForEach(makers) { maker in
                        Button(maker.label) { model.apply([.run(maker.id)]) }
                    }
                } label: {
                    Label("New mask", systemImage: "plus.circle")
                }
                .padding(.horizontal, 10)

                ForEach(Array(model.state.masks.enumerated()), id: \.offset) { item in
                    maskRow(item.offset, item.element)
                }

                // Shows the selected mask as a red tint (preview only, never saved).
                if let overlay = model.registry.control(id: "maskOverlay"), !model.state.masks.isEmpty {
                    ControlRow(model: model, control: overlay)
                }

                if let m = model.state.selectedMask, model.state.masks.indices.contains(m) {
                    selected(model.state.masks[m])
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Masks").font(.headline)
        }
    }

    /// One mask in the list: tap selects it (again: back to the global sliders).
    private func maskRow(_ index: Int, _ mask: Mask) -> some View {
        let isSelected = model.state.selectedMask == index
        return HStack {
            Button {
                model.selectMask(isSelected ? nil : index)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mask \(index + 1)").fontWeight(isSelected ? .semibold : .regular)
                    Text(mask.components.map { model.label(ofPart: $0.kind) }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button(role: .destructive) {
                model.apply([.run("deleteMask", value: Double(index + 1))])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The selected mask: its parts (tap one to edit it), menus to add, subtract or intersect a
    /// part, the selected part's settings, the brush, the mask's settings and the local sliders.
    @ViewBuilder
    private func selected(_ mask: Mask) -> some View {
        Text("Components").font(.subheadline.weight(.semibold))
        ForEach(Array(mask.components.enumerated()), id: \.offset) { item in
            let isSelected = item.offset == mask.selectedComponent
            Button {
                model.apply([.set(EditState.componentSelectorID, Double(item.offset + 1))])
            } label: {
                HStack {
                    Text("\(item.offset + 1). \(model.label(ofPart: item.element.kind))")
                    Spacer()
                    Text(item.element.mode.rawValue + (item.element.inverted ? ", inverted" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fontWeight(isSelected ? .semibold : .regular)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        HStack {
            ForEach(MaskComponent.Mode.allCases, id: \.self) { mode in
                Menu(mode.rawValue.capitalized) {
                    ForEach(makers) { maker in
                        Button(maker.label) { model.apply([.run(maker.id, value: nil, mode: mode.rawValue)]) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        HStack {
            Button("Duplicate mask") { model.apply([.run("duplicateMask")]) }
            Button("Delete component", role: .destructive) { model.apply([.run("deleteComponent")]) }
        }
        .buttonStyle(.bordered)
        .font(.footnote)
        .padding(.horizontal, 10)
        if let part = mask.component {
            if let hint = EditorModel.hints[part.kind] {
                Text(hint.prefix(1).uppercased() + hint.dropFirst() + ".")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            let partRows = controls.filter { $0.scope == "component" && ($0.component == part.kind || $0.component == nil) }
            ForEach(partRows) { ControlRow(model: model, control: $0) }
            if ["brush", "quickSelect"].contains(part.kind) {
                section("Brush", rows: controls.filter { $0.section == "Brush" })
            }
        }
        let maskRows = controls.filter { $0.scope == "mask" && $0.kind != .action && $0.id != EditState.componentSelectorID }
        if !maskRows.isEmpty {
            section("Mask", rows: maskRows)
        }
        // The mask's own sliders (Mask Amount scales them all); colour grading folded away.
        let local = model.registry.controls.filter(\.local)
        Text("Local adjustments").font(.subheadline.weight(.semibold))
        ForEach(local.filter { $0.section != "Color grading" }) { ControlRow(model: model, control: $0) }
        section("Color grading", rows: local.filter { $0.section == "Color grading" })
        Button("Done") { model.apply([.run("maskDone")]) }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 10)
    }

    private func section(_ title: String, rows: [Control]) -> some View {
        DisclosureGroup(isExpanded: isOpen("masks/" + title)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { ControlRow(model: model, control: $0) }
            }
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
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

/// Touches on the photo for the selected mask part (finger or Pencil): brush strokes, drawn as a
/// line while painting and handed to the mask when the stroke ends; gradients follow the drag.
/// Handles show where a gradient is.
struct MaskCanvas: View {
    @ObservedObject var model: EditorModel
    let tool: String
    @State private var points: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear.contentShape(Rectangle())
                handles(geo.size)
                Path { path in
                    path.addLines(points)
                }
                .stroke(Color.red.opacity(0.5), style: StrokeStyle(lineWidth: brushWidth(geo.size), lineCap: .round, lineJoin: .round))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if Self.painted.contains(tool) {
                            points.append(drag.location)
                        } else {
                            model.draw([Self.unit(drag.startLocation, in: geo.size), Self.unit(drag.location, in: geo.size)],
                                       finished: false)
                        }
                    }
                    .onEnded { drag in
                        if Self.painted.contains(tool) {
                            model.draw(points.map { Self.unit($0, in: geo.size) })
                        } else {
                            model.draw([Self.unit(drag.startLocation, in: geo.size), Self.unit(drag.location, in: geo.size)])
                        }
                        points = []
                    }
            )
        }
    }

    /// Parts painted with the brush (the others follow the drag as it goes).
    static let painted: Set<String> = ["brush", "quickSelect"]

    /// Lines of the selected gradient: where it is full, its middle, where it ends.
    @ViewBuilder
    private func handles(_ size: CGSize) -> some View {
        if tool == "linear", let part = model.selectedPart {
            let ends = MaskGeometry.linearHandles(angle: part.values["linearAngle"] ?? 0, position: part.values["linearPosition"] ?? 25,
                                                  width: part.values["linearWidth"] ?? 50,
                                                  width: Double(size.width), height: Double(size.height))
            let a = CGPoint(x: CGFloat(ends.start.x) * size.width, y: CGFloat(ends.start.y) * size.height)
            let b = CGPoint(x: CGFloat(ends.end.x) * size.width, y: CGFloat(ends.end.y) * size.height)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            ZStack {
                Self.across(a, b, size).stroke(Color.white, lineWidth: 1.5)
                Self.across(mid, b, size, through: mid).stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                Self.across(b, a, size).stroke(Color.white.opacity(0.6), lineWidth: 1)
                Circle().fill(Color.white).frame(width: 10, height: 10).position(mid)
            }
            .allowsHitTesting(false)
        } else if let point = model.selectedPart?.point {
            // A tapped sample (colour range, magic wand).
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 18, height: 18)
                .position(x: CGFloat(point.x) * size.width, y: CGFloat(point.y) * size.height)
                .allowsHitTesting(false)
        } else if tool == "radial", let part = model.selectedPart {
            // The ellipse's edge, on screen (the photo fills the canvas, so its pixels scale evenly).
            let v = part.values
            let radii = MaskGeometry.radialRadii(size: v["radialSize"] ?? 60, aspect: v["radialAspect"] ?? 0,
                                                 width: Double(size.width), height: Double(size.height))
            let centre = CGPoint(x: CGFloat((v["radialX"] ?? 50) / 100) * size.width, y: CGFloat((v["radialY"] ?? 50) / 100) * size.height)
            ZStack {
                Ellipse()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: CGFloat(2 * radii.x), height: CGFloat(2 * radii.y))
                    .rotationEffect(.degrees(v["radialAngle"] ?? 0))
                    .position(centre)
                Circle().fill(Color.white).frame(width: 10, height: 10).position(centre)
            }
            .allowsHitTesting(false)
        }
    }

    /// A line across the photo through `p` (or `through`), at right angles to the direction p → q.
    private static func across(_ p: CGPoint, _ q: CGPoint, _ size: CGSize, through: CGPoint? = nil) -> Path {
        let c = through ?? p
        var dx = q.x - p.x, dy = q.y - p.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        dx /= length
        dy /= length
        let reach = size.width + size.height
        return Path { path in
            path.move(to: CGPoint(x: c.x - dy * reach, y: c.y + dx * reach))
            path.addLine(to: CGPoint(x: c.x + dy * reach, y: c.y - dx * reach))
        }
    }

    /// The brush's width on screen (Brush Size is a share of the photo's long side).
    private func brushWidth(_ size: CGSize) -> CGFloat {
        guard Self.painted.contains(tool) else { return 0 }
        let percent = model.registry.control(id: "brushSize").map { model.value(of: $0) } ?? 10
        return max(2, CGFloat(percent / 100) * max(size.width, size.height))
    }

    /// A point on the photo as x, y from the top-left, 0…1.
    static func unit(_ p: CGPoint, in size: CGSize) -> MaskPoint {
        MaskPoint(Double(min(max(p.x / max(size.width, 1), 0), 1)), Double(min(max(p.y / max(size.height, 1), 0), 1)))
    }
}
