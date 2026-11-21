import CommandEngine
import PhotosUI
import SwiftUI

/// The Merge panel: pick several photos from the library (in order), then merge them (HDR, …) with
/// the panel's settings. The merged photo becomes the photo being edited; changing a merge's setting
/// afterwards merges again.
struct MergePanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>
    @State private var items: [PhotosPickerItem] = []

    private var controls: [Control] { model.registry.controls(inGroup: "merge") }

    var body: some View {
        DisclosureGroup(isExpanded: isOpen("merge")) {
            VStack(alignment: .leading, spacing: 6) {
                // Originals (.current), so HEIC brackets keep their full range.
                PhotosPicker(selection: $items, selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                    Label("Pick Photos to Merge", systemImage: "photo.stack")
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 10)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                if model.isMerging {
                    ProgressView("Merging…")
                        .padding(.horizontal, 10)
                }
                ForEach(controls.filter { $0.section == nil }) { ControlRow(model: model, control: $0) }
                ForEach(sections, id: \.self) { section in
                    DisclosureGroup(isExpanded: isOpen("merge/" + section)) {
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
            Text("Merge").font(.headline)
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

    private var status: String {
        switch model.mergePhotos.count {
        case 0: return "No photos picked yet. Pick them in the order to merge (darkest to brightest, left to right, …)."
        case 1: return "1 photo picked."
        default: return "\(model.mergePhotos.count) photos picked."
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
