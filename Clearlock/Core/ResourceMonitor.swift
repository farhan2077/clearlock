import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// One reading of Clearlock's own resource usage, from the kernel's per-process
/// accounting (the same counters Activity Monitor uses).
struct ResourceSample: Identifiable {
    let id = UUID()
    let date: Date
    let footprint: UInt64          // bytes, matches Activity Monitor's "Memory" column
    let cpuPercent: Double
    let wakeupsPerSecond: Double
    let milliwatts: Double?        // CPU energy attributed to this process
    let threads: Int

    struct Raw {
        let date: Date
        let cpuNanos: UInt64
        let wakeups: UInt64
        let energyNanojoules: UInt64
        let footprint: UInt64
    }

    static func readRaw() -> Raw? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { return nil }
        // CPU times are reported in Mach absolute time units on Apple silicon.
        let cpu = machToNanos(info.ri_user_time + info.ri_system_time)
        return Raw(date: Date(), cpuNanos: cpu, wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
                   energyNanojoules: info.ri_energy_nj, footprint: info.ri_phys_footprint)
    }

    static func between(_ a: Raw, _ b: Raw) -> ResourceSample {
        let seconds = max(b.date.timeIntervalSince(a.date), 0.001)
        let cpu = Double(b.cpuNanos &- a.cpuNanos) / (seconds * 1e9) * 100
        let wakeups = Double(b.wakeups &- a.wakeups) / seconds
        let energy = b.energyNanojoules >= a.energyNanojoules && b.energyNanojoules > 0
            ? Double(b.energyNanojoules - a.energyNanojoules) / seconds / 1e6 : nil
        return ResourceSample(date: b.date, footprint: b.footprint, cpuPercent: cpu,
                              wakeupsPerSecond: wakeups, milliwatts: energy, threads: threadCount())
    }

    static func currentFootprint() -> UInt64 { readRaw()?.footprint ?? 0 }

    static func footprintString(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func machToNanos(_ value: UInt64) -> UInt64 {
        value * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }

    private static func threadCount() -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size ? Int(info.pti_threadnum) : 0
    }
}

/// Battery, power source and whole-system power draw.
struct SystemPowerSnapshot {
    var isOnAC = true
    var batteryPercent: Int?
    var isCharging = false
    var minutesRemaining: Int?
    var systemWatts: Double?
    var assertionCounts: [String: Int] = [:]

    static func current(includeAssertions: Bool = false) -> SystemPowerSnapshot {
        var snapshot = SystemPowerSnapshot()
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            snapshot.isOnAC = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                if let current = desc[kIOPSCurrentCapacityKey] as? Int, let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    snapshot.batteryPercent = current * 100 / max
                }
                snapshot.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                if let minutes = desc[kIOPSTimeToEmptyKey] as? Int, minutes > 0 { snapshot.minutesRemaining = minutes }
            }
        }
        snapshot.systemWatts = systemPowerDraw()
        if includeAssertions {
            var status: Unmanaged<CFDictionary>?
            if IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
               let dict = status?.takeRetainedValue() as? [String: Int] {
                snapshot.assertionCounts = dict
            }
        }
        return snapshot
    }

    /// Whole-machine power from the battery controller: telemetry when on AC, V × A on battery.
    private static func systemPowerDraw() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        if let telemetry = dict["PowerTelemetryData"] as? [String: Any],
           let systemIn = telemetry["SystemPowerIn"] as? Int, systemIn > 0 {
            return Double(systemIn) / 1000
        }
        if let voltage = dict["Voltage"] as? Int, let amperage = dict["InstantAmperage"] as? Int ?? dict["Amperage"] as? Int {
            let watts = Double(voltage) * Double(abs(amperage)) / 1_000_000
            return watts > 0 ? watts : nil
        }
        return nil
    }
}

/// Samples Clearlock's own impact once per second, only while Diagnostics is open.
@Observable
final class ResourceMonitor {
    static let shared = ResourceMonitor()

    struct TestResult {
        let duration: TimeInterval
        let averageCPU: Double
        let averageWakeups: Double
        let averageMilliwatts: Double?
        let memory: UInt64
        let state: String

