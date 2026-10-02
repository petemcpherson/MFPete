import AppKit
import MFPeteCore
import SwiftUI

/// First-launch window (spec §8.7): what MFPete does, launch at login and
/// notifications, then a first rule from a template or Skip. Closing the
/// window at any step counts as done, so it never shows again.
struct OnboardingWindow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = Step.intro
    @State private var launchAtLogin = true
    @State private var notificationsAsked = false
    @State private var notificationsAllowed = false

    /// UI tests opt in with `--ui-testing-onboarding`; otherwise UI tests
    /// skip onboarding so they start on the Rules window.
    static var shouldShowAtLaunch: Bool {
        !UITestingFixture.isActive || ProcessInfo.processInfo.arguments.contains(UITestingFixture.onboardingArgument)
    }

    enum Step: Int, CaseIterable {
        case intro, setup, firstRule
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .intro: intro
                case .setup: setup
                case .firstRule: firstRule
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 28)

            footer
        }
        .frame(width: 520, height: 440)
        .onDisappear(perform: finish)
    }

    // MARK: - Steps

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to MFPete")
                .font(.largeTitle.bold())
            Text("MFPete watches your folders and tidies files for you, using simple rules.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            WhenIfThenPicture()
                .padding(.top, 8)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set Up")
                .font(.largeTitle.bold())
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                    Text("Rules only run while MFPete is open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                    Text("MFPete sends one short summary when something fails or after Run Now. It works fine without them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if notificationsAsked {
                    Label(notificationsAllowed ? "Allowed" : "Not allowed",
                          systemImage: notificationsAllowed ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(notificationsAllowed ? .green : .secondary)
                } else {
                    Button("Allow Notifications…") {
                        Task {
                            notificationsAllowed = await NotificationPermission.request()
                            notificationsAsked = true
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private var firstRule: some View {
        VStack(spacing: 14) {
            Text("Create Your First Rule")
                .font(.largeTitle.bold())
            Text("Start from a template. You pick the folders and save.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(RuleTemplate.featured) { template in
                    Button {
                        finish()
                        appState.startNewRule(from: template)
                        dismissWindow(id: WindowID.onboarding)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.title)
                                Text(template.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: template.systemImage)
                                .frame(width: 20)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-template-\(template.id)")
                }
            }
            .frame(width: 360)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            PageDots(current: step.rawValue, count: Step.allCases.count)
            Spacer()
            if step != .intro {
                Button("Back") { move(by: -1) }
            }
            switch step {
            case .intro, .setup:
                Button("Continue") { move(by: 1) }
                    .keyboardShortcut(.defaultAction)
            case .firstRule:
                Button("Skip") { dismissWindow(id: WindowID.onboarding) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding-skip")
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        if step == .setup && offset > 0 {
            applyLaunchAtLogin()
        }
        withAnimation { step = next }
    }

    private func applyLaunchAtLogin() {
        guard !UITestingFixture.isActive else { return }
        let wanted = launchAtLogin
        if wanted != (LoginItem.status != .disabled) {
            LoginItem.setEnabled(wanted)
        }
    }

    /// Runs once, whichever way the window closes.
    private func finish() {
        guard !appState.hasCompletedOnboarding else { return }
        if step == .setup { applyLaunchAtLogin() }
        appState.completeOnboarding()
        MenuBarHint.showSoon()
    }
}

/// When → If → Then, the shape of every rule.
private struct WhenIfThenPicture: View {
    var body: some View {
        HStack(spacing: 8) {
            card("When", "A file is added to Downloads", "bolt.fill")
            arrow
            card("If", "Its kind is Disk Image", "line.3.horizontal.decrease")
            arrow
            card("Then", "Move it to the Trash", "checkmark")
        }
        .accessibilityElement(children: .combine)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func card(_ title: LocalizedStringKey, _ text: LocalizedStringKey, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 130, height: 92, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PageDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current + 1) of \(count)"))
    }
}
