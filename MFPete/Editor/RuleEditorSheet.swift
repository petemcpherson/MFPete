import MFPeteCore
import SwiftUI

/// The When / If / Then rule editor (spec §8.3, D11). Works on a draft copy:
/// Save writes it back, Cancel discards it (after a confirm if edited).
struct RuleEditorSheet: View {
    let isNew: Bool
    private let original: Rule
    @State private var draft: Rule
    /// The name follows folders and actions until the user types one (spec §7).
    @State private var nameIsAuto: Bool
    @State private var showsMoreOptions: Bool
    /// Errors show after the first Save attempt; warnings show right away.
    @State private var showsErrors = false
    @State private var confirmDiscard = false
    @State private var preview: PreviewTarget?
    @State private var matchCount = MatchCount.counting
    @State private var sample: FileSnapshot?
    @State private var gate = FolderGate()

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private static let summarizer = RuleSummarizer()
    private static let validator = RuleValidator()

    init(rule: Rule, isNew: Bool) {
        self.isNew = isNew
        original = rule
        _draft = State(initialValue: rule)
        _nameIsAuto = State(initialValue: rule.name == Rule.autoName(scope: rule.scope, actions: rule.actions))
        _showsMoreOptions = State(initialValue: rule.options.stopOtherRules || rule.options.notifyEachRun || !rule.notes.isEmpty)
    }

