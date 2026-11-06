import AppKit
import Observation
import Security

/// Self-updates from GitHub Releases without third-party frameworks.
///
/// A release must contain a zipped `Clearlock.app`. Before installing, the
/// downloaded app must satisfy the running app's own designated code requirement,
/// i.e. it must be signed with the same certificate. A tampered or foreign build
/// is rejected even if the download source were compromised.
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let asset: URL
        let size: Int
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case ready(Release, URL)
        case installing
        case failed(String)
    }

    private(set) var state = State.idle

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// "owner/repo" from Info.plist. Updates are disabled until it's filled in.
    let repository: String? = Updater.repository(from: Bundle.main.object(forInfoDictionaryKey: "AWLUpdateRepository"))

    /// "owner/repo", or nil while the placeholder or a malformed value is still in Info.plist.
    static func repository(from value: Any?) -> String? {
        guard let repo = (value as? String)?.trimmingCharacters(in: .whitespaces),
              repo.split(separator: "/").count == 2, !repo.contains("OWNER") else { return nil }
        return repo
    }

    var isConfigured: Bool { repository != nil }

    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?

    private init() {}

    // MARK: Scheduling

    /// Lets the system pick an energy-efficient moment roughly once a day.
    func scheduleBackgroundChecks() {
        guard isConfigured else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.farhan2077.clearlock.update-check")
        scheduler.repeats = true
        scheduler.interval = 24 * 60 * 60
        scheduler.tolerance = 4 * 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            Task { @MainActor in
                if Preferences.shared.autoCheckForUpdates { await Updater.shared.check(userInitiated: false) }
                completion(.finished)
            }
        }
        self.scheduler = scheduler

        let last = Preferences.shared.lastUpdateCheck ?? .distantPast
        if Preferences.shared.autoCheckForUpdates, Date().timeIntervalSince(last) > 24 * 60 * 60 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                await check(userInitiated: false)
            }
        }
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard let repository else {
            state = .failed("Updates aren’t configured for this build.")
            return
        }
        if case .downloading = state { return }
        if case .ready = state, !userInitiated { return }
        state = .checking

        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Clearlock/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("No releases found for \(repository).")
            }
            let check = try Self.evaluate(data, currentVersion: currentVersion)
            Preferences.shared.lastUpdateCheck = Date()
            guard case .available(let release) = check else {
                state = .upToDate
                return
            }
            state = .available(release)
            ActivityLog.shared.add("arrow.down.circle", "Update \(release.version) available")
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: Download and verify

    func download(_ release: Release) async {
        state = .downloading(release)
        do {
            let app = Bundle.main.bundleURL
            // A replacement directory on the same volume lets the final swap be an atomic rename.
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: app, create: true)
            let (downloaded, _) = try await URLSession.shared.download(from: release.asset)
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)

            let extracted = work.appendingPathComponent("extracted")
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError("The download doesn’t contain an app.")
            }
            try verify(newApp, expectedVersion: release.version)
            state = .ready(release, newApp)
            ActivityLog.shared.add("checkmark.seal", "Update \(release.version) downloaded and verified")
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    enum ReleaseCheck: Equatable {
        case upToDate
        case available(Release)
    }

    /// Reads GitHub's "latest release" response: a newer version (tag "v1.2.0" or "1.2.0")
    /// with a zipped Clearlock.app attached is an update; anything else isn't.
    static func evaluate(_ data: Data, currentVersion: String) throws -> ReleaseCheck {
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard isVersion(version, newerThan: currentVersion) else { return .upToDate }
        guard let asset = payload.assets.first(where: { $0.name.hasSuffix(".zip") && $0.name.localizedCaseInsensitiveContains("clearlock") }) else {
            throw UpdateError("Version \(version) has no downloadable app.")
        }
        return .available(Release(version: version, notes: payload.body ?? "", page: payload.htmlURL,
                                  asset: asset.downloadURL, size: asset.size))
    }

    func verify(_ app: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The downloaded app isn’t Clearlock.")
        }
        var selfCode: SecCode?
        var requirement: SecRequirement?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              let selfStatic = Self.staticCode(for: selfCode),
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError("Couldn’t read code signatures.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw UpdateError("The update isn’t signed with Clearlock’s certificate, so it wasn’t installed.")
        }
    }

    private static func staticCode(for code: SecCode) -> SecStaticCode? {
        var result: SecStaticCode?
        return SecCodeCopyStaticCode(code, [], &result) == errSecSuccess ? result : nil
    }

    // MARK: Install

    func installAndRelaunch() {
        guard case .ready(_, let newApp) = state else { return }
        guard Self.canInstall(isLocked: LockController.shared.isLocked) else { return }
        state = .installing
        do {
            let current = Bundle.main.bundleURL
            _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
            let script = "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"\(current.path)\""
            let relauncher = Process()
            relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
            relauncher.arguments = ["-c", script]
            try relauncher.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Couldn’t replace the app. Make sure Clearlock is in a folder you can write to, like Applications.")
        }
    }

    /// Installing quits and relaunches Clearlock, so it never happens while locked.
    static func canInstall(isLocked: Bool) -> Bool { !isLocked }

    // MARK: Menu command

    /// "Check for Updates…" with native alerts for each outcome.
    func checkInteractively() async {
        await check(userInitiated: true)
        NSApp.activate()
        let alert = NSAlert()
        switch state {
        case .upToDate:
            alert.messageText = "You’re up to date"
            alert.informativeText = "Clearlock \(currentVersion) is the latest version."
            alert.runModal()
        case .available(let release), .ready(let release, _):
            alert.messageText = "Clearlock \(release.version) is available"
            let notes = release.notes.count > 600 ? String(release.notes.prefix(600)) + "…" : release.notes
            alert.informativeText = "You have \(currentVersion).\n\n\(notes)"
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Release Notes")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if case .available = state { await download(release) }
                if case .ready = state { installAndRelaunch() } else { await checkFailedAlert() }
            case .alertThirdButtonReturn:
                NSWorkspace.shared.open(release.page)
            default:
                break
            }
        case .failed:
            await checkFailedAlert()
        default:
            break
        }
    }

    private func checkFailedAlert() async {
        guard case .failed(let message) = state else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t update Clearlock"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Helpers

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        if status != 0 { throw UpdateError("Couldn’t unpack the update.") }
    }

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let downloadURL: URL
            enum CodingKeys: String, CodingKey { case name, size, downloadURL = "browser_download_url" }
        }
        let tagName: String
        let body: String?
        let htmlURL: URL
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", body, htmlURL = "html_url", assets }
    }
}