        /// The result comes only from the readings at the start and end of the test, so
        /// nothing between them (no sampling, no redrawing) adds to it.
        static func measured(from start: ResourceSample.Raw, to end: ResourceSample.Raw, state: String) -> TestResult {
            let total = ResourceSample.between(start, end)
            return TestResult(duration: end.date.timeIntervalSince(start.date), averageCPU: total.cpuPercent,
                              averageWakeups: total.wakeupsPerSecond, averageMilliwatts: total.milliwatts,
                              memory: end.footprint, state: state)
        }

        enum Verdict: Comparable {
            case negligible, veryLow, low, noticeable

            var title: String {
                switch self {
                case .negligible: "Negligible"
                case .veryLow: "Very low"
                case .low: "Low"
                case .noticeable: "Noticeable"
                }
            }
        }

        var verdict: Verdict { Self.verdict(cpuPercent: averageCPU, wakeupsPerSecond: averageWakeups) }

        static func verdict(cpuPercent: Double, wakeupsPerSecond: Double) -> Verdict {
            if cpuPercent < 0.1 && wakeupsPerSecond < 2 { return .negligible }
            if cpuPercent < 1 && wakeupsPerSecond < 10 { return .veryLow }
            if cpuPercent < 5 { return .low }
            return .noticeable
        }
    }

    private(set) var samples: [ResourceSample] = []
    private(set) var power = SystemPowerSnapshot()
    /// When the running impact test ends; nil when no test is running.
    private(set) var testEndDate: Date?
    private(set) var testResult: TestResult?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastRaw: ResourceSample.Raw?
    @ObservationIgnored private var testStart: ResourceSample.Raw?
    @ObservationIgnored private var testTimer: Timer?
    @ObservationIgnored private var resumesAfterTest = false
    private let historyLength = 120
    let testDuration: TimeInterval = 30

    var latest: ResourceSample? { samples.last }

    private init() {}

    func start() {
        guard timer == nil else { return }
        if testStart != nil { resumesAfterTest = true; return }
        lastRaw = ResourceSample.readRaw()
        power = SystemPowerSnapshot.current(includeAssertions: true)
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ResourceMonitor.shared.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// True while Diagnostics samples live (only while its window is open, and paused
    /// during an impact test).
    var isSampling: Bool { timer != nil }

    var isTesting: Bool { testStart != nil }

    func stop() {
        timer?.invalidate()
        timer = nil
        testTimer?.invalidate()
        testTimer = nil
        samples = []
        testStart = nil
        testEndDate = nil
        resumesAfterTest = false
    }

    /// Measures average CPU, wakeups and energy over `duration` seconds in the current state.
    /// Live sampling pauses until it ends, so the charts don't redraw and this window's
    /// own drawing isn't counted: only one reading at each end and a single timer.
    func runImpactTest(duration: TimeInterval? = nil) {
        guard testStart == nil, let raw = ResourceSample.readRaw() else { return }
        let duration = duration ?? testDuration
        resumesAfterTest = timer != nil
        timer?.invalidate()
        timer = nil
        testResult = nil
        testStart = raw
        testEndDate = raw.date.addingTimeInterval(duration)
        let testTimer = Timer(timeInterval: duration, repeats: false) { _ in
            MainActor.assumeIsolated { ResourceMonitor.shared.finishImpactTest() }
        }
        testTimer.tolerance = 0.2
        RunLoop.main.add(testTimer, forMode: .common)
        self.testTimer = testTimer
    }

    private func finishImpactTest() {
        testTimer = nil
        guard let first = testStart else { return }
        testStart = nil
        testEndDate = nil
        if let end = ResourceSample.readRaw() {
            let state = LockController.shared.isLocked ? "Locked"
                : AwakeController.shared.isActive ? "Keeping awake" : "Idle"
            let result = TestResult.measured(from: first, to: end, state: state)
            testResult = result
            ActivityLog.shared.add("gauge.with.dots.needle.33percent", "Impact test: \(result.verdict.title.lowercased()) impact")
        }
        if resumesAfterTest {
            resumesAfterTest = false
            start()
        }
    }

    private func tick() {
        guard let raw = ResourceSample.readRaw() else { return }
        if let lastRaw {
            samples.append(ResourceSample.between(lastRaw, raw))
            if samples.count > historyLength { samples.removeFirst(samples.count - historyLength) }
        }
        lastRaw = raw
        if Int(raw.date.timeIntervalSince1970) % 5 == 0 {
            power = SystemPowerSnapshot.current(includeAssertions: true)
        }
    }
}