    private var issues: [RuleIssue] { Self.validator.validate(draft) }
    private var isDirty: Bool { draft != original }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    WhenCard(rule: $draft)
                    if !draft.emptiesTrash {
                        IfCard(rule: $draft, matchCount: matchCount) {
                            preview = PreviewTarget(rule: draft, mode: .matches)
                        }
                    }
                    ThenCard(rule: $draft, sample: sample, issues: actionIssues)
                    ruleIssues
                    moreOptions
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 720)
        .environment(gate)
        .interactiveDismissDisabled()
        .onChange(of: draft.scope) { updateAutoName() }
        .onChange(of: draft.actions) {
            if draft.emptiesTrash { fitEmptyTrash() }
            updateAutoName()
        }
        .task(id: MatchInputs(draft)) { await updateMatchCount() }
        .task(id: SampleInputs(draft)) { await updateSample() }
        .sheet(item: $preview) { PreviewSheet(target: $0) }
        .confirmationDialog("Discard changes to this rule?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert(
            explainerTitle,
            isPresented: Binding(get: { gate.pending != nil }, set: { if !$0 { gate.cancelPending() } }),
            presenting: gate.pending
        ) { _ in
            Button("Continue") { gate.confirmPending() }
            Button("Cancel", role: .cancel) { gate.cancelPending() }
        } message: { pending in
            Text("macOS protects \(pending.location.displayName). When MFPete first opens this folder, macOS asks for permission. Click Allow so the rule can see its files. You can change this later in System Settings › Privacy & Security › Files and Folders.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("Rule name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .accessibilityLabel(Text("Rule name"))
                    .accessibilityIdentifier("ruleName")
                Toggle("Enabled", isOn: $draft.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text(Self.summarizer.sentence(for: draft))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ruleSummary")
        }
        .padding(16)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft.name },
            set: { newValue in
                draft.name = newValue
                nameIsAuto = newValue.isEmpty
            }
        )
    }

    /// Empty Trash acts on the whole Trash on a schedule: drop folders and
    /// conditions, and switch a file-event trigger to weekly.
    private func fitEmptyTrash() {
        draft.scope = []
        draft.conditions = ConditionGroup()
        if draft.trigger.isFileEvent {
            draft.trigger = TriggerType.weekly.makeTrigger(from: draft.trigger)
        }
    }

    private func updateAutoName() {
        guard nameIsAuto else { return }
        draft.name = Rule.autoName(scope: draft.scope.filter { !$0.path.isEmpty }, actions: draft.actions)
    }

    // MARK: - Issues and options

    private var actionIssues: [Int: [RuleIssue]] {
        Dictionary(grouping: visibleIssues.filter { $0.actionIndex != nil }) { $0.actionIndex ?? 0 }
    }

    private var visibleIssues: [RuleIssue] {
        issues.filter { showsErrors || $0.severity == .warning }
    }

    @ViewBuilder
    private var ruleIssues: some View {
        let general = visibleIssues.filter { $0.actionIndex == nil }
        if !general.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(general.enumerated()), id: \.offset) { _, issue in
                    EditorHint(text: issue.message, style: issue.severity == .error ? .error : .warning)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                general.contains { $0.code == .destructiveWithoutConditions } ? Color.orange.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("editorIssues")
        }
    }

    private var moreOptions: some View {
        DisclosureGroup("More options", isExpanded: $showsMoreOptions) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Stop processing other rules for matched files", isOn: $draft.options.stopOtherRules)
                Toggle("Notify on each run", isOn: $draft.options.notifyEachRun)
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if showsErrors, issues.contains(where: { $0.severity == .error }) {
                EditorHint(text: String(localized: "Fix the marked problems to save."), style: .error)
            }
            Spacer()
            Button("Cancel", role: .cancel) { cancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cancelEditor")
            Button("Save & Run") { save(thenRun: true) }
                .disabled(draft.trigger == .fileRemoved)
                .help(draft.trigger == .fileRemoved
                      ? Text("Run Now is not available for “File removed” rules")
                      : Text("Save the rule, then run it once"))
                .accessibilityIdentifier("saveAndRun")
            Button("Save Rule") { save(thenRun: false) }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("saveRule")
        }
        .padding(16)
    }

    private func cancel() {
        if isDirty {
            confirmDiscard = true
        } else {
            dismiss()
        }
    }

    private func save(thenRun: Bool) {
        guard !Self.validator.hasErrors(draft) else {
            showsErrors = true
            return
        }
        var rule = draft
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
            rule.name = Rule.autoName(scope: rule.scope, actions: rule.actions)
        }
        if isNew {
            appState.add(rule)
        } else {
            appState.update(rule)
        }
        dismiss()
        if thenRun {
            appState.engineController.startRun(rule.id)
        }
    }

    // MARK: - Live match count and sample file

    /// What the match count depends on. Actions do not change which files match.
    private struct MatchInputs: Hashable {
        let scope: [FolderRef]
        let trigger: Trigger
        let conditions: ConditionGroup
        let options: RuleOptions

        init(_ rule: Rule) {
            scope = rule.scope
            trigger = rule.trigger
            conditions = rule.conditions
            options = rule.options
        }
    }

    private struct SampleInputs: Hashable {
        let scope: [FolderRef]
        let options: RuleOptions

        init(_ rule: Rule) {
            scope = rule.scope
            options = rule.options
        }
    }

    /// Debounced (~400 ms) dry run against the current scope.
    private func updateMatchCount() async {
        if draft.emptiesTrash { return }
        if draft.trigger == .fileRemoved {
            matchCount = .unavailable(String(localized: "“File removed” rules act on files that are gone, so there is nothing to count."))
            return
        }
        var rule = draft
        rule.scope = rule.scope.filter { !$0.path.isEmpty }
        guard !rule.scope.isEmpty else {
            matchCount = .unavailable(String(localized: "Choose a folder to see matching files."))
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        matchCount = .counting
        let results = await appState.engineController.plan(rule)
        guard !Task.isCancelled else { return }
        matchCount = .counted(total: results.count, alreadyProcessed: results.filter(\.alreadyProcessed).count)
    }

    /// First file in the rule's folders, for pattern previews.
    private func updateSample() async {
        let folders = draft.scope.filter { !$0.path.isEmpty }
        let options = draft.options
        let snapshot = await Task.detached(priority: .utility) { () -> FileSnapshot? in
            for folder in folders where FolderHealth.check(folder) == .ok {
                let candidates = FolderScanner.candidates(in: folder, options: options)
                let snapshots = candidates.prefix(20).compactMap { try? FileSnapshot(reading: $0) }
                if let file = snapshots.first(where: { !$0.isDirectory }) ?? snapshots.first {
                    return file
                }
            }
            return nil
        }.value
        guard !Task.isCancelled else { return }
        sample = snapshot
    }

    private var explainerTitle: String {
        guard let pending = gate.pending else { return "" }
        return String(localized: "MFPete Needs Access to \(pending.location.displayName)")
    }
}
