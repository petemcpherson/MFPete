import AppKit
import MFPeteCore
import SwiftUI
import UniformTypeIdentifiers

/// THEN: the ordered action list with per-action parameters (spec §8.3).
struct ThenCard: View {
    @Binding var rule: Rule
    /// A file from the rule's folders, for pattern previews.
    let sample: FileSnapshot?
    /// Messages from the validator, by action index.
    let issues: [Int: [RuleIssue]]

    @State private var dropTarget: Int?

    var body: some View {
        EditorCard(title: "THEN") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rule.actions.enumerated()), id: \.offset) { index, _ in
                    ActionRow(
                        number: index + 1,
                        action: actionBinding(index),
                        allowedTypes: allowedTypes(current: rule.actions[index].type),
                        sample: sample,
                        issues: issues[index] ?? [],
                        onRemove: { remove(index) }
                    )
                    .padding(.top, dropTarget == index ? 6 : 0)
                    .overlay(alignment: .top) {
                        if dropTarget == index {
                            Rectangle().fill(Color.accentColor).frame(height: 2)
                        }
                    }
                    .dropDestination(for: String.self) { payload, _ in
                        guard let source = payload.first.flatMap(Self.sourceIndex) else { return false }
                        move(from: source, to: index)
                        return true
                    } isTargeted: { targeted in
                        dropTarget = targeted ? index : (dropTarget == index ? nil : dropTarget)
                    }
                    .accessibilityActions {
                        if index > 0 {
                            Button("Move Up") { move(from: index, to: index - 1) }
                        }
                        if index < rule.actions.count - 1 {
                            Button("Move Down") { move(from: index, to: index + 1) }
                        }
                    }
                    if index < rule.actions.count - 1 {
                        Divider()
                    }
                }
            }
            // Empty Trash is always the only action.
            if !rule.emptiesTrash {
                Menu {
                    ForEach(allowedTypes(current: nil)) { type in
                        Button(type.displayName) { rule.actions.append(type.makeAction()) }
                    }
                } label: {
                    Label("Add Action", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .accessibilityIdentifier("addAction")
            }
            if rule.trigger == .fileRemoved {
                EditorHint(text: String(localized: "The file is already gone when this rule runs, so only Show notification is available."))
            }
        }
    }

    /// "File removed" rules allow only actions that need no file (spec §3.1).
    /// Empty Trash is offered only where it would be the rule's only action.
    private func allowedTypes(current: ActionType?) -> [ActionType] {
        ActionType.allCases
            .filter { rule.trigger != .fileRemoved || $0.worksWithoutFile || $0 == current }
            .filter { $0 != .emptyTrash || rule.actions.count <= (current == nil ? 0 : 1) }
    }

    private func actionBinding(_ index: Int) -> Binding<Action> {
        Binding(
            get: { rule.actions.indices.contains(index) ? rule.actions[index] : .trash },
            set: { newValue in
                guard rule.actions.indices.contains(index) else { return }
                rule.actions[index] = newValue
            }
        )
    }

    private func remove(_ index: Int) {
        guard rule.actions.indices.contains(index) else { return }
        rule.actions.remove(at: index)
    }

    /// Moves the action at `source` so it ends up at index `destination`.
    private func move(from source: Int, to destination: Int) {
        guard rule.actions.indices.contains(source), source != destination else { return }
        rule.actions.move(fromOffsets: IndexSet(integer: source), toOffset: destination > source ? destination + 1 : destination)
    }

    static let dragPrefix = "mfpete-action:"

    static func sourceIndex(_ payload: String) -> Int? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        return Int(payload.dropFirst(dragPrefix.count))
    }
}

private struct ActionRow: View {
    let number: Int
    @Binding var action: Action
    let allowedTypes: [ActionType]
    let sample: FileSnapshot?
    let issues: [RuleIssue]
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(number).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let type = action.type {
                    Picker("Action", selection: Binding(
                        get: { type },
                        set: { if $0 != type { action = $0.makeAction() } }
                    )) {
                        ForEach(allowedTypes) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Action \(number)"))
                } else {
                    Text("Action not supported by this version")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RowIconButton(systemImage: "minus.circle", label: "Remove action", action: onRemove)
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .draggable(ThenCard.dragPrefix + String(number - 1))
                    .help("Drag to reorder")
                    .accessibilityLabel(Text("Reorder"))
            }
            ActionParameters(action: $action, sample: sample)
                .padding(.leading, 22)
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                EditorHint(text: issue.message, style: issue.severity == .error ? .error : .warning)
                    .padding(.leading, 22)
            }
        }
    }
}

