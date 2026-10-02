import AppKit
import MFPeteCore
import SwiftUI

/// The activity log (spec §8.4, D15): one table, newest first, filtered by
/// rule and "Errors only". Reloads after every engine event.
struct ActivityWindow: View {
    @Environment(AppState.self) private var appState
    @State private var ruleFilter: Rule.ID?
    @State private var errorsOnly = false
    @State private var records: [ActivityRecord] = []
    @State private var selection: Set<ActivityRecord.ID> = []
    @State private var confirmingClear = false
    @State private var hasLoaded = false

    private var controller: EngineController { appState.engineController }

    var body: some View {
        table
            .overlay { emptyState }
            .toolbar { toolbar }
            .navigationTitle("Activity")
            .frame(minWidth: 700, minHeight: 320)
            .task(id: LoadKey(ruleID: ruleFilter, errorsOnly: errorsOnly, revision: controller.activityRevision)) {
                await load()
            }
            .onAppear { applyRequest(appState.activityRequest) }
            .onChange(of: appState.activityRequest) { _, request in applyRequest(request) }
            .confirmationDialog("Clear the Activity Log?", isPresented: $confirmingClear) {
                Button("Clear Log", role: .destructive) {
                    Task { await controller.clearActivityLog() }
                }
            } message: {
                Text("All entries are deleted. Files and rules are not changed.")
            }
    }

    private var table: some View {
        Table(records, selection: $selection) {
            TableColumn("Time") { record in
                Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .help(record.timestamp.formatted(date: .complete, time: .standard))
            }
            .width(min: 110, ideal: 140)
            TableColumn("Rule") { record in
                Text(record.ruleName)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Trigger") { record in
                Text(record.runTrigger.displayName)
                    .help(record.detail)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Action") { record in
                Text(record.action)
            }
            .width(min: 70, ideal: 110)
            TableColumn("File") { record in
                FileCell(record: record)
            }
            .width(min: 160, ideal: 300)
            TableColumn("Result") { record in
                ResultMark(result: record.result)
            }
            .width(48)
        }
        .contextMenu(forSelectionType: ActivityRecord.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            for record in records where ids.contains(record.id) {
                ActivityFile.reveal(record)
            }
        }
        .accessibilityIdentifier("activityTable")
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<ActivityRecord.ID>) -> some View {
        let chosen = records.filter { ids.contains($0.id) }
        Button("Reveal in Finder") {
            for record in chosen { ActivityFile.reveal(record) }
        }
        .disabled(!chosen.contains { ActivityFile.existingPath(of: $0) != nil })
        Button("Copy Path") {
            let paths = chosen.map { $0.destinationPath ?? $0.sourcePath }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        }
        .disabled(chosen.isEmpty)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Rule", selection: $ruleFilter) {
                Text("All Rules").tag(Rule.ID?.none)
                Divider()
                ForEach(appState.rules) { rule in
                    Text(rule.name).tag(Optional(rule.id))
                }
            }
            .frame(minWidth: 160)
            .help("Show one rule's activity")
            .accessibilityIdentifier("activityRuleFilter")

            Toggle(isOn: $errorsOnly) {
                Label("Errors Only", systemImage: "exclamationmark.triangle")
            }
            .help("Show only failed actions")

            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear Log", systemImage: "trash")
            }
            .help("Clear the activity log")
            .disabled(records.isEmpty && ruleFilter == nil && !errorsOnly)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasLoaded && records.isEmpty {
            ContentUnavailableView {
                Label("No Activity", systemImage: "list.bullet.rectangle")
            } description: {
                Text(ruleFilter == nil && !errorsOnly
                     ? "Each file a rule acts on appears here. Entries are kept for 30 days."
                     : "No entries match these filters.")
            }
        }
    }

    private func load() async {
        records = await controller.activityEntries(ruleID: ruleFilter, errorsOnly: errorsOnly)
        hasLoaded = true
        let ids = Set(records.map(\.id))
        selection.formIntersection(ids)
    }

    /// A rule's "Show Activity" or a notification click pre-selects the rule.
    private func applyRequest(_ request: ActivityRequest?) {
        guard let request else { return }
        ruleFilter = request.ruleID.flatMap { appState.rule($0)?.id }
        errorsOnly = false
        appState.activityRequest = nil
    }

    private struct LoadKey: Equatable {
        var ruleID: Rule.ID?
        var errorsOnly: Bool
        var revision: Int
    }
}

/// File name, with the failure or skip reason as a second line.
private struct FileCell: View {
    let record: ActivityRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(URL(fileURLWithPath: record.sourcePath).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(record.destinationPath.map { "\(record.sourcePath) → \($0)" } ?? record.sourcePath)
            if let message = record.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// ✓ / ⚠︎ / ✕ with a VoiceOver label.
private struct ResultMark: View {
    let result: ActivityResultKind

    var body: some View {
        switch result {
        case .success:
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Succeeded"))
        case .skipped:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityLabel(Text("Skipped"))
        case .failed:
            Image(systemName: "xmark")
                .foregroundStyle(.red)
                .accessibilityLabel(Text("Failed"))
        }
    }
}

/// Finds and reveals the file an entry refers to.
enum ActivityFile {
    /// The destination if it still exists, else the source.
    static func existingPath(of record: ActivityRecord) -> String? {
        [record.destinationPath, record.sourcePath]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func reveal(_ record: ActivityRecord) {
        guard let path = existingPath(of: record) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
