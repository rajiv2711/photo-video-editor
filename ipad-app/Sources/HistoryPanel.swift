import CommandEngine
import SwiftUI

/// The History panel: every step of the edit, newest first (step 0 is the photo as opened); a tap goes
/// to that step, as "history 3" does. Steps undone stay listed, greyed, until a new change drops them.
struct HistoryPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>
    @State private var snapshotName = ""
    @State private var copyName = ""

    var body: some View {
        PanelGroup {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button("Undo") { model.apply([.run("undo")]) }.disabled(!model.canUndo)
                    Button("Redo") { model.apply([.run("redo")]) }.disabled(!model.canRedo)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 10)
                ForEach(Array(model.historySteps.enumerated()).reversed(), id: \.offset) { item in
                    stepRow(item.offset, item.element)
                }
                DisclosureGroup(isExpanded: isOpen("history/Snapshots")) {
                    snapshots
                } label: {
                    Text("Snapshots").font(.subheadline.weight(.semibold))
                }
                DisclosureGroup(isExpanded: isOpen("history/Virtual copies")) {
                    copies
                } label: {
                    Text("Virtual copies").font(.subheadline.weight(.semibold))
                }
            }
            .padding(.top, 6)
        } label: {
            Text("History").font(.headline)
        }
    }

    /// Named states of the edit: save the current one, tap one to come back to it (a long press deletes it).
    private var snapshots: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Snapshot name", text: $snapshotName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.apply([.run("saveSnapshot", text: snapshotName.trimmingCharacters(in: .whitespaces))])
                    snapshotName = ""
                }
                .buttonStyle(.bordered)
            }
            ForEach(Array(model.snapshots.enumerated()), id: \.offset) { item in
                Button("\(item.offset + 1). \(item.element.name)") {
                    model.apply([.run("restoreSnapshot", text: item.element.name)])
                }
                .contextMenu {
                    Button("Delete", role: .destructive) { model.apply([.run("deleteSnapshot", text: item.element.name)]) }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    /// The photo's edits: make a new one from this edit, tap one to edit it (a long press deletes it).
    private var copies: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Copy name", text: $copyName)
                    .textFieldStyle(.roundedBorder)
                Button("New Copy") {
                    model.apply([.run("virtualCopy", text: copyName.trimmingCharacters(in: .whitespaces))])
                    copyName = ""
                }
                .buttonStyle(.bordered)
            }
            ForEach(Array(model.copyNames.enumerated()), id: \.offset) { item in
                Button("\(item.offset + 1). \(item.element)") {
                    model.apply([.run("switchCopy", text: String(item.offset + 1))])
                }
                .fontWeight(item.offset == model.currentCopy ? .semibold : .regular)
                .contextMenu {
                    Button("Delete", role: .destructive) { model.apply([.run("deleteCopy", text: String(item.offset + 1))]) }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func stepRow(_ index: Int, _ step: EditHistory.Step) -> some View {
        let isCurrent = index == model.historyPosition
        return Button {
            model.apply([.run("history", value: Double(index))])
        } label: {
            HStack {
                Text("\(index)").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                Text(step.label).lineLimit(1)
                Spacer()
            }
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(index > model.historyPosition ? Color.secondary : Color.primary)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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
