import SwiftUI

/// Two tabs: General for everyday settings, Advanced for Accessibility, lid-closed mode and
/// Diagnostics.
/// Everything not listed is always on and isn't shown.
enum SettingsPane: CaseIterable {
    case general, advanced

    var title: String {
        switch self {
        case .general: "General"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .advanced: "gearshape.2"
        }
    }

    /// The sections on this tab, top to bottom. Each section is on exactly one tab.
    var sections: [SettingsSection] {
        switch self {
        case .general: [.general, .lockScreen, .updates]
        case .advanced: [.agents, .keepAwake, .diagnostics]
        }
    }
}

enum SettingsSection: CaseIterable, Identifiable {
    case general, lockScreen, agents, keepAwake, updates, diagnostics
    var id: Self { self }
}

// MARK: - Settings

struct SettingsView: View {
    @Bindable private var prefs = Preferences.shared
    private let permissions = PermissionCenter.shared
    private let hotKeys = HotKeyCenter.shared
    private let lid = LidSleepManager.shared
    private let updater = Updater.shared

    let pane: SettingsPane

    /// A grouped form sized to its content, so the window resizes per tab like System Settings.
    var body: some View {
        Form {
            ForEach(pane.sections) { section($0) }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func section(_ section: SettingsSection) -> some View {
        switch section {
        case .general:
            Section("Basics") {
                Toggle("Open at login", isOn: Binding(
                    get: { permissions.opensAtLogin || permissions.loginItemNeedsApproval },
                    set: { permissions.setOpensAtLogin($0) }))
                if permissions.loginItemNeedsApproval {
                    LabeledContent {
                        Button("Open Login Items…") { permissions.openLoginItemsSettings() }
                    } label: {
                        Label("Allow Clearlock in Login Items to finish", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("Lock shortcut") {
                    ShortcutRecorder(shortcut: $prefs.lockShortcut, defaultShortcut: .defaultLock,
                                     conflict: hotKeys.failures.contains(.lock))
                }
                LabeledContent("Lock color") {
                    TintPicker(selection: $prefs.tint)
                }
            }

        case .lockScreen:
            Section("Lock Screen") {
                Picker("Position", selection: $prefs.cardPosition) {
                    ForEach(CardPosition.allCases) { position in
                        Text(position.title).tag(position)
                        if position == .topRight || position == .right { Divider() }
                    }
                }
                LabeledContent {
                    HStack {
                        Slider(value: $prefs.dimLevel, in: 0...0.9)
                        Text(prefs.dimLevel, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 220)
                } label: {
                    Text("Dim screen")
                }
            }

        case .agents:
            Section {
                AccessibilityPermissionRow()
            } header: {
                Text("Agents")
            } footer: {
                Text("While locked, your keyboard, mouse and trackpad are blocked, but input from apps and scripts, such as AI agents, always goes through. With Accessibility, Clearlock also blocks system shortcuts, media keys and gestures.")
            }

        case .keepAwake:
            Section {
                Toggle(isOn: Binding(get: { prefs.keepAwakeWithLidClosed }, set: setLidMode)) {
                    Text("Keep running with the lid closed")
                    Text("While locked. Needs a one-time administrator approval. A closed Mac can get warm, so don’t put it in a bag.")
                }
                .disabled(lid.isBusy)
                let power = Self.lidPowerToggle(lidEnabled: prefs.keepAwakeWithLidClosed, onlyOnPower: prefs.lidOnlyOnPower)
                Toggle("Only when connected to power", isOn: Binding(
                    get: { power.isOn },
                    set: { prefs.lidOnlyOnPower = $0 }))
                    .disabled(!power.isEnabled)
                if let error = lid.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Keep Awake")
            } footer: {
                Text("Clearlock keeps your Mac and its display awake for as long as it’s running.")
            }

        case .updates:
            Section {
                LabeledContent {
                    actionButton
                } label: {
                    Text("Clearlock \(updater.currentVersion)")
                    statusView.font(.caption)
                }
                Toggle("Check for updates automatically", isOn: $prefs.autoCheckForUpdates)
            } header: {
                Text("Updates")
            }
            .disabled(!updater.isConfigured)

        case .diagnostics:
            Section("Diagnostics") {
                LabeledContent("Resource usage") {
                    Button("Open Diagnostics…") { WindowCoordinator.shared.showDiagnostics() }
                }
            }
        }
    }

    /// "Only when connected to power" is shown off and can't be changed while lid-closed
    /// mode is off. The saved choice is kept for when it's turned on again.
    static func lidPowerToggle(lidEnabled: Bool, onlyOnPower: Bool) -> (isOn: Bool, isEnabled: Bool) {
        (lidEnabled && onlyOnPower, lidEnabled)
    }

    private func setLidMode(_ enabled: Bool) {
        guard enabled, !lid.isHelperInstalled else {
            prefs.keepAwakeWithLidClosed = enabled
            return
        }
        Task {
            if await lid.installHelper() { prefs.keepAwakeWithLidClosed = true }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch updater.state {
        case .idle:
            Label("Not checked yet", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("Clearlock is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let release):
            Label("Version \(release.version) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .downloading(let release):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading \(release.version)…") }
        case .ready(let release, _):
            Label("Version \(release.version) is ready to install", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…") }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch updater.state {
        case .available(let release):
            Button("Download and Install") {
                Task {
                    await updater.download(release)
                    updater.installAndRelaunch()
                }
            }
            .buttonStyle(.borderedProminent)
        case .ready:
            Button("Restart to Update") { updater.installAndRelaunch() }
                .buttonStyle(.borderedProminent)
                .disabled(LockController.shared.isLocked)
        case .checking, .downloading, .installing:
            EmptyView()
        default:
            Button("Check Now") { Task { await updater.check(userInitiated: true) } }
        }
    }
}

/// Color swatches like the accent color picker in System Settings.
struct TintPicker: View {
    @Binding var selection: LockTint

    var body: some View {
        HStack(spacing: 8) {
            ForEach(LockTint.allCases) { tint in
                Button {
                    selection = tint
                } label: {
                    Circle()
                        .fill(Color(nsColor: tint.color).gradient)
                        .frame(width: 18, height: 18)
                        .overlay {
                            if selection == tint {
                                Circle().fill(.white).frame(width: 6, height: 6)
                            }
                        }
                        .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(tint.title)
                .accessibilityLabel(tint.title)
                .accessibilityAddTraits(selection == tint ? .isSelected : [])
            }
        }
    }
}

/// Live Accessibility status. Updates the moment the switch is flipped in System Settings.
struct AccessibilityPermissionRow: View {
    private let permissions = PermissionCenter.shared

    var body: some View {
        let trusted = permissions.isAccessibilityTrusted
        HStack(spacing: 12) {
            Image(systemName: "accessibility")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.blue.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility")
                Text(trusted ? "Allowed. The Shield is available." : "Turn on Clearlock in Privacy & Security › Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if trusted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow…") { permissions.requestAccessibility() }
            }
        }
        .animation(.snappy, value: trusted)
    }
}
