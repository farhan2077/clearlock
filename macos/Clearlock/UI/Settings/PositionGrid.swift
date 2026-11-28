import SwiftUI

/// Picks where the unlock pill sits: a small picture of a screen split into a 3 × 3 grid.
/// Each cell is a position; the chosen one shows a little pill in the lock color.
struct PositionGrid: View {
    @Binding var selection: CardPosition
    var tint: Color

    @State private var hovered: CardPosition?

    private static let screenSize = CGSize(width: 132, height: 84)
    private static let inset: CGFloat = 4

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        if let position = CardPosition.at(gridRow: row, gridColumn: column) {
                            cell(position)
                        }
                    }
                }
            }
        }
        .padding(Self.inset)
        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.background.secondary))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Position")
    }

    private func cell(_ position: CardPosition) -> some View {
        let isSelected = position == selection
        let isHovered = position == hovered
        return Button {
            selection = position
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered && !isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                if isSelected {
                    Capsule().fill(tint).frame(width: 22, height: 7)
                } else {
                    Circle().fill(.tertiary).frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? position : (hovered == position ? nil : hovered) }
        .help(position.title)
        .accessibilityLabel(position.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
