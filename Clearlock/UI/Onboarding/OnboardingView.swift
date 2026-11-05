import SwiftUI

/// The welcome guide has two pages: a welcome with Clearlock's three main features, then
/// Accessibility permission. Everything else (Touch ID, the ⇧⌘L shortcut, Keep Awake,
/// letting agents work) is on by default.
struct OnboardingView: View {
    let onFinish: () -> Void

    enum Page: CaseIterable { case welcome, accessibility }
    enum PrimaryButton { case `continue`, done, skipForNow }

    /// The bottom-right button: Continue on the welcome page; on the Accessibility page,
    /// Done once it's allowed, Skip for Now before that.
    static func primaryButton(on page: Page, accessibilityAllowed: Bool) -> PrimaryButton {
        switch page {
        case .welcome: .continue
        case .accessibility: accessibilityAllowed ? .done : .skipForNow
        }
    }

    /// Back is only offered on the Accessibility page.
    static func showsBack(on page: Page) -> Bool { page == .accessibility }

    @State private var page = Page.welcome
    @State private var showsLockPausedBanner = false
    private let session = OnboardingSession.shared
    private let permissions = PermissionCenter.shared

    enum FinishButton { case done, skipForNow }

    /// The Accessibility page's finish button: Done once allowed, Skip for Now before that.
    static func finishButton(accessibilityAllowed: Bool) -> FinishButton {
        accessibilityAllowed ? .done : .skipForNow
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .welcome: WelcomePage()
                case .accessibility: ShieldPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

            HStack {
                if Self.showsBack(on: page) {
                    Button("Back") { withAnimation(.snappy) { page = .welcome } }
                        .controlSize(.large)
                }
                Spacer()
                primaryButton
            }
            .overlay {
                // Page dots, centered on the window whichever buttons are showing.
                HStack(spacing: 6) {
                    ForEach(Page.allCases, id: \.self) { dot in
                        Circle()
                            .fill(dot == page ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .frame(width: 620, height: 480)
        .overlay(alignment: .bottom) {
            if showsLockPausedBanner {
                Label("Locking is paused until you finish this guide", systemImage: "lock.slash.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .overlay(Capsule().strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: session.blockedLockCount) {
            withAnimation(.snappy) { showsLockPausedBanner = true }
            Task {
                try? await Task.sleep(for: .seconds(3.5))
                withAnimation(.snappy) { showsLockPausedBanner = false }
            }
        }
    }
}

extension OnboardingView {
    @ViewBuilder private var primaryButton: some View {
        let kind = Self.primaryButton(on: page, accessibilityAllowed: permissions.isAccessibilityTrusted)
        Button(kind == .continue ? "Continue" : kind == .done ? "Done" : "Skip for Now") {
            if kind == .continue {
                withAnimation(.snappy) { page = .accessibility }
            } else {
                onFinish()
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
}

private struct PageLayout<Content: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.gradient))
                .shadow(color: color.opacity(0.35), radius: 10, y: 4)
            VStack(spacing: 6) {
                Text(title).font(.title.weight(.semibold))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            content
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Page 1: what Clearlock does, in three features.
private struct WelcomePage: View {
    var body: some View {
        PageLayout(symbol: "lock.fill", color: .orange, title: "Welcome to Clearlock",
                   subtitle: "Lock your Mac while your work keeps running. Like a glass case: everything stays visible, but nothing can be touched.") {
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "sun.max.fill", color: .yellow, title: "Stays awake",
                        detail: "Your Mac and its display stay awake for as long as Clearlock runs.")
                Feature(symbol: "lock.shield.fill", color: .orange, title: "Locks with ⇧⌘L",
                        detail: "Covers every screen. Unlock with Touch ID or your login password.")
                Feature(symbol: "sparkles", color: .purple, title: "Agents keep working",
                        detail: "Only your keyboard, mouse and trackpad are blocked. AI agents and scripts carry on.")
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.top, 6)
        }
    }
}

private struct Feature: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Page 2: Accessibility permission.
private struct ShieldPage: View {
    private let permissions = PermissionCenter.shared

    var body: some View {
        PageLayout(symbol: "hand.raised.fill", color: .red, title: "Let your agents keep working",
                   subtitle: "With Accessibility permission, Clearlock blocks only your keyboard, mouse and trackpad, while AI agents and scripts keep working. Optional, and you can change it later in Settings.") {
            AccessibilityPermissionRow()
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                .frame(maxWidth: 480)

            if permissions.hasRequestedAccessibility && !permissions.isAccessibilityTrusted {
                Text("Switch on Clearlock in the list that opened. This page updates as soon as you do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
            }
        }
    }
}
