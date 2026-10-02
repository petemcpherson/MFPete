import MFPeteCore
import SwiftUI

/// The Rules window (spec §8.2): one list of rules with search, filter,
/// sort, per-row Run Now and `⋯` menu, and the engine's prompts.
struct RulesWindow: View {
    @Environment(AppState.self) private var appState
    @State private var query = RuleListQuery()
    @State private var selection: Set<Rule.ID> = []
    @State private var editing: EditorTarget?
    @State private var preview: PreviewTarget?
    @State private var pendingDelete: Set<Rule.ID>?

    private var controller: EngineController { appState.engineController }

    private var visibleRules: [Rule] {
        let controller = controller
        return query.apply(to: appState.rules, stats: controller.stats) { controller.status(of: $0).isError }
    }

    var body: some View {
        withPrompts(withSheets(decoratedList))
    }

    private var ruleList: some View {
        List(selection: $selection) {
            ForEach(visibleRules) { rule in
                RuleRow(rule: rule) { perform($0, on: rule) }
                    .tag(rule.id)
            }
            .onMove(perform: moveAction)
        }
        .contextMenu(forSelectionType: Rule.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click or Return opens the editor.
            if ids.count == 1, let id = ids.first, let rule = appState.rule(id) {
                openEditor(rule)
            }
        }
        .onDeleteCommand {
            if !selection.isEmpty { pendingDelete = selection }
        }
    }

