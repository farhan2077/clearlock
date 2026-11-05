import Foundation
import Testing
@testable import Clearlock

@Suite("Diagnostics measurements")
struct ResourceTests {
    @Test("CPU, wakeups and energy are computed per second between two readings")
    func ratesBetweenReadings() {
        let start = Date(timeIntervalSince1970: 1000)
        let a = ResourceSample.Raw(date: start, cpuNanos: 1_000_000_000, wakeups: 100,
                                   energyNanojoules: 10_000_000, footprint: 14_000_000)
        let b = ResourceSample.Raw(date: start.addingTimeInterval(2), cpuNanos: 1_500_000_000, wakeups: 110,
                                   energyNanojoules: 14_000_000, footprint: 15_000_000)
        let sample = ResourceSample.between(a, b)
        #expect(sample.cpuPercent == 25)           // 0.5 s of CPU over 2 s
        #expect(sample.wakeupsPerSecond == 5)      // 10 wakeups over 2 s
        #expect(sample.milliwatts == 2)            // 4 mJ over 2 s
        #expect(sample.footprint == 15_000_000)
    }

    @Test("Energy is unknown rather than zero when the system doesn't report it")
    func missingEnergyIsNil() {
        let start = Date(timeIntervalSince1970: 1000)
        let a = ResourceSample.Raw(date: start, cpuNanos: 0, wakeups: 0, energyNanojoules: 0, footprint: 1)
        let b = ResourceSample.Raw(date: start.addingTimeInterval(1), cpuNanos: 0, wakeups: 0, energyNanojoules: 0, footprint: 1)
        #expect(ResourceSample.between(a, b).milliwatts == nil)
    }

    @Test("The activity log keeps the newest 200 entries, newest first")
    func activityLogIsCapped() {
        let log = ActivityLog.shared
        for i in 0..<250 { log.add("circle", "entry \(i)") }
        #expect(log.entries.count == 200)
        #expect(log.entries.first?.text == "entry 249")
    }
}
