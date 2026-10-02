import AppKit
import MFPeteCore
import OSLog
import SwiftData
import SwiftUI

/// App-wide UI state. Owns the loaded rules and persists every change
/// through `RulesStore`.
@MainActor
@Observable
final class AppState {
    private(set) var rules: [Rule] = []
    /// Set when `rules.json` could not be read. Shown as an alert (Phase 6).
    var loadIssue: RulesStore.LoadIssue?
    /// Rules loaded disabled because they contain unknown parts.
    var disabledUnknownRules: [String] = []
    var lastSaveError: String?
    /// Expands `~` in template folders. UI tests point it at a temporary folder.
    var templateHome = FolderRef.homePath

    /// Runs rules and mirrors engine state for the UI.
    let engineController: EngineController
    @ObservationIgnored let modelContainer: ModelContainer
    @ObservationIgnored private let rulesStore: RulesStore
    @ObservationIgnored private let logger = Logger(subsystem: "com.mftpete.MFPete", category: "AppState")
    /// Set by a scene view, so code outside SwiftUI (the app delegate) can
    /// open windows. A window asked for before then opens once it is set.
    @ObservationIgnored var windowOpener: ((String) -> Void)? {
        didSet {
            guard let windowOpener, let pending = pendingWindow else { return }
            pendingWindow = nil
            windowOpener(pending)
        }
    }
    @ObservationIgnored private var pendingWindow: String?

    init(
        rulesStore: RulesStore = RulesStore(),
        modelContainer: ModelContainer? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.rulesStore = rulesStore
        self.modelContainer = modelContainer ?? AppState.makeModelContainer()
        engineController = EngineController(modelContainer: self.modelContainer, defaults: defaults)

        let result = rulesStore.load()
        rules = result.rules
        loadIssue = result.issue
        disabledUnknownRules = result.disabledUnknownRules
        if let issue = result.issue {
            logger.error("Rules file problem on load: \(String(describing: issue))")
        }
        engineController.setRules(rules)
        engineController.onPromptNeeded = { [weak self] in
            self?.openWindow(WindowID.rules)
        }
    }

    var activeRuleCount: Int {
        rules.filter(\.isEnabled).count
    }

    func rule(_ id: Rule.ID) -> Rule? {
        rules.first { $0.id == id }
    }

    // MARK: - Rule changes

    func add(_ rule: Rule) {
        var rule = rule
        rule.order = rules.count
        rules.append(rule)
        persist()
    }

    func update(_ rule: Rule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var rule = rule
        rule.modifiedAt = Date()
        rules[index] = rule
        persist()
    }

    func setEnabled(_ isEnabled: Bool, for id: Rule.ID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = isEnabled
        rules[index].modifiedAt = Date()
        persist()
    }

    /// Inserts a disabled copy right below the original.
    @discardableResult
    func duplicate(_ id: Rule.ID) -> Rule? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        let original = rules[index]
        let now = Date()
        var copy = original
        copy.id = UUID()
        copy.name = String(localized: "\(original.name) copy")
        copy.isEnabled = false
        copy.createdAt = now
        copy.modifiedAt = now
        rules.insert(copy, at: index + 1)
        renumber()
        persist()
        return copy
    }

    func delete(_ ids: Set<Rule.ID>) {
        rules.removeAll { ids.contains($0.id) }
        renumber()
        persist()
    }

    /// Drag reorder. Order sets run order (D5).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        renumber()
        persist()
    }

    private func renumber() {
        for index in rules.indices {
            rules[index].order = index
        }
    }

    private func persist() {
        engineController.setRules(rules)
        do {
            try rulesStore.save(rules)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
            logger.error("Could not save rules: \(error.localizedDescription)")
        }
    }

    // MARK: - Windows

    /// Opens a window and brings the app to front (needed in accessory mode).
    func openWindow(_ id: String) {
        if let windowOpener {
            windowOpener(id)
        } else {
            pendingWindow = id
        }
        AppActivation.bringToFront()
    }

    // MARK: - Activity log

    func pruneActivityLog() {
        let store = ActivityStore(modelContainer: modelContainer)
        Task.detached(priority: .utility) {
            try? await store.prune()
        }
    }

    private static func makeModelContainer() -> ModelContainer {
        do {
            return try DataStore.makeContainer()
        } catch {
            Logger(subsystem: "com.mftpete.MFPete", category: "AppState")
                .error("Could not open data store, using memory only: \(error.localizedDescription)")
            do {
                return try DataStore.makeInMemoryContainer()
            } catch {
                fatalError("Could not create in-memory data store: \(error)")
            }
        }
    }
}

/// `UserDefaults` keys for app and engine settings (Settings › Advanced, Phase 6).
enum SettingsKey {
    static let settleDelay = "settleDelay"
    static let bulkThreshold = "bulkGuardThreshold"
    static let isPaused = "isPaused"
}

enum AppActivation {
    /// In accessory mode a newly opened window stays behind other apps unless
    /// the app activates itself.
    static func bringToFront() {
        NSApp.activate()
    }
}
