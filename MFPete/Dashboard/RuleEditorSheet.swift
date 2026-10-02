import MFPeteCore
import SwiftUI

/// Placeholder editor sheet. Works on a draft copy: Save writes it back,
/// Cancel discards it. The full When / If / Then editor replaces the body in
/// Phase 5; Save, Save & Run, ⌘S, and Esc already behave as specified.
struct RuleEditorSheet: View {
    let isNew: Bool
    @State private var draft: Rule

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    init(rule: Rule, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: rule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Rule" : "Edit Rule")
                .font(.title2.bold())
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            Text(RuleSummarizer().sentence(for: draft))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Enabled", isOn: $draft.isEnabled)
            Text("Folders, conditions, and actions can be edited in a coming update.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save & Run") { save(thenRun: true) }
                    .disabled(draft.trigger == .fileRemoved)
                    .help(draft.trigger == .fileRemoved
                          ? Text("Run Now is not available for “File removed” rules")
                          : Text("Save the rule, then run it once"))
                Button("Save Rule") { save(thenRun: false) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func save(thenRun: Bool) {
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
}
