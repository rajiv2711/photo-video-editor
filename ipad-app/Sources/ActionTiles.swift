import SwiftUI

/// Buttons (and menus) as equal tiles, an icon above a short name, in a grid that wraps onto more rows
/// when the panel is narrow (296 points in landscape: four tiles a row), so a name never breaks letter by
/// letter. Tiles are at least 54 points wide and 50 tall: easy to tap.
///
///     ActionTiles {
///         Button { model.apply([.run("export")]) } label: { ActionTile("Photos", "photo.on.rectangle", prominent: true) }
///         Menu { … } label: { ActionTile("Stars", "star") }
///     }
struct ActionTiles<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 6)], spacing: 6) {
            content
        }
        .buttonStyle(.plain)
    }
}

/// One tile of ActionTiles: the icon above the name (one line, a little smaller when long). `prominent`:
/// filled (the main action, or a filter in use); `tint`: the colour (red to delete).
struct ActionTile: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, _ symbol: String, prominent: Bool = false, tint: Color = .accentColor) {
        self.title = title
        self.symbol = symbol
        self.prominent = prominent
        self.tint = tint
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(height: 22)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 50)
        .foregroundStyle(prominent ? Color.white : tint)
        .background(prominent ? tint : tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .combine)
    }
}
