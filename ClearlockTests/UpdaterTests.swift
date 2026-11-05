import Foundation
import Testing
@testable import Clearlock

@Suite("In-app updates")
struct UpdaterTests {
    private func release(tag: String, assets: [String]) -> Data {
        let list = assets.map {
            #"{"name":"\#($0)","size":1000,"browser_download_url":"https://example.com/\#($0)"}"#
        }.joined(separator: ",")
        return Data(#"{"tag_name":"\#(tag)","body":"Notes","html_url":"https://example.com/r","assets":[\#(list)]}"#.utf8)
    }

    @Test("Versions compare numerically, not alphabetically")
    func numericVersionComparison() {
        #expect(Updater.isVersion("1.10.0", newerThan: "1.9.0"))
        #expect(Updater.isVersion("2.0", newerThan: "1.9.9"))
        #expect(!Updater.isVersion("1.0.0", newerThan: "1.0.0"))
        #expect(!Updater.isVersion("1.2.0", newerThan: "1.10.0"))
    }

    @Test("A newer tagged release with the app zip is offered, with the 'v' prefix dropped")
    func newerReleaseIsAvailable() throws {
        let check = try Updater.evaluate(release(tag: "v1.2.0", assets: ["Source.zip", "Clearlock-1.2.0.zip"]),
                                         currentVersion: "1.0.0")
        guard case .available(let update) = check else {
            Issue.record("Expected an update, got \(check)")
            return
        }
        #expect(update.version == "1.2.0")
        #expect(update.asset.lastPathComponent == "Clearlock-1.2.0.zip")
    }

    @Test("The app zip is found whatever its capitalization")
    func assetNameIgnoresCase() throws {
        for name in ["Clearlock-1.2.0.zip", "ClearLock-1.2.0.zip", "clearlock-1.2.0.zip"] {
            #expect(try Updater.evaluate(release(tag: "v1.2.0", assets: [name]), currentVersion: "1.0.0") != .upToDate)
        }
    }

    @Test("The same or an older release is not offered")
    func sameOrOlderIsUpToDate() throws {
        #expect(try Updater.evaluate(release(tag: "v1.0.0", assets: ["Clearlock-1.0.0.zip"]), currentVersion: "1.0.0") == .upToDate)
        #expect(try Updater.evaluate(release(tag: "0.9.0", assets: ["Clearlock-0.9.0.zip"]), currentVersion: "1.0.0") == .upToDate)
    }

    @Test("A newer release without the app zip is reported, not silently skipped")
    func releaseWithoutAppIsAnError() {
        #expect(throws: Updater.UpdateError.self) {
            try Updater.evaluate(release(tag: "v2.0.0", assets: ["Source.zip"]), currentVersion: "1.0.0")
        }
    }

    @Test("A download that isn't Clearlock is never installed")
    func foreignAppIsRejected() throws {
        let app = try makeBundle(identifier: "com.example.SomethingElse")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(throws: Updater.UpdateError.self) { try Updater.shared.verify(app, expectedVersion: "9.9.9") }
    }

    @Test("An unsigned copy of Clearlock is never installed")
    func unsignedAppIsRejected() throws {
        let app = try makeBundle(identifier: Bundle.main.bundleIdentifier ?? "com.farhan2077.clearlock")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(throws: Updater.UpdateError.self) { try Updater.shared.verify(app, expectedVersion: "9.9.9") }
    }

    /// A minimal, unsigned app bundle in a temporary folder.
    private func makeBundle(identifier: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClearlockTests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Clearlock.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Clearlock",
                                   "CFBundleShortVersionString": "9.9.9", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/Clearlock"))
        return app
    }
}
