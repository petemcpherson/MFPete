import MFPeteCore
import SwiftUI

/// Settings scene (spec §8.5).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            FolderSettings()
                .tabItem { Label("Folders", systemImage: "folder") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var appState
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var notificationsDenied = false

    var body: some View {
        let controller = appState.engineController
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus != .disabled },
                    set: { enabled in
                        loginError = LoginItem.setEnabled(enabled)
                        loginStatus = LoginItem.status
                    }
                ))
                if loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { LoginItem.openLoginItemsSettings() }
                    } label: {
                        Text("Requires approval in System Settings › Login Items.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let loginError {
                    Text(loginError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Toggle("Show icon in Dock", isOn: Binding(
                    get: { appState.showsDockIcon },
                    set: { appState.setShowsDockIcon($0) }
                ))
            }

            Section {
                Picker("Notifications", selection: Binding(
                    get: { controller.notificationLevel },
                    set: { controller.setNotificationLevel($0) }
                )) {
                    ForEach(NotificationLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text(levelDescription(controller.notificationLevel))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if notificationsDenied {
                    LabeledContent {
                        Button("Open Notifications…") { SystemSettingsLink.openNotifications() }
                    } label: {
                        Text("Notifications are turned off for MFPete in System Settings. The Activity log still records every run.")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("The “Show notification” action always posts, even when notifications are off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            loginStatus = LoginItem.status
            notificationsDenied = await NotificationPermission.isDenied()
        }
    }

    private func levelDescription(_ level: NotificationLevel) -> LocalizedStringKey {
        switch level {
        case .off:
            return "No summaries. Check the Activity log to see what ran."
        case .errorsOnly:
            return "A summary when something fails, after Run Now, and for rules with “Notify on each run”."
        case .everyRun:
            return "A summary after every run that acted on files, plus errors and Run Now."
        }
    }
}

// MARK: - Folders

private struct FolderSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let usages = appState.engineController.folderUsages
        VStack(alignment: .leading, spacing: 10) {
            if usages.isEmpty {
                ContentUnavailableView(
                    "No Folders",
                    systemImage: "folder",
                    description: Text("Folders your rules watch appear here.")
                )
                .frame(height: 220)
            } else {
                List(usages) { usage in
                    FolderUsageRow(usage: usage)
                }
                .frame(minHeight: 240)
            }
            HStack {
                Text("MFPete checks each folder before every run.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if usages.contains(where: { $0.health == .noPermission }) {
                    Button("Open Privacy & Security…") { SystemSettingsLink.openFilesAndFolders() }
                }
            }
        }
        .padding()
        .task { await appState.engineController.refresh() }
    }
}

private struct FolderUsageRow: View {
    let usage: FolderUsage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(usage.folder.tildeAbbreviated())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ListFormatter.localizedString(byJoining: usage.ruleNames))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            FolderHealthLabel(health: usage.health)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([usage.folder.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(usage.health == .missing || usage.health == .unavailable)
            .help("Reveal in Finder")
            .accessibilityLabel(Text("Reveal \(usage.folder.displayName) in Finder"))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

private struct FolderHealthLabel: View {
    let health: FolderHealth

    var body: some View {
        switch health {
        case .ok:
            Label("OK", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing:
            Label("Missing", systemImage: "questionmark.folder.fill")
                .foregroundStyle(.orange)
        case .noPermission:
            Label("No permission", systemImage: "lock.fill")
                .foregroundStyle(.orange)
        case .unavailable:
            Label("Unavailable", systemImage: "externaldrive.badge.xmark")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Environment(AppState.self) private var appState
    @State private var confirmingReset = false
    @State private var resetDone = false

    var body: some View {
        let controller = appState.engineController
        Form {
            Section {
                Stepper(value: Binding(
                    get: { controller.settleDelay },
                    set: { controller.setSettleDelay($0) }
                ), in: Settler.delayRange, step: 1) {
                    LabeledContent("File settle delay") {
                        Text("\(Int(controller.settleDelay)) s")
                            .monospacedDigit()
                    }
                }
                Text("How long a new file must stay unchanged before rules run on it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Stepper(value: Binding(
                    get: { controller.bulkThreshold },
                    set: { controller.setBulkThreshold($0) }
                ), in: EngineController.bulkThresholdRange, step: 5) {
                    LabeledContent("Ask before acting on more than") {
                        Text("\(controller.bulkThreshold) files")
                            .monospacedDigit()
                    }
                }
            }

            Section("Rules") {
                LabeledContent("Rules file") {
                    HStack {
                        Button("Export All Rules…") {
                            RuleExporter.exportAll(appState.rules)
                        }
                        .disabled(appState.rules.isEmpty)
                        Button("Import Rules…") {
                            RuleExporter.importRules(into: appState)
                        }
                    }
                }
                LabeledContent("Processed files") {
                    Button("Reset History…") { confirmingReset = true }
                }
                Text(resetDone
                     ? "History reset. Rules re-check existing files on their next run."
                     : "Each rule acts on a file once until it changes. Resetting makes every rule re-check existing files on its next run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset Processed-File History?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                Task {
                    await controller.resetAllProcessed()
                    resetDone = true
                }
            }
        } message: {
            Text("Every rule will act again on matching files that are already in its folders.")
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("MFPete")
                .font(.title2.bold())
            Text(AppInfo.version)
                .foregroundStyle(.secondary)
            Text("Free and open source under the MIT License.")
            HStack(spacing: 16) {
                Link("GitHub", destination: AppInfo.repositoryURL)
                Link("License", destination: AppInfo.licenseURL)
            }
            Divider()
                .padding(.vertical, 4)
            // Sparkle "Check for Updates…" and the automatic-check toggle come in Phase 7.
            UpdateControls(updater: appState.updater)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

private struct UpdateControls: View {
    @Bindable var updater: UpdaterService

    var body: some View {
        if updater.isAvailable {
            VStack(spacing: 8) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
            }
        } else {
            Text("Updates are turned off in this build.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
