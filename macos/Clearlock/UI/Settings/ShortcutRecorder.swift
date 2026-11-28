import AppKit
import SwiftUI

/// Click to record a global shortcut. Hotkeys are suspended while recording so the
/// current shortcut can be pressed again without triggering it.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    /// The shortcut a reset brings back. A reset button shows whenever the shortcut differs.
    var defaultShortcut: Shortcut? = nil
    var conflict = false

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(label)
                    .monospacedDigit()
                    .frame(minWidth: 120)
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
            }
            .help(isRecording ? "Type a shortcut with ⌘, ⌥ or ⌃" : "Click to record a new shortcut")

            if shortcut != nil && !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
                .accessibilityLabel("Clear shortcut")
            }

            if let defaultShortcut, !isRecording, Self.showsReset(current: shortcut, default: defaultShortcut) {
                Button {
                    shortcut = defaultShortcut
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reset to \(defaultShortcut.displayString)")
                .accessibilityLabel("Reset shortcut to \(defaultShortcut.displayString)")
            }

            if conflict && !isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another app already uses this shortcut.")
            }
        }
        .onDisappear(perform: stop)
    }

    /// A reset is offered when the shortcut was changed or cleared, never when it's the default.
    static func showsReset(current: Shortcut?, default defaultShortcut: Shortcut) -> Bool {
        current != defaultShortcut
    }

    private var label: String {
        if isRecording { return rejected ? "Add ⌘, ⌥ or ⌃" : "Type Shortcut…" }
        return shortcut?.displayString ?? "Record Shortcut"
    }

    private func start() {
        isRecording = true
        rejected = false
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stop()
                return nil
            }
            if let recorded = Shortcut(event: event) {
                shortcut = recorded
                stop()
            } else {
                rejected = true
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        AppDelegate.registerHotKeys()
    }
}
