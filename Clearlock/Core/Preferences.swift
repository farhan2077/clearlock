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

/// How big the unlock pill is (Settings › Lock Screen › Pill size). Regular by default. Each
/// size sets the pill and everything inside it; Tiny shows only the title, no helper line.
enum PillSize: String, CaseIterable, Identifiable {
    case regular, small, tiny
    var id: Self { self }

    static let defaultSize = PillSize.regular

    var title: String {
        switch self {
        case .regular: "Regular"
        case .small: "Small"
        case .tiny: "Tiny"
        }
    }

    /// Everything inside the pill that scales with it.
    struct Metrics {
        var size: NSSize
        var fingerprint: CGFloat
        var fingerprintBox: CGFloat
        var authControlSize: NSControl.ControlSize
        var lockSymbol: CGFloat
        var titleFont: CGFloat
        var helperFont: CGFloat
        var fieldWidth: CGFloat
        var fieldControlSize: NSControl.ControlSize
        var submitSymbol: CGFloat
        var detailHeight: CGFloat
        var leftInset: CGFloat
        var rightInset: CGFloat
        var spacing: CGFloat
        /// Only the title, no helper line: a double-click swaps the title for the password
        /// field, and feedback shows inside the empty field while it's open.
        var oneLine = false
    }

    var metrics: Metrics {
        switch self {
        case .regular:
            Metrics(size: NSSize(width: 330, height: 64), fingerprint: 36, fingerprintBox: 40, authControlSize: .large,
                    lockSymbol: 20, titleFont: 15, helperFont: 12, fieldWidth: 180, fieldControlSize: .regular,
                    submitSymbol: 17, detailHeight: 22, leftInset: 13, rightInset: 20, spacing: 10)
        case .small:
            Metrics(size: NSSize(width: 252, height: 46), fingerprint: 24, fingerprintBox: 26, authControlSize: .small,
                    lockSymbol: 14, titleFont: 12, helperFont: 10, fieldWidth: 135, fieldControlSize: .small,
                    submitSymbol: 13, detailHeight: 18, leftInset: 10, rightInset: 14, spacing: 7)
        case .tiny:
            // As wide as the title needs and no wider, so no empty glass is left after it. The
            // password field row is made exactly the title's width (`oneLineTextWidth`).
            Metrics(size: NSSize(width: 8 + 24 + 7 + Self.oneLineTextWidth + 13, height: 36), fingerprint: 22,
                    fingerprintBox: 24, authControlSize: .small, lockSymbol: 13, titleFont: 12, helperFont: 10,
                    fieldWidth: 0, fieldControlSize: .small, submitSymbol: 13, detailHeight: 22, leftInset: 8,
                    rightInset: 13, spacing: 7, oneLine: true)
        }
    }

    /// The one-line pill's text width: "Locked by Clearlock" in its title font. The title and
    /// the password field row both take exactly this width.
    static var oneLineTextWidth: CGFloat {
        ceil((UnlockPanel.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width)
    }

    /// Clearlock Dev's temporary size picker saved its choice under `debugPillSize`, with the
    /// sizes' working names. The release never had it. Maps a saved value to today's size.
    static let legacyDefaultsKey = "debugPillSize"
    static func fromLegacy(_ value: String?) -> PillSize? {
        switch value {
        case "slight": .regular
        case "between": .small
        case "tiny": .small
        case "oneLine": .tiny
        default: nil
        }
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
    /// How big the unlock pill is. Regular by default.
    var pillSize: PillSize { didSet { store.set(pillSize.rawValue, forKey: "pillSize") } }
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
        if d.object(forKey: "pillSize") == nil, let legacy = PillSize.fromLegacy(d.string(forKey: PillSize.legacyDefaultsKey)) {
            // Carry over Clearlock Dev's pick from the temporary size picker.
            pillSize = legacy
            d.set(legacy.rawValue, forKey: "pillSize")
        } else {
            pillSize = PillSize(rawValue: d.string(forKey: "pillSize") ?? "") ?? .defaultSize
        }
        d.removeObject(forKey: PillSize.legacyDefaultsKey)
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