private struct ActionParameters: View {
    @Binding var action: Action
    let sample: FileSnapshot?

    private let renderer = PatternRenderer()

    var body: some View {
        switch action {
        case .move(let folder, let policy):
            folderAndPolicy(folder, policy) { action = .move(to: $0, onConflict: $1) }
        case .copy(let folder, let policy):
            folderAndPolicy(folder, policy) { action = .copy(to: $0, onConflict: $1) }
        case .rename(let pattern, let policy):
            VStack(alignment: .leading, spacing: 6) {
                PatternField(
                    placeholder: "{name}.{extension}",
                    pattern: Binding(get: { pattern }, set: { action = .rename(pattern: $0, onConflict: policy) }),
                    preview: renderedName
                )
                conflictPicker(policy) { action = .rename(pattern: pattern, onConflict: $0) }
            }
        case .changeExtension(let ext):
            HStack {
                Text("New extension")
                TextField("md", text: Binding(get: { ext }, set: { action = .changeExtension($0) }))
                    .frame(width: 100)
            }
        case .sortIntoSubfolder(let base, let pattern):
            VStack(alignment: .leading, spacing: 6) {
                FolderField(folder: base, placeholder: "Choose the base folder…") {
                    action = .sortIntoSubfolder(base: $0, pattern: pattern)
                }
                PatternField(
                    placeholder: "{year}/{month}",
                    pattern: Binding(get: { pattern }, set: { action = .sortIntoSubfolder(base: base, pattern: $0) }),
                    preview: renderedPath
                )
            }
        case .addTags(let tags):
            CommaListField(placeholder: "Tag names, comma separated", items: Binding(get: { tags }, set: { action = .addTags($0) }))
        case .removeTags(let tags):
            CommaListField(placeholder: "Tag names, comma separated", items: Binding(get: { tags }, set: { action = .removeTags($0) }))
        case .unarchive(let destination, let trashArchive):
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Extract into another folder", isOn: Binding(
                    get: { destination != nil },
                    set: { action = .unarchive(destination: $0 ? FolderRef(path: "") : nil, trashArchive: trashArchive) }
                ))
                if let destination {
                    FolderField(folder: destination) { action = .unarchive(destination: $0, trashArchive: trashArchive) }
                }
                Toggle("Move the archive to the Trash afterwards", isOn: Binding(
                    get: { trashArchive },
                    set: { action = .unarchive(destination: destination, trashArchive: $0) }
                ))
                Text("Only .zip archives are supported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .open(let app):
            HStack(spacing: 6) {
                Text("With")
                Text(app.map { FileManager.default.displayName(atPath: $0.path) } ?? String(localized: "Default app"))
                    .foregroundStyle(app == nil ? .secondary : .primary)
                Spacer()
                Button("Choose App…") {
                    if let url = Self.chooseApp() { action = .open(withApp: url) }
                }
                .controlSize(.small)
                if app != nil {
                    Button("Use Default") { action = .open(withApp: nil) }
                        .controlSize(.small)
                }
            }
        case .notify(let message):
            PatternField(
                placeholder: "Message",
                pattern: Binding(get: { message }, set: { action = .notify(message: $0) }),
                preview: renderedText
            )
        case .emptyTrash:
            Text("Permanently deletes everything in the Trash. The first run asks for permission to control Finder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .trash, .revealInFinder, .unknown:
            EmptyView()
        }
    }

    private func folderAndPolicy(
        _ folder: FolderRef,
        _ policy: ConflictPolicy,
        set: @escaping (FolderRef, ConflictPolicy) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FolderField(folder: folder) { set($0, policy) }
            conflictPicker(policy) { set(folder, $0) }
        }
    }

    private func conflictPicker(_ policy: ConflictPolicy, set: @escaping (ConflictPolicy) -> Void) -> some View {
        Picker("If the name exists", selection: Binding(get: { policy }, set: set)) {
            ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .fixedSize()
    }

    private func renderedName(_ pattern: String) -> String? {
        sample.map { renderer.render(pattern, snapshot: $0, now: Date()) }
    }

    private func renderedPath(_ pattern: String) -> String? {
        sample.map { renderer.renderPathSegments(pattern, snapshot: $0, now: Date()).joined(separator: "/") }
    }

    private func renderedText(_ pattern: String) -> String? {
        sample.map { renderer.renderText(pattern, snapshot: $0, now: Date()) }
    }

    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
