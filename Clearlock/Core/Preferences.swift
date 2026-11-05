import AppKit
import Observation

enum LockTint: String, CaseIterable, Identifiable {
    case orange, red, pink, purple, blue, green, graphite
    var id: Self { self }
    var title: String { rawValue.capitalized }

    var color: NSColor {
        switch self {
        case .orange: .systemOrange
        case .red: .systemRed
        case .pink: .systemPink
        case .purple: .systemPurple
        case .blue: .systemBlue
        case .green: .systemGreen
        case .graphite: .systemGray
        }
    }
}

/// Where the unlock pill sits on the lock screen. Center by default.
enum CardPosition: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var id: Self { self }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .top: "Top"
        case .topRight: "Top Right"
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .bottomLeft: "Bottom Left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom Right"
        }
    }

    /// -1 (left/bottom), 0 (middle) or 1 (right/top) on each axis.
    var column: Int { [.topLeft, .left, .bottomLeft].contains(self) ? -1 : [.topRight, .right, .bottomRight].contains(self) ? 1 : 0 }
    var row: Int { [.topLeft, .top, .topRight].contains(self) ? 1 : [.bottomLeft, .bottom, .bottomRight].contains(self) ? -1 : 0 }

    /// The position for a cell of the 3 × 3 grid in Settings, counting rows from the top and
    /// columns from the left (0, 1, 2), so the grid matches where the pill lands on screen.
    static func at(gridRow: Int, gridColumn: Int) -> CardPosition? {
        allCases.first { 1 - $0.row == gridRow && $0.column + 1 == gridColumn }
    }
}

/// All user-configurable settings, persisted in UserDefaults. Observable so both
/// SwiftUI panes and AppKit controllers react to changes immediately.
@Observable
final class Preferences {
    static let shared = Preferences(store: .standard)

    @ObservationIgnored private let store: UserDefaults

    var hasCompletedOnboarding: Bool { didSet { store.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    // General
    var lockShortcut: Shortcut? { didSet { save(lockShortcut, "lockShortcut") } }
    var tint: LockTint { didSet { store.set(tint.rawValue, forKey: "tint") } }
    var keepAwakeWithLidClosed: Bool { didSet { store.set(keepAwakeWithLidClosed, forKey: "keepAwakeWithLidClosed") } }
    var lidOnlyOnPower: Bool { didSet { store.set(lidOnlyOnPower, forKey: "lidOnlyOnPower") } }
    var autoCheckForUpdates: Bool { didSet { store.set(autoCheckForUpdates, forKey: "autoCheckForUpdates") } }
    var lastUpdateCheck: Date? { didSet { store.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }

    // Lock
    /// Where the unlock pill sits on the screen.
    var cardPosition: CardPosition { didSet { store.set(cardPosition.rawValue, forKey: "cardPosition") } }
    /// How dark the screen gets while locked, 0 (not at all) to 0.9. 30 % by default.
    var dimLevel: Double { didSet { store.set(dimLevel, forKey: "dimLevel") } }

    /// Tests pass their own UserDefaults suite; the app uses `shared`.
    init(store d: UserDefaults) {
        store = d
        d.register(defaults: [
            "dimLevel": Self.defaultDimLevel,
            "lidOnlyOnPower": true,
            "autoCheckForUpdates": true,
        ])
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
        lockShortcut = Self.load("lockShortcut", d) ?? (d.object(forKey: "lockShortcut") == nil ? .defaultLock : nil)
        tint = LockTint(rawValue: d.string(forKey: "tint") ?? "") ?? .orange
        keepAwakeWithLidClosed = d.bool(forKey: "keepAwakeWithLidClosed")
        lidOnlyOnPower = d.bool(forKey: "lidOnlyOnPower")
        autoCheckForUpdates = d.bool(forKey: "autoCheckForUpdates")
        lastUpdateCheck = d.object(forKey: "lastUpdateCheck") as? Date
        cardPosition = CardPosition(rawValue: d.string(forKey: "cardPosition") ?? "") ?? .center
        dimLevel = min(max(d.double(forKey: "dimLevel"), 0), 0.9)
    }

    static let defaultDimLevel = 0.3

    /// A cleared shortcut is stored as empty data so it isn't replaced by the default.
    private func save(_ shortcut: Shortcut?, _ key: String) {
        store.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    private static func load(_ key: String, _ d: UserDefaults) -> Shortcut? {
        guard let data = d.data(forKey: key), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
}

/// Re-runs `apply` whenever any observable property it reads changes.
func observeChanges(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking(apply) {
        Task { @MainActor in observeChanges(apply) }
    }
}
