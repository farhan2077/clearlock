import AppKit
import Testing
@testable import Clearlock

/// Placement is a pure function of the chosen position and the screen, so no window is shown.
@Suite("Card position")
struct CardPositionTests {
    // A screen that doesn't start at the origin, like a second display, with a 37 pt menu bar.
    let area = NSRect(x: -1440, y: 200, width: 1440, height: 900)
    let topInset: CGFloat = 37

    private func frame(_ position: CardPosition) -> NSRect {
        UnlockPanel.frame(for: position, in: area, topInset: topInset)
    }

    @Test("Every position keeps the whole pill on screen, at full size, clear of the edges and the menu bar",
          arguments: CardPosition.allCases)
    func staysOnScreen(position: CardPosition) {
        let pill = frame(position)
        let safe = NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height - topInset)
            .insetBy(dx: UnlockPanel.edgeMargin, dy: UnlockPanel.edgeMargin)
        #expect(pill.size == UnlockPanel.pillSize)
        #expect(safe.contains(pill))
    }

    @Test("Each position puts the pill on its own side of the screen", arguments: CardPosition.allCases)
    func matchesItsName(position: CardPosition) {
        let pill = frame(position)
        switch position.column {
        case -1: #expect(pill.minX == area.minX + UnlockPanel.edgeMargin)
        case 1: #expect(pill.maxX == area.maxX - UnlockPanel.edgeMargin)
        default: #expect(abs(pill.midX - area.midX) <= 1)
        }
        switch position.row {
        case 1: #expect(pill.maxY == area.maxY - topInset - UnlockPanel.edgeMargin)
        case -1: #expect(pill.minY == area.minY + UnlockPanel.edgeMargin)
        default: #expect(pill.midY > area.midY && pill.midY < area.midY + area.height * 0.1)
        }
    }

    @Test("The nine positions are all different")
    func allDistinct() {
        let origins = Set(CardPosition.allCases.map { "\(frame($0).origin)" })
        #expect(origins.count == CardPosition.allCases.count)
        #expect(CardPosition.allCases.count == 9)
    }

    @Test("Center, the default, sits just above the middle of the screen, where it always was")
    func centerUnchanged() {
        let pill = frame(.center)
        #expect(abs(pill.midX - area.midX) <= 1)
        #expect(abs(pill.midY - (area.midY + area.height * 0.04)) <= 1)
    }

    @Test("The Settings grid matches the screen: top-left cell is Top Left, bottom-right is Bottom Right")
    func gridCorners() {
        #expect(CardPosition.at(gridRow: 0, gridColumn: 0) == .topLeft)
        #expect(CardPosition.at(gridRow: 0, gridColumn: 2) == .topRight)
        #expect(CardPosition.at(gridRow: 1, gridColumn: 1) == .center)
        #expect(CardPosition.at(gridRow: 2, gridColumn: 0) == .bottomLeft)
        #expect(CardPosition.at(gridRow: 2, gridColumn: 2) == .bottomRight)
    }

    @Test("Every grid cell picks a different position, all nine are reachable, and cells match where the pill lands",
          arguments: CardPosition.allCases)
    func gridCellPerPosition(position: CardPosition) {
        let row = 1 - position.row, column = position.column + 1
        #expect(CardPosition.at(gridRow: row, gridColumn: column) == position)
        let cells = (0..<3).flatMap { r in (0..<3).compactMap { c in CardPosition.at(gridRow: r, gridColumn: c) } }
        #expect(Set(cells).count == 9)
    }

    @Test("Cells outside the 3 × 3 grid pick nothing")
    func gridOutOfRange() {
        #expect(CardPosition.at(gridRow: 3, gridColumn: 0) == nil)
        #expect(CardPosition.at(gridRow: 0, gridColumn: -1) == nil)
    }

}
