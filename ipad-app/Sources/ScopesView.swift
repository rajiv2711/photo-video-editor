import CommandEngine
import SwiftUI

/// The View panel's scopes over the photo's corner: the histogram (luma in grey, red, green and blue
/// as lines), darkest on the left; the vectorscope (colours by hue around the circle and saturation
/// out from its middle, red up-left, blue right, with the skin-tone line); how much is clipped while the
/// clipping warning is on.
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
            if let v = scopes.vectorscope {
                Canvas { context, size in
                    let side = min(size.width, size.height)
                    let circle = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
                    context.stroke(Path(ellipseIn: circle), with: .color(.white.opacity(0.4)), lineWidth: 1)
                    let centre = CGPoint(x: circle.midX, y: circle.midY)
                    var cross = Path()
                    cross.move(to: CGPoint(x: circle.minX, y: centre.y))
                    cross.addLine(to: CGPoint(x: circle.maxX, y: centre.y))
                    cross.move(to: CGPoint(x: centre.x, y: circle.minY))
                    cross.addLine(to: CGPoint(x: centre.x, y: circle.maxY))
                    context.stroke(cross, with: .color(.white.opacity(0.2)), lineWidth: 1)
                    // The skin-tone line, from the middle out.
                    let a = Scopes.skinToneAngle * .pi / 180
                    var skin = Path()
                    skin.move(to: centre)
                    skin.addLine(to: CGPoint(x: centre.x + side / 2 * cos(a), y: centre.y - side / 2 * sin(a)))
                    context.stroke(skin, with: .color(.orange.opacity(0.8)), lineWidth: 1)
                    let cell = side / CGFloat(v.size)
                    for (i, level) in v.cells.enumerated() where level > 0 {
                        let rect = CGRect(x: circle.minX + CGFloat(i % v.size) * cell, y: circle.minY + CGFloat(i / v.size) * cell,
                                          width: cell, height: cell)
                        context.fill(Path(rect), with: .color(.white.opacity(0.15 + 0.85 * level)))
                    }
                }
                .frame(width: 160, height: 160)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Vectorscope")
            }
            ForEach(scopes.samples, id: \.self) { line in
                Text(line)
                    .font(.caption.monospacedDigit())
                    .padding(6)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
            }
            if let clip = scopes.clipping {
                Text(String(format: "Highlights clipped %.1f %% · shadows %.1f %%", 100 * clip.highlights, 100 * clip.shadows))
                    .font(.caption.monospacedDigit())
                    .padding(6)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
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
