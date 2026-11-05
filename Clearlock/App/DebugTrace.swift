#if DEBUG
import AppKit
import os

/// Debug builds log window and activation events, to diagnose focus problems from real
/// clicks: `log show --predicate 'subsystem == "com.farhan2077.clearlock" AND category == "trace"'`.
enum DebugTrace {
    private static let logger = Logger(subsystem: "com.farhan2077.clearlock", category: "trace")
    private static var observers: [NSObjectProtocol] = []

    static func note(_ message: String) {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
        logger.notice("\(message, privacy: .public) [active=\(NSApp.isActive) front=\(front, privacy: .public)]")
    }

    static func start() {
        let app = NotificationCenter.default
        observers.append(app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { note("app became active") }
        })
        observers.append(app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { note("app resigned active") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let name = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "-"
            MainActor.assumeIsolated { note("macOS activated \(name)") }
        })
        for (name, label) in [(NSWindow.didBecomeKeyNotification, "became key"), (NSWindow.didResignKeyNotification, "resigned key"),
                              (NSWindow.didChangeOcclusionStateNotification, "occlusion changed"), (NSWindow.willCloseNotification, "will close")] {
            observers.append(app.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let window = n.object as? NSWindow, window.styleMask.contains(.titled) else { return }
                let title = window.title
                MainActor.assumeIsolated {
                    note("window '\(title)' \(label) visible=\(window.isVisible) onScreen=\(window.occlusionState.contains(.visible))")
                }
            })
        }
        note("trace started")
    }
}
#endif