    private var decoratedList: some View {
        ruleList
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) { reorderHint }
        .overlay { emptyState(visible: visibleRules) }
        .searchable(text: $query.searchText, placement: .toolbar, prompt: Text("Search Rules"))
        .toolbar { toolbar }
        .navigationTitle("Rules")
        .task { await controller.refresh() }
        .frame(minWidth: 580, minHeight: 380)
    }

    private func withSheets(_ content: some View) -> some View {
        content
        .sheet(item: $editing) { target in
            RuleEditorSheet(rule: target.rule, isNew: target.isNew)
        }
        .sheet(item: $preview) { target in
            PreviewSheet(target: target)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { ids in
            Button("Delete", role: .destructive) {
                appState.delete(ids)
                selection.subtract(ids)
            }
        } message: { _ in
            Text("This cannot be undone. Files the rule already handled stay where they are.")
        }
    }

    private func withPrompts(_ content: some View) -> some View {
        content
        .alert(
            "Run on Many Files?",
            isPresented: promptBinding(controller.bulkRequests.first != nil),
            presenting: controller.bulkRequests.first
        ) { request in
            Button("Preview") { showPreview(ruleID: request.ruleID, mode: .bulk(request)) }
            Button("Run") { controller.resolveBulk(request, approve: true) }
            Button("Cancel", role: .cancel) { controller.resolveBulk(request, approve: false) }
        } message: { request in
            Text("“\(request.ruleName)” wants to act on \(request.fileCount) files.")
        }
        .alert(
            "Apply to Existing Files?",
            isPresented: promptBinding(controller.bulkRequests.isEmpty && controller.applyRequests.first != nil),
            presenting: controller.applyRequests.first
        ) { request in
            Button("Preview") { showPreview(ruleID: request.ruleID, mode: .applyExisting(request)) }
            Button("Apply") { controller.resolveApplyExisting(request, apply: true) }
            Button("Only New Files", role: .cancel) { controller.resolveApplyExisting(request, apply: false) }
                .keyboardShortcut(.defaultAction)
        } message: { request in
            Text("Apply “\(request.ruleName)” to the \(request.fileCount) files already in \(ListFormatter.localizedString(byJoining: request.folderNames)) that match?")
        }
    }

    // MARK: - Commands

    private func perform(_ command: RuleCommand, on rule: Rule) {
        switch command {
        case .edit:
            openEditor(rule)
        case .runNow:
            controller.startRun(rule.id)
        case .preview:
            preview = PreviewTarget(rule: rule, mode: .matches)
        case .duplicate:
            if let copy = appState.duplicate(rule.id) {
                selection = [copy.id]
            }
        case .export:
            RuleExporter.export([rule], suggestedName: rule.name)
        case .runAgainOnAllFiles:
            controller.runAgainOnAllFiles(rule.id)
        case .delete:
            pendingDelete = [rule.id]
        }
    }

    private func openEditor(_ rule: Rule) {
        controller.clearError(rule.id)
        editing = EditorTarget(rule: rule, isNew: false)
    }

    private func newRule(from template: RuleTemplate? = nil) {
        editing = EditorTarget(rule: template?.makeRule() ?? Rule(), isNew: true)
    }

    /// Drag reorder, only on the full list in manual order.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard query.allowsReorder else { return nil }
        let appState = appState
        return { source, destination in
            appState.move(fromOffsets: source, toOffset: destination)
        }
    }

    private func showPreview(ruleID: Rule.ID, mode: PreviewTarget.Mode) {
        guard let rule = appState.rule(ruleID) else { return }
        preview = PreviewTarget(rule: rule, mode: mode)
    }

    /// Engine prompts show only while no sheet is up. Dismissal happens by
    /// answering, which removes the request.
    private func promptBinding(_ hasRequest: Bool) -> Binding<Bool> {
        Binding(get: { hasRequest && preview == nil && editing == nil }, set: { _ in })
    }

    private var deleteTitle: String {
        guard let ids = pendingDelete else { return "" }
        if ids.count == 1, let rule = ids.first.flatMap(appState.rule) {
            return String(localized: "Delete “\(rule.name)”?")
        }
        return String(localized: "Delete \(ids.count) Rules?")
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<Rule.ID>) -> some View {
        if ids.count == 1, let id = ids.first, let rule = appState.rule(id) {
            RuleMenuItems(rule: rule, isRunning: controller.isRunning(id)) { perform($0, on: rule) }
        } else if ids.count > 1 {
            Button("Delete \(ids.count) Rules…", role: .destructive) { pendingDelete = ids }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Status", selection: $query.status) {
                    ForEach(RuleListQuery.StatusFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Trigger", selection: $query.trigger) {
                    ForEach(RuleListQuery.TriggerFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Folder", selection: $query.folder) {
                    Text("All Folders").tag(String?.none)
                    ForEach(RuleListQuery.folders(in: appState.rules), id: \.path) { folder in
                        Text(folder.displayName).tag(Optional(folder.path))
                    }
                }
                .pickerStyle(.inline)
                if query.isFiltering {
                    Divider()
                    Button("Clear Filters") { query.clearFilters() }
                }
            } label: {
                Label(
                    "Filter",
                    systemImage: query.isFiltering
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
            }
            .help("Filter rules")

            Menu {
                Picker("Sort By", selection: $query.sort) {
                    ForEach(RuleListQuery.Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort rules")

            // The Activity window arrives with the activity log (Phase 6).
            Button {} label: {
                Label("Activity", systemImage: "list.bullet.rectangle")
            }
            .disabled(true)
            .help("Activity log")

            Menu {
                Button("New Rule") { newRule() }
                Menu("New from Template") {
                    ForEach(RuleTemplate.all) { template in
                        Button(template.title) { newRule(from: template) }
                    }
                }
            } label: {
                Label("Add Rule", systemImage: "plus")
            } primaryAction: {
                newRule()
            }
            .help("New rule")
            .accessibilityIdentifier("addRule")
        }
    }

    // MARK: - Banners and empty states

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if controller.isPaused {
                Banner(systemImage: "pause.circle.fill", text: "All rules are paused. Run Now still works.") {
                    Button("Resume") { controller.setPaused(false) }
                }
            }
            if controller.offerScanAfterResume {
                Banner(systemImage: "arrow.clockwise.circle.fill", text: "Rules resumed. Files added while paused were not processed.") {
                    Button("Scan Now") { controller.scanAfterResume() }
                    Button("Dismiss") { controller.offerScanAfterResume = false }
                }
            }
            if let error = appState.lastSaveError {
                Banner(systemImage: "exclamationmark.triangle.fill", text: "Could not save rules: \(error)") {}
            }
        }
    }

    @ViewBuilder
    private var reorderHint: some View {
        if !appState.rules.isEmpty && !query.allowsReorder {
            Text(query.sort == .manual
                 ? "Clear search and filters to drag rules into a new order."
                 : "Drag to reorder works only with Manual sort. Rules still run in manual order.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(.bar)
        }
    }

    @ViewBuilder
    private func emptyState(visible: [Rule]) -> some View {
        if appState.rules.isEmpty {
            EmptyRulesView(onTemplate: { newRule(from: $0) }, onBlank: { newRule() })
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label("No Matching Rules", systemImage: "magnifyingglass")
            } description: {
                Text("No rules match your search and filters.")
            } actions: {
                Button("Clear Filters") { query.clearFilters() }
            }
        }
    }
}

/// A rule being edited in the sheet.
struct EditorTarget: Identifiable {
    var rule: Rule
    var isNew: Bool
    var id: Rule.ID { rule.id }
}

/// One-line notice above the list.
private struct Banner<Actions: View>: View {
    let systemImage: String
    let text: LocalizedStringKey
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
            Spacer()
            actions
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

/// Empty dashboard: short message, three templates, and a blank rule (spec §8.2).
private struct EmptyRulesView: View {
    let onTemplate: (RuleTemplate) -> Void
    let onBlank: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No Rules Yet")
                .font(.title2.bold())
            Text("A rule watches a folder and tidies new files for you. Start from a template:")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(RuleTemplate.featured) { template in
                    Button { onTemplate(template) } label: {
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
                }
            }
            .frame(width: 340)
            Button("Create Blank Rule", action: onBlank)
                .buttonStyle(.link)
        }
        .padding(24)
    }
}
