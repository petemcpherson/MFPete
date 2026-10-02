import MFPeteCore
import SwiftUI

/// Things the user can do to one rule from its row.
enum RuleCommand {
    case edit, runNow, preview, duplicate, export, runAgainOnAllFiles, delete
}

/// One dashboard row (spec §8.2): toggle, name, two-line summary, last run
/// and file count, status badge, Run Now, and the `⋯` menu.
struct RuleRow: View {
    let rule: Rule
    let onCommand: (RuleCommand) -> Void

    @Environment(AppState.self) private var appState
    private static let summarizer = RuleSummarizer()

    private var controller: EngineController { appState.engineController }

    var body: some View {
        let summary = Self.summarizer.shortSummary(for: rule)
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: enabledBinding) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(Text("Enable \(rule.name)"))
                .accessibilityIdentifier("toggle-\(rule.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(.headline)
                        .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                    if !rule.isEnabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    StatusBadge(status: controller.status(of: rule.id))
                }
                Text(summary.trigger)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(summary.trigger)
                HStack(spacing: 12) {
                    Text("→ \(summary.actions)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    RunInfo(stats: controller.stats[rule.id])
                        .accessibilityIdentifier("lastRun-\(rule.name)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            runButton

            Menu {
                RuleMenuItems(rule: rule, isRunning: controller.isRunning(rule.id), onCommand: onCommand)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel(Text("Actions for \(rule.name)"))
            .accessibilityIdentifier("menu-\(rule.name)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { appState.setEnabled($0, for: rule.id) }
        )
    }

    /// Always visible (D14). Spinner while running, disabled for "File removed".
    @ViewBuilder
    private var runButton: some View {
        if controller.isRunning(rule.id) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
                .accessibilityLabel(Text("Running \(rule.name)"))
        } else {
            Button {
                onCommand(.runNow)
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(rule.trigger == .fileRemoved)
            .help(rule.trigger == .fileRemoved
                  ? Text("Run Now is not available for “File removed” rules")
                  : Text("Run Now"))
            .accessibilityLabel(Text("Run \(rule.name) now"))
            .accessibilityIdentifier("run-\(rule.name)")
        }
    }
}

/// The `⋯` menu, shared by the row button and the list's context menu.
struct RuleMenuItems: View {
    let rule: Rule
    let isRunning: Bool
    let onCommand: (RuleCommand) -> Void

    private var canRun: Bool { rule.trigger != .fileRemoved && !isRunning }

    var body: some View {
        Button("Edit…") { onCommand(.edit) }
        Button("Run Now") { onCommand(.runNow) }
            .disabled(!canRun)
        Button("Preview Matches…") { onCommand(.preview) }
            .disabled(rule.trigger == .fileRemoved)
        Divider()
        Button("Duplicate") { onCommand(.duplicate) }
        Button("Export…") { onCommand(.export) }
        // The Activity window arrives with the activity log (Phase 6).
        Button("Show Activity") {}
            .disabled(true)
        Divider()
        Button("Run Again on All Files") { onCommand(.runAgainOnAllFiles) }
            .disabled(!canRun)
        Divider()
        Button("Delete…", role: .destructive) { onCommand(.delete) }
    }
}

/// "Last run 2 minutes ago · 128 files". Updates every minute.
private struct RunInfo: View {
    let stats: RuleStats?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(text(now: context.date))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func text(now: Date) -> String {
        guard let lastRun = stats?.lastRun else { return String(localized: "Never run") }
        let relative = lastRun.formatted(.relative(presentation: .named).locale(.current))
        let count = stats?.fileCount ?? 0
        return String(localized: "Last run \(relative) · \(count) files")
    }
}

/// Error or unavailable badge next to the rule name.
private struct StatusBadge: View {
    let status: RuleStatus

    var body: some View {
        if let message = status.message {
            Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "externaldrive.badge.xmark")
                .foregroundStyle(status.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .help(message)
                .accessibilityLabel(Text(message))
        }
    }
}

extension RuleStatus {
    /// Text for badges and tooltips. Nil when the rule is OK.
    var message: String? {
        switch self {
        case .ok: return nil
        case .folderMissing(let path): return String(localized: "Folder missing: \(path)")
        case .noPermission(let path): return String(localized: "No permission: \(path)")
        case .folderUnavailable(let path): return String(localized: "Folder unavailable: \(path)")
        case .error(let message): return message
        }
    }
}
