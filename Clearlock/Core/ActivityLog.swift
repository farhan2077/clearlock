import Foundation
import Observation

/// In-memory record of what Clearlock did, shown in Diagnostics. Capped so it never grows.
@Observable
final class ActivityLog {
    static let shared = ActivityLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let symbol: String
        let text: String
    }

    private(set) var entries: [Entry] = []
    private let limit = 200

    private init() {}

    func add(_ symbol: String, _ text: String) {
        entries.insert(Entry(symbol: symbol, text: text), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
}
