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

    @Test("The impact test's result comes only from the readings at its start and end")
    func impactResultFromEndReadings() {
        let start = Date(timeIntervalSince1970: 1000)
        let a = ResourceSample.Raw(date: start, cpuNanos: 2_000_000_000, wakeups: 500,
                                   energyNanojoules: 50_000_000, footprint: 14_000_000)
        let b = ResourceSample.Raw(date: start.addingTimeInterval(30), cpuNanos: 2_030_000_000, wakeups: 530,
                                   energyNanojoules: 59_000_000, footprint: 15_000_000)
        let result = ResourceMonitor.TestResult.measured(from: a, to: b, state: "Idle")
        #expect(result.duration == 30)
        #expect(abs(result.averageCPU - 0.1) < 1e-9)       // 30 ms of CPU over 30 s
        #expect(result.averageWakeups == 1)                // 30 wakeups over 30 s
        #expect(result.averageMilliwatts == 0.3)           // 9 mJ over 30 s
        #expect(result.memory == 15_000_000)
    }

    @Test("The activity log keeps the newest 200 entries, newest first")
    func activityLogIsCapped() {
        let log = ActivityLog.shared
        for i in 0..<250 { log.add("circle", "entry \(i)") }
        #expect(log.entries.count == 200)
        #expect(log.entries.first?.text == "entry 249")
    }
}
