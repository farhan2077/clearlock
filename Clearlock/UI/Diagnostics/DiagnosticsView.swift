import Charts
import SwiftUI

/// Shows exactly what Clearlock is doing and what it costs: its own memory, CPU,
/// wakeups and energy, the power assertions it holds, the input shield's counters
/// and a timeline of events. Sampling runs only while this window is open.
struct DiagnosticsView: View {
    private let monitor = ResourceMonitor.shared
    private let lock = LockController.shared
    private let awake = AwakeController.shared
    private let power = PowerAssertions.shared
    private let log = ActivityLog.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DiagnosticsStyle.sectionSpacing) {
                header
                metrics
                impactTest
                HStack(alignment: .top, spacing: DiagnosticsStyle.cardSpacing) {
                    engineSection
                    powerSection
                }
                activitySection
            }
            .padding(DiagnosticsStyle.pagePadding)
        }
        .background(.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DiagnosticsStyle.cardSpacing) {
            VStack(alignment: .leading, spacing: DiagnosticsStyle.textSpacing) {
                Text("Clearlock Impact").font(DiagnosticsStyle.pageTitle)
                Text("Live measurements from the system’s per-process accounting, the same counters Activity Monitor uses.")
                    .font(DiagnosticsStyle.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            StateBadge(locked: lock.isLocked, awake: awake.isActive)
        }
    }

    // MARK: Metrics

    private var metrics: some View {
        let samples = monitor.samples
        let latest = monitor.latest
        return Grid(horizontalSpacing: DiagnosticsStyle.cardSpacing, verticalSpacing: DiagnosticsStyle.cardSpacing) {
            GridRow {
                MetricTile(title: "Memory", value: latest.map { ResourceSample.footprintString($0.footprint) } ?? "…",
                           caption: "Physical footprint", color: .blue,
                           points: samples.map { ($0.date, Double($0.footprint) / 1_048_576) })
                MetricTile(title: "CPU", value: latest.map { String(format: "%.2f %%", $0.cpuPercent) } ?? "…",
                           caption: "Of one core", color: .orange,
                           points: samples.map { ($0.date, $0.cpuPercent) })
            }
            GridRow {
                MetricTile(title: "Wakeups", value: latest.map { String(format: "%.1f /s", $0.wakeupsPerSecond) } ?? "…",
                           caption: "Idle and interrupt wakeups", color: .purple,
                           points: samples.map { ($0.date, $0.wakeupsPerSecond) })
                MetricTile(title: "Energy", value: latest.flatMap { $0.milliwatts }.map { String(format: "%.1f mW", $0) } ?? "—",
                           caption: "CPU energy", color: .green,
                           points: samples.compactMap { s in s.milliwatts.map { (s.date, $0) } })
            }
        }
    }

    // MARK: Impact test

    private var impactTest: some View {
        DiagnosticsCard("Impact Test") {
            if let progress = monitor.testProgress {
                ProgressView(value: progress).controlSize(.small).frame(width: 120)
            } else {
                Button("Run Test") { monitor.runImpactTest() }
                    .controlSize(.small)
            }
        } content: {
            Text("Measures Clearlock’s average cost over \(Int(monitor.testDuration)) seconds in its current state. Part of what it measures is this window itself.")
                .font(DiagnosticsStyle.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let result = monitor.testResult {
                Divider()
                HStack(alignment: .top, spacing: DiagnosticsStyle.sectionSpacing) {
                    ResultValue(title: "Verdict", value: result.verdict.title, emphasized: true)
                    ResultValue(title: "State", value: result.state)
                    ResultValue(title: "Avg CPU", value: String(format: "%.3f %%", result.averageCPU))
                    ResultValue(title: "Peak CPU", value: String(format: "%.2f %%", result.peakCPU))
                    ResultValue(title: "Wakeups", value: String(format: "%.1f /s", result.averageWakeups))
                    ResultValue(title: "Energy", value: result.averageMilliwatts.map { String(format: "%.1f mW", $0) } ?? "—")
                    ResultValue(title: "Memory", value: ResourceSample.footprintString(result.memory))
                }
            }
        }
    }

    // MARK: Engine

    private var engineSection: some View {
        DiagnosticsCard("What’s Running") {
            EngineRow(symbol: "bolt.fill", title: "Prevent system sleep", active: power.preventsSystemSleep,
                      detail: power.systemAssertion.map { "IOKit assertion #\($0)" } ?? "Not held")
            EngineRow(symbol: "sun.max.fill", title: "Prevent display sleep", active: power.preventsDisplaySleep,
                      detail: power.displayAssertion.map { "IOKit assertion #\($0)" } ?? "Not held")
            EngineRow(symbol: "rectangle.inset.filled", title: "Lock windows", active: lock.isLocked,
                      detail: lock.isLocked ? "\(lock.overlayCount) display\(lock.overlayCount == 1 ? "" : "s") covered · \(lock.mode.title)" : "None")
            EngineRow(symbol: "hand.raised.fill", title: "Input shield", active: lock.shield.isRunning,
                      detail: shieldDetail)
            EngineRow(symbol: "laptopcomputer", title: "Lid sleep disabled", active: LidSleepManager.shared.isEngaged,
                      detail: LidSleepManager.shared.isHelperInstalled ? "Helper installed" : "Not set up")
            EngineRow(symbol: "command", title: "Global shortcut", active: true,
                      detail: "Carbon hotkey. No cost until pressed.")
            if let session = lock.lastSession, !lock.isLocked {
                Divider()
                Text("Last lock: \(LockController.durationString(since: session.start)) ago, unlocked with \(session.unlockMethod). \(session.blockedInputs) inputs blocked, \(session.allowedAutomation) automation events allowed, \(session.failedAttempts.count) failed attempts.")
                    .font(DiagnosticsStyle.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shieldDetail: String {
        let c = lock.shield.counters
        guard lock.shield.isRunning else {
            return PermissionCenter.shared.isAccessibilityTrusted ? "Starts when locked" : "Needs Accessibility"
        }
        var text = "\(c.blockedPhysical) physical blocked · \(c.allowedAutomation) automation allowed"
        let sources = c.automationSources.sorted { $0.value > $1.value }.prefix(3).map { pid, count in
            "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)") (\(count))"
        }
        if !sources.isEmpty { text += "\nFrom: " + sources.joined(separator: ", ") }
        return text
    }

    // MARK: Power

    private var powerSection: some View {
        let p = monitor.power
        return DiagnosticsCard("Power") {
            InfoRow("Power source", p.isOnAC ? "Power adapter" : "Battery")
            if let percent = p.batteryPercent {
                InfoRow("Battery", "\(percent)%" + (p.isCharging ? ", charging" : "")
                               + (p.minutesRemaining.map { ", \($0 / 60)h \($0 % 60)m left" } ?? ""))
            }
            if let watts = p.systemWatts {
                InfoRow("Whole Mac draw", String(format: "%.1f W", watts))
            }
            InfoRow("Sleep blockers, system-wide", "\(p.assertionCounts["PreventUserIdleSystemSleep"] ?? 0)")
            InfoRow("Display sleep blockers", "\(p.assertionCounts["PreventUserIdleDisplaySleep"] ?? 0)")
            Text("A held power assertion costs nothing by itself. Most of the extra power comes from the display staying lit.")
                .font(DiagnosticsStyle.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        DiagnosticsCard("Activity") {
            if log.entries.isEmpty {
                Text("Nothing yet. Lock your Mac to see events here.")
                    .font(DiagnosticsStyle.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.entries.prefix(40)) { entry in
                    HStack(spacing: DiagnosticsStyle.iconSpacing) {
                        Image(systemName: entry.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: DiagnosticsStyle.iconWidth)
                        Text(entry.text).font(DiagnosticsStyle.body)
                        Spacer(minLength: 0)
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .font(DiagnosticsStyle.detail.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Style

/// One spacing scale and four text styles for the whole window.
enum DiagnosticsStyle {
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let cardSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 12
    static let textSpacing: CGFloat = 4
    static let iconSpacing: CGFloat = 10
    static let iconWidth: CGFloat = 18
    static let cornerRadius: CGFloat = 12

    static let pageTitle = Font.title2.weight(.semibold)
    static let cardTitle = Font.headline
    static let body = Font.body
    static let detail = Font.caption
    static let metricValue = Font.system(.title, design: .rounded).weight(.semibold).monospacedDigit()
}

/// Every box in the window: a title row (with an optional control on the right) over
/// content, with the same padding, spacing and background.
private struct DiagnosticsCard<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DiagnosticsStyle.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: DiagnosticsStyle.cardSpacing) {
                Text(title).font(DiagnosticsStyle.cardTitle)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DiagnosticsStyle.cardPadding)
        .background(RoundedRectangle(cornerRadius: DiagnosticsStyle.cornerRadius).fill(.quaternary.opacity(0.5)))
    }
}

extension DiagnosticsCard where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Components

private struct StateBadge: View {
    let locked: Bool
    let awake: Bool

    var body: some View {
        let (text, symbol, color): (String, String, Color) =
            locked ? ("Locked", "lock.fill", Color(nsColor: Preferences.shared.tint.color))
            : awake ? ("Keeping Awake", "cup.and.heat.waves.fill", .orange)
            : ("Not Active", "moon.zzz", .secondary)
        Label(text, systemImage: symbol)
            .font(DiagnosticsStyle.body.weight(.medium))
            .padding(.horizontal, DiagnosticsStyle.iconSpacing)
            .padding(.vertical, DiagnosticsStyle.textSpacing)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let caption: String
    let color: Color
    let points: [(Date, Double)]

    var body: some View {
        DiagnosticsCard(title) {
            Text(caption)
                .font(DiagnosticsStyle.detail)
                .foregroundStyle(.secondary)
        } content: {
            Text(value)
                .font(DiagnosticsStyle.metricValue)
                .contentTransition(.numericText())
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("Time", point.0), y: .value(title, point.1))
                        .foregroundStyle(color.opacity(0.15).gradient)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.0), y: .value(title, point.1))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                    AxisGridLine()
                    AxisValueLabel().font(DiagnosticsStyle.detail)
                }
            }
            .frame(height: 64)
        }
    }
}

private struct EngineRow: View {
    let symbol: String
    let title: String
    let active: Bool
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DiagnosticsStyle.iconSpacing) {
            Image(systemName: symbol)
                .foregroundStyle(active ? Color.green : Color.secondary)
                .frame(width: DiagnosticsStyle.iconWidth)
            VStack(alignment: .leading, spacing: DiagnosticsStyle.textSpacing / 2) {
                HStack(spacing: DiagnosticsStyle.textSpacing * 1.5) {
                    Text(title).font(DiagnosticsStyle.body)
                    Circle().fill(active ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                }
                Text(detail)
                    .font(DiagnosticsStyle.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct InfoRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: DiagnosticsStyle.cardSpacing) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit()
        }
        .font(DiagnosticsStyle.body)
    }
}

private struct ResultValue: View {
    let title: String
    let value: String
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: DiagnosticsStyle.textSpacing / 2) {
            Text(title).font(DiagnosticsStyle.detail).foregroundStyle(.secondary)
            Text(value)
                .font(DiagnosticsStyle.body.weight(emphasized ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(emphasized ? Color.green : .primary)
        }
    }
}
