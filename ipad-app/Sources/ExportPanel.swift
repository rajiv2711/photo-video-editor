import CommandEngine
import SwiftUI

/// The Export panel: export the photo (to Photos), and how: the file format (only those this iPad can
/// write), quality, size (long edge or percent), output sharpening, metadata, and how files are named.
/// The settings stay from photo to photo.
struct ExportPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>
    @State private var customName = ""
    @State private var presetName = ""

    private var controls: [Control] { model.registry.controls(inGroup: "export") }

    var body: some View {
        DisclosureGroup(isExpanded: isOpen("export")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { model.apply([.run("export")]) } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                        .buttonStyle(.borderedProminent)
                    Button { model.apply([.run("saveToFiles")]) } label: { Label("Files", systemImage: "folder") }
                    Button { model.apply([.run("share")]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .padding(.horizontal, 10)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                ForEach(sections, id: \.self) { section in
                    DisclosureGroup(isExpanded: isOpen("export/" + section)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(controls.filter { $0.section == section && !Self.shownApart.contains($0.id) }) { control in
                                if control.id == "exportFormat" {
                                    formatPicker(control)
                                } else {
                                    ControlRow(model: model, control: control)
                                }
                            }
                            if section == "Naming" { nameField }
                            if section == "Presets" { presetsSection }
                        }
                    } label: {
                        Text(section).font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Export").font(.headline)
        }
    }

    /// Controls shown in their own way (buttons above, the name field, the presets list).
    static let shownApart: Set<String> = ["export", "saveToFiles", "share", "exportName", "exportPreset", "saveExportPreset", "deleteExportPreset"]

    /// Export presets: tap one to use its settings (a long press deletes one of yours); save the panel's
    /// settings under a name.
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("New export preset", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.apply([.run("saveExportPreset", text: presetName.trimmingCharacters(in: .whitespaces))])
                    presetName = ""
                }
                .buttonStyle(.bordered)
            }
            ForEach(Array(model.exportPresets.enumerated()), id: \.offset) { item in
                Button(item.element.name + (item.offset < model.userExportPresetCount ? "" : " (built in)")) {
                    model.apply([.run("exportPreset", text: item.element.name)])
                }
                .contextMenu {
                    if item.offset < model.userExportPresetCount {
                        Button("Delete", role: .destructive) { model.apply([.run("deleteExportPreset", text: item.element.name)]) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    /// Only the formats ImageIO can write on this iPad.
    private func formatPicker(_ control: Control) -> some View {
        Picker(control.label, selection: Binding(
            get: { Int(model.value(of: control)) },
            set: { model.setFromSlider(control, to: Double($0)) }
        )) {
            ForEach(Array(control.options.enumerated()), id: \.offset) { item in
                if Exporter.isWritable(item.element.id) {
                    Text(item.element.label).tag(item.offset)
                }
            }
        }
        .padding(.horizontal, 10)
    }

    /// The words exported files are named after ("Custom and Number").
    private var nameField: some View {
        HStack {
            TextField(model.library.exportName.isEmpty ? "Custom name" : model.library.exportName, text: $customName)
                .textFieldStyle(.roundedBorder)
            Button("Set") {
                model.apply([.run("exportName", text: customName.trimmingCharacters(in: .whitespaces))])
                customName = ""
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 10)
    }

    /// What an export makes now: "JPEG 90 % · full size · screen sharpening · all metadata · IMG_0001.jpg".
    private var summary: String {
        let o = model.exportOptions
        var parts = [o.format.uppercased() + (["jpeg", "heic", "avif"].contains(o.format) ? " \(Int(o.quality * 100)) %" : "")]
        parts.append(o.longEdge > 0 ? "long edge ≤ \(Int(o.longEdge)) px" : o.percent < 100 ? "\(Int(o.percent)) %" : "full size")
        if o.sharpening != "off" { parts.append("\(o.sharpening) sharpening (\(o.sharpenAmount))") }
        parts.append(o.metadata == "all" ? (o.removeLocation ? "metadata without location" : "all metadata") : o.metadata == "none" ? "no metadata" : "copyright only")
        if !Exporter.isWritable(o.format) { parts.append("can't write \(o.format.uppercased()) here: JPEG") }
        return parts.joined(separator: " · ")
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
