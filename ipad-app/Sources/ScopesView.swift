import CommandEngine
import SwiftUI

/// The View panel's scopes over the photo's corner: the histogram (luma in grey, red, green and blue
/// as lines), darkest on the left.
struct ScopesView: View {
    let scopes: EditorModel.ScopeReadings

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let h = scopes.histogram {
                Canvas { context, size in
                    context.fill(Self.area(h.luma, size), with: .color(.white.opacity(0.35)))
                    for (bins, color) in [(h.red, Color.red), (h.green, Color.green), (h.blue, Color.blue)] {
                        context.stroke(Self.line(bins, size), with: .color(color.opacity(0.9)), lineWidth: 1)
                    }
                }
                .frame(width: 256, height: 100)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Histogram")
            }
        }
        .allowsHitTesting(false)
    }

    /// The bars as a filled shape along the bottom.
    static func area(_ heights: [Double], _ size: CGSize) -> Path {
        var path = Path()
        guard heights.count > 1 else { return path }
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, h) in heights.enumerated() {
            path.addLine(to: CGPoint(x: CGFloat(i) / CGFloat(heights.count - 1) * size.width, y: (1 - CGFloat(h)) * size.height))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    /// The bars' tops as a line.
    static func line(_ heights: [Double], _ size: CGSize) -> Path {
        var path = Path()
        for (i, h) in heights.enumerated() {
            let p = CGPoint(x: CGFloat(i) / CGFloat(max(1, heights.count - 1)) * size.width, y: (1 - CGFloat(h)) * size.height)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}
