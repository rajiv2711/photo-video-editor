import CommandEngine
import SwiftUI

/// The History panel: every step of the edit, newest first (step 0 is the photo as opened); a tap goes
/// to that step, as "history 3" does. Steps undone stay listed, greyed, until a new change drops them.
struct HistoryPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>

    var body: some View {
        DisclosureGroup(isExpanded: isOpen("history")) {
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
            }
            .padding(.top, 6)
        } label: {
            Text("History").font(.headline)
        }
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
