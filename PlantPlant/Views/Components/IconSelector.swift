import SwiftUI

/// A "level" selector rendered as a row of identical icons. Tapping an icon selects that level:
/// every icon from the left up to (and including) the tapped one is drawn filled, the rest as
/// outlines — like a rating control. Used in the editor for sunlight (suns) and how dry the
/// soil should get before watering (drops). The options must be ordered lowest → highest.
struct LevelSelector<Option: Identifiable & Equatable>: View {
    let options: [Option]
    @Binding var selection: Option
    let filledSymbol: String
    let outlineSymbol: String
    var tint: Color = .accentColor

    var body: some View {
        let selectedIndex = options.firstIndex(of: selection) ?? 0
        HStack(spacing: 16) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let filled = index <= selectedIndex
                Button {
                    selection = option
                } label: {
                    Image(systemName: filled ? filledSymbol : outlineSymbol)
                        .font(.title2)
                        .foregroundStyle(filled ? tint : Color.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Level \(index + 1)")
                .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// Read-only counterpart to `LevelSelector`: shows `level` of `total` icons filled. Used on the
/// detail page to display sunlight / soil-dryness as icons rather than text.
struct LevelIndicator: View {
    /// 1-based number of filled icons.
    let level: Int
    let total: Int
    let filledSymbol: String
    let outlineSymbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<total, id: \.self) { index in
                Image(systemName: index < level ? filledSymbol : outlineSymbol)
                    // Fixed-width, centered slots so the suns line up in columns with the drops
                    // even though the two symbols have different intrinsic widths.
                    .frame(width: 22)
                    .foregroundStyle(index < level ? tint : Color.secondary.opacity(0.5))
            }
        }
    }
}
