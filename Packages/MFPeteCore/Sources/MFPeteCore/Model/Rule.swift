import Foundation

/// A named automation: trigger + scope + conditions + actions + options
/// (spec §2, §9). Run stats (last run, file count, last error) are derived
/// from the activity log and are not stored here.
public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Dashboard position. Sets run order when several rules match (D5).
    public var order: Int
    public var scope: [FolderRef]
    public var trigger: Trigger
    public var conditions: ConditionGroup
    public var actions: [Action]
    public var options: RuleOptions
    public var notes: String
    public var createdAt: Date
    public var modifiedAt: Date

    /// Pass `name: nil` to auto-generate one from scope and actions (spec §7).
    public init(
        id: UUID = UUID(),
        name: String? = nil,
        isEnabled: Bool = true,
        order: Int = 0,
        scope: [FolderRef] = [],
        trigger: Trigger = .fileAdded,
        conditions: ConditionGroup = ConditionGroup(),
        actions: [Action] = [],
        options: RuleOptions = RuleOptions(),
        notes: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name ?? Rule.autoName(scope: scope, actions: actions)
        self.isEnabled = isEnabled
        self.order = order
        self.scope = scope
        self.trigger = trigger
        self.conditions = conditions
        self.actions = actions
        self.options = options
        self.notes = notes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, order, scope, trigger, conditions, actions
        case options, notes, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        scope = try container.decodeIfPresent([FolderRef].self, forKey: .scope) ?? []
        trigger = try container.decode(Trigger.self, forKey: .trigger)
        conditions = try container.decodeIfPresent(ConditionGroup.self, forKey: .conditions) ?? ConditionGroup()
        actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? []
        options = try container.decodeIfPresent(RuleOptions.self, forKey: .options) ?? RuleOptions()
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt

        // A rule with parts this version does not understand must not run (spec §9).
        if containsUnknownElements {
            isEnabled = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(order, forKey: .order)
        try container.encode(scope, forKey: .scope)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(conditions, forKey: .conditions)
        try container.encode(actions, forKey: .actions)
        try container.encode(options, forKey: .options)
        try container.encode(notes, forKey: .notes)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }

    /// True if any action or condition is an unknown placeholder from a newer
    /// app version.
    public var containsUnknownElements: Bool {
        actions.contains(where: \.isUnknown) || conditions.containsUnknown
    }

    /// Auto-generated name, "Downloads: Move to Trash" (spec §7).
    public static func autoName(scope: [FolderRef], actions: [Action]) -> String {
        let folder = scope.first?.displayName
        let action = actions.first?.displayName
        switch (folder, action) {
        case let (folder?, action?): return "\(folder): \(action)"
        case let (folder?, nil): return folder
        case let (nil, action?): return action
        case (nil, nil): return localized("New Rule")
        }
    }

    /// Copy with every folder path abbreviated with `~`, for export (spec §9).
    public func tildeAbbreviated(home: String = FolderRef.homePath) -> Rule {
        var copy = self
        let transform = { (folder: FolderRef) in FolderRef(path: folder.tildeAbbreviated(home: home)) }
        copy.scope = scope.map(transform)
        copy.actions = actions.map { $0.mappingFolders(transform) }
        return copy
    }
}

/// Per-rule options (spec §7).
public struct RuleOptions: Codable, Hashable, Sendable {
    public var includeSubfolders: Bool
    public var includeHidden: Bool
    /// "Stop processing other rules for matched files" (D5).
    public var stopOtherRules: Bool
    public var notifyEachRun: Bool

    public init(
        includeSubfolders: Bool = false,
        includeHidden: Bool = false,
        stopOtherRules: Bool = false,
        notifyEachRun: Bool = false
    ) {
        self.includeSubfolders = includeSubfolders
        self.includeHidden = includeHidden
        self.stopOtherRules = stopOtherRules
        self.notifyEachRun = notifyEachRun
    }

    private enum CodingKeys: String, CodingKey {
        case includeSubfolders, includeHidden, stopOtherRules, notifyEachRun
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includeSubfolders = try container.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? false
        includeHidden = try container.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? false
        stopOtherRules = try container.decodeIfPresent(Bool.self, forKey: .stopOtherRules) ?? false
        notifyEachRun = try container.decodeIfPresent(Bool.self, forKey: .notifyEachRun) ?? false
    }
}
