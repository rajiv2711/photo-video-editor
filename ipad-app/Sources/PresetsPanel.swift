import CommandEngine
import PhotosUI
import SwiftUI

/// The Presets panel: save the edit as a preset (the Include switches choose its panels), apply the
/// user's presets or a built-in pack's with a tap, and set how strongly the last one shows (Preset
/// Amount). A long press on one of the user's presets renames or deletes it.
struct PresetsPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>
    @State private var newName = ""
    @State private var renaming: String?
    @State private var renamedTo = ""
    @State private var items: [PhotosPickerItem] = []

    private var controls: [Control] { model.registry.controls(inGroup: "presets") }

    /// The built-in packs in their file's order.
    private var packs: [String] {
        var out: [String] = []
        for preset in model.builtInPresets {
            if let pack = preset.pack, !out.contains(pack) { out.append(pack) }
        }
        return out
    }

    var body: some View {
        DisclosureGroup(isExpanded: isOpen("presets")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("New preset name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        model.apply([.run("savePreset", text: newName.trimmingCharacters(in: .whitespaces))])
                        newName = ""
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 10)
                if let amount = model.registry.control(id: Presets.amountID) {
                    ControlRow(model: model, control: amount)
                }
                if !model.userPresets.isEmpty {
                    Text("Your presets").font(.subheadline.weight(.semibold)).padding(.horizontal, 10)
                    ForEach(model.userPresets, id: \.name) { preset in
                        Button(preset.name) { model.apply([.run("applyPreset", text: preset.name)]) }
                            .contextMenu {
                                Button("Rename…") {
                                    renamedTo = preset.name
                                    renaming = preset.name
                                }
                                Button("Delete", role: .destructive) { model.apply([.run("deletePreset", text: preset.name)]) }
                            }
                            .padding(.horizontal, 10)
                    }
                }
                ForEach(packs, id: \.self) { pack in
                    DisclosureGroup(isExpanded: isOpen("presets/pack/" + pack)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.builtInPresets.filter { $0.pack == pack }, id: \.name) { preset in
                                Button(preset.name) { model.apply([.run("applyPreset", text: preset.name)]) }
                            }
                        }
                        .padding(.horizontal, 10)
                    } label: {
                        Text(pack).font(.subheadline.weight(.semibold))
                    }
                }
                // The rest of the panel's controls (copy, paste, …) and its sections (Include).
                ForEach(controls.filter { $0.section == nil && !Self.shownAbove.contains($0.id) }) { ControlRow(model: model, control: $0) }
                ForEach(sections, id: \.self) { section in
                    DisclosureGroup(isExpanded: isOpen("presets/" + section)) {
                        VStack(alignment: .leading, spacing: 6) {
                            if section == "Batch" {
                                // The photos to edit: the same picker as the Merge panel's.
                                PhotosPicker(selection: $items, selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                                    Label("Pick Photos", systemImage: "photo.stack")
                                }
                                .buttonStyle(.bordered)
                                .padding(.horizontal, 10)
                                Text(model.mergePhotos.isEmpty ? "No photos picked yet." : "\(model.mergePhotos.count) photos picked.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                            }
                            ForEach(controls.filter { $0.section == section }) { ControlRow(model: model, control: $0) }
                        }
                    } label: {
                        Text(section).font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Presets").font(.headline)
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
        .alert("Rename preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renamedTo)
            Button("Rename") {
                if let old = renaming { model.apply([.run("renamePreset", text: old + " to " + renamedTo)]) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    /// Controls the panel shows in its own way above.
    static let shownAbove: Set<String> = ["applyPreset", "savePreset", "renamePreset", "deletePreset", Presets.amountID]

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
