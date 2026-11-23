import SwiftUI

/// The bar above the panel while something takes the touches on the photo (a mask, a layer, a retouch
/// tool, a geometry tool, a picker or Targeted Adjustment): what is being edited, and Done (as saying
/// “done”). It stays put while the panel scrolls, in portrait and landscape.
struct EditingBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let editing = model.editing {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: editing.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(editing.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Text("Changes are saved as you go")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                    Button { model.endEditing() } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(Color.accentColor, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Done: " + editing.title)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            }
        }
    }
}
