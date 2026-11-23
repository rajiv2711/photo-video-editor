import CommandEngine
import PhotosUI
import SwiftUI

/// The Layers panel: a menu to make a layer, the stack (top first, as in Photoshop: tap a layer to
/// select it, the eye hides it), and for the selected layer its settings and actions (move it up or
/// down the stack, copy, delete). Touches on the picture move the selected layer.
struct LayersPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>
    @State private var items: [PhotosPickerItem] = []

    private var controls: [Control] { model.registry.controls(inGroup: "layers") }

    /// Actions that make a layer (Place Photo, …).
    private var makers: [Control] { controls.filter { $0.kind == .action && $0.layer != nil && $0.section == nil } }

    /// Sections shown for the whole panel, not for one layer.
    static let panelSections: Set<String> = ["Collage", "Watermark"]

    /// The panel's own sections that have controls, in order.
    private var shownSections: [String] {
        Self.panelSections.sorted().filter { section in controls.contains { $0.section == section } }
    }

    var body: some View {
        PanelGroup {
            VStack(alignment: .leading, spacing: 10) {
                ActionTiles {
                    Menu {
                        ForEach(makers) { maker in makerButton(maker) }
                    } label: {
                        ActionTile("New Layer", "plus.square.on.square")
                    }
                    // The photos picked go into photo layers (and merges): the same picker as the Merge panel's.
                    PhotosPicker(selection: $items, selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                        ActionTile("Pick Photos", "photo.on.rectangle")
                    }
                }
                .padding(.horizontal, 10)
                ForEach(Array(model.state.layers.indices.reversed()), id: \.self) { index in
                    row(index)
                }
                if let l = model.state.selectedLayer, model.state.layers.indices.contains(l) {
                    selected(model.state.layers[l])
                }
                // The whole panel's sections: the collage (the photo as opened and the photos picked), the watermark.
                ForEach(shownSections, id: \.self) { section in
                    DisclosureGroup(isExpanded: isOpen("layers/" + section)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(controls.filter { $0.section == section }) { control in
                                if control.id == "watermarkText" {
                                    TextField("Watermark text", text: Binding(get: { model.state.watermarkText },
                                                                              set: { model.setWatermarkText($0) }))
                                        .textFieldStyle(.roundedBorder)
                                        .padding(.horizontal, 10)
                                } else if control.kind == .action {
                                    makerButton(control).buttonStyle(.bordered).padding(.horizontal, 10)
                                } else {
                                    ControlRow(model: model, control: control)
                                }
                            }
                        }
                    } label: {
                        Text(section).font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            PanelTitle(model: model, title: "Layers", group: "layers")
        }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            Task { @MainActor in
                var files: [Data] = []
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self) { files.append(data) }
                }
                model.pickForMerge(files: files)
            }
        }
    }

    /// A maker with options (a sticker, a collage layout) is a menu of them.
    @ViewBuilder
    private func makerButton(_ maker: Control) -> some View {
        if maker.options.isEmpty {
            Button(maker.label) { model.apply([.run(maker.id)]) }
        } else {
            Menu(maker.label) {
                ForEach(Array(maker.options.enumerated()), id: \.offset) { item in
                    Button(item.element.label) { model.apply([.run(maker.id, value: Double(item.offset))]) }
                }
            }
        }
    }

    /// One layer in the stack: the eye shows or hides it, a tap selects it (again: deselects it).
    private func row(_ index: Int) -> some View {
        let layer = model.state.layers[index]
        let isSelected = model.state.selectedLayer == index
        return HStack {
            Button {
                model.toggleLayerVisible(index)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            Button {
                model.apply([.set(EditState.layerSelectorID, isSelected ? 0 : Double(index + 1))])
            } label: {
                Text("\(index + 1). \(model.layerName(index))")
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
            Button(role: .destructive) {
                model.apply([.run("deleteLayer", value: Double(index + 1))])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The selected layer: its settings (those every layer has and those of its kind), by section,
    /// and the actions on it.
    @ViewBuilder
    private func selected(_ layer: Layer) -> some View {
        let rows = controls.filter {
            $0.scope == "layer" && ($0.layer == nil || $0.layer == layer.kind) && $0.id != "layerVisible"
                && !Self.panelSections.contains($0.section ?? "")
        }
        if layer.kind == "text" {
            // The words, typed (or said: “edit text …”).
            TextField("Text", text: Binding(get: { layer.text }, set: { model.setLayerText($0) }))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
        }
        ForEach(rows.filter { $0.section == nil }) { ControlRow(model: model, control: $0) }
        ForEach(sections(of: rows), id: \.self) { section in
            DisclosureGroup(isExpanded: isOpen("layers/" + section)) {
                VStack(alignment: .leading, spacing: 6) {
                    if section == "Transform", let position = model.registry.control(id: "layerPosition") {
                        makerButton(position).padding(.horizontal, 10)
                    }
                    ForEach(rows.filter { $0.section == section }) { ControlRow(model: model, control: $0) }
                }
            } label: {
                Text(section).font(.subheadline.weight(.semibold))
            }
        }
        if layer.kind == "paint" {
            // The paint brush's settings for new strokes.
            ForEach(["brushColor", "paintSize"].compactMap { model.registry.control(id: $0) }) { ControlRow(model: model, control: $0) }
        }
        if layer.kind == "adjustment" {
            // Its own sliders (those a mask can hold), on everything below it; colour grading folded away.
            let local = model.registry.controls.filter(\.local)
            Text("Adjustments").font(.subheadline.weight(.semibold))
            ForEach(local.filter { $0.section != "Color grading" }) { ControlRow(model: model, control: $0) }
        }
        DisclosureGroup(isExpanded: isOpen("layers/Mask")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let mask = model.registry.control(id: "layerMask") { makerButton(mask) }
                    Button("Invert") { model.apply([.run("invertLayerMask")]) }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 10)
                if model.layerMode == "mask" {
                    // Painting the mask uses the mask brush's settings.
                    ForEach(["brushSize", "brushFeather", "brushErase"].compactMap { model.registry.control(id: $0) }) {
                        ControlRow(model: model, control: $0)
                    }
                }
            }
        } label: {
            Text(layer.mask == nil ? "Mask" : "Mask (on)").font(.subheadline.weight(.semibold))
        }
        ActionTiles {
            Button { model.apply([.run("moveLayerUp")]) } label: { ActionTile("Up", "arrow.up") }
            Button { model.apply([.run("moveLayerDown")]) } label: { ActionTile("Down", "arrow.down") }
            Button { model.apply([.run("duplicateLayer")]) } label: { ActionTile("Duplicate", "plus.square.on.square") }
        }
        .padding(.horizontal, 10)
    }

    private func sections(of controls: [Control]) -> [String] {
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

/// Touches on the picture for the selected layer: a drag moves it; with the paint brush or the mask
/// brush, strokes (finger or Pencil, with its pressure and tilt) paint on it or its mask; with the pen,
/// taps add corners and drags curved points. Its outline shows where it is.
struct LayerCanvas: View {
    @ObservedObject var model: EditorModel
    let tool: String
    @State private var points: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear.contentShape(Rectangle())
                outline(geo.size)
                // The pen's points so far (the first one closes the path).
                ForEach(Array(model.penPoints.enumerated()), id: \.offset) { item in
                    Circle()
                        .fill(item.offset == 0 ? Color.accentColor : Color.white)
                        .frame(width: 9, height: 9)
                        .position(x: CGFloat(item.element.x) * geo.size.width, y: CGFloat(item.element.y) * geo.size.height)
                        .allowsHitTesting(false)
                }
                if Self.painted.contains(tool) {
                    Path { path in path.addLines(points) }
                        .stroke((tool == "mask" ? Color.red : Color.white).opacity(0.5),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        .allowsHitTesting(false)
                    PencilTouches(
                        onMove: { points = $0 },
                        onEnd: { stroke, pressure, tilt in
                            model.draw(stroke.map { MaskCanvas.unit($0, in: geo.size) }, pressure: pressure, tilt: tilt)
                            points = []
                        }
                    )
                }
            }
            .gesture(drag(geo.size), including: Self.painted.contains(tool) ? .subviews : .all)
        }
        .onChange(of: tool) { _, _ in points = [] }
    }

    /// Tools that paint strokes with finger or Pencil (the mask brush, the paint brush).
    static let painted: Set<String> = ["mask", "paint"]

    /// A drag moves the layer (the Pencil strokes view takes the touches while painting).
    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                model.draw([MaskCanvas.unit(drag.startLocation, in: size), MaskCanvas.unit(drag.location, in: size)], finished: false)
            }
            .onEnded { drag in
                model.draw([MaskCanvas.unit(drag.startLocation, in: size), MaskCanvas.unit(drag.location, in: size)])
            }
    }

    /// The selected layer's box, dashed.
    private func outline(_ size: CGSize) -> some View {
        let corners = model.selectedLayerOutline.map { CGPoint(x: CGFloat($0.x) * size.width, y: CGFloat($0.y) * size.height) }
        return Path { path in
            guard corners.count == 4 else { return }
            path.addLines(corners)
            path.closeSubpath()
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        .allowsHitTesting(false)
    }
}
