import Foundation

/// Starter rules shown in the dashboard's empty state and the `+` menu
/// (spec §8.6). Each one opens the editor pre-filled; the user confirms the
/// folders and saves.
public struct RuleTemplate: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var systemImage: String
    private var build: Builder

    /// Wraps the factory so the template stays `Hashable`.
    private struct Builder: Hashable, Sendable {
        let id: String
        let make: @Sendable (String) -> Rule

        static func == (lhs: Builder, rhs: Builder) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    init(id: String, title: String, subtitle: String, systemImage: String, make: @escaping @Sendable (String) -> Rule) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.build = Builder(id: id, make: make)
    }

    /// A new rule with a fresh ID. `home` expands the template's `~` paths.
    public func makeRule(home: String = FolderRef.homePath) -> Rule {
        build.make(home)
    }

    /// The spec's six templates, in its order, then Empty Trash.
    public static let all: [RuleTemplate] = [
        cleanDownloads, unzipDownloads, archiveScreenshots, keepDesktopClean, sortByType, textToMarkdown,
        emptyTrashWeekly,
    ]

    /// The three shown as buttons in the empty dashboard.
    public static let featured: [RuleTemplate] = [cleanDownloads, unzipDownloads, keepDesktopClean]

    // MARK: - Templates

    /// Spec template 1 mixes "file added" with a daily schedule. An age
    /// condition only makes sense on a schedule (spec §4.2), so this is a
    /// daily rule.
    public static let cleanDownloads = RuleTemplate(
        id: "cleanDownloads",
        title: localized("Clean up Downloads"),
        subtitle: localized("Trash old disk images and archives every day"),
        systemImage: "trash"
    ) { home in
        Rule(
            name: localized("Clean up Downloads"),
            scope: [FolderRef(expanding: "~/Downloads", home: home)],
            trigger: .daily(hour: 9, minute: 0),
            conditions: ConditionGroup(items: [
                .group(ConditionGroup(match: .any, items: [
                    .condition(Condition(attribute: .kind, op: .is, value: .kind(.diskImage))),
                    .condition(Condition(attribute: .kind, op: .is, value: .kind(.archive))),
                ])),
                .condition(Condition(attribute: .dateAdded, op: .notInTheLast, value: .duration(7, .days))),
            ]),
            actions: [.trash]
        )
    }

    public static let unzipDownloads = RuleTemplate(
        id: "unzipDownloads",
        title: localized("Unzip downloads"),
        subtitle: localized("Extract new zip files and trash the archive"),
        systemImage: "doc.zipper"
    ) { home in
        Rule(
            name: localized("Unzip downloads"),
            scope: [FolderRef(expanding: "~/Downloads", home: home)],
            conditions: ConditionGroup(items: [
                .condition(Condition(attribute: .extension, op: .is, value: .text("zip"))),
            ]),
            actions: [.unarchive(destination: nil, trashArchive: true)]
        )
    }

    public static let archiveScreenshots = RuleTemplate(
        id: "archiveScreenshots",
        title: localized("Archive old screenshots"),
        subtitle: localized("Move screenshots older than 3 days into Archive"),
        systemImage: "camera.viewfinder"
    ) { home in
        Rule(
            name: localized("Archive old screenshots"),
            scope: [FolderRef(expanding: "~/Screenshots", home: home)],
            trigger: .daily(hour: 18, minute: 0),
            conditions: ConditionGroup(items: [
                .condition(.filesOnly),
                .condition(Condition(attribute: .name, op: .startsWith, value: .text("Screenshot"))),
                .condition(Condition(attribute: .dateAdded, op: .notInTheLast, value: .duration(3, .days))),
            ]),
            actions: [.move(to: FolderRef(expanding: "~/Screenshots/Archive", home: home), onConflict: .keepBoth)]
        )
    }

    public static let keepDesktopClean = RuleTemplate(
        id: "keepDesktopClean",
        title: localized("Keep Desktop clean"),
        subtitle: localized("Move new Desktop files into Desktop Inbox"),
        systemImage: "menubar.dock.rectangle"
    ) { home in
        Rule(
            name: localized("Keep Desktop clean"),
            scope: [FolderRef(expanding: "~/Desktop", home: home)],
            conditions: ConditionGroup(items: [
                .condition(.filesOnly),
                .condition(Condition(attribute: .kind, op: .isNot, value: .kind(.alias))),
            ]),
            actions: [.move(to: FolderRef(expanding: "~/Desktop Inbox", home: home), onConflict: .keepBoth)]
        )
    }

    /// No folder is pre-set: the user picks the folder to sort.
    public static let sortByType = RuleTemplate(
        id: "sortByType",
        title: localized("Sort by type"),
        subtitle: localized("Sort new files into subfolders by extension"),
        systemImage: "square.grid.3x1.folder.badge.plus"
    ) { _ in
        Rule(
            name: localized("Sort by type"),
            conditions: ConditionGroup(items: [.condition(.filesOnly)]),
            actions: [.sortIntoSubfolder(base: FolderRef(path: ""), pattern: "{extension}")]
        )
    }

    /// No folders are pre-set: the user picks the source and the vault.
    public static let textToMarkdown = RuleTemplate(
        id: "textToMarkdown",
        title: localized("Text to Markdown"),
        subtitle: localized("Rename .txt files to .md and move them"),
        systemImage: "doc.text"
    ) { _ in
        Rule(
            name: localized("Text to Markdown"),
            conditions: ConditionGroup(items: [
                .condition(Condition(attribute: .extension, op: .is, value: .text("txt"))),
            ]),
            actions: [.changeExtension("md"), .move(to: FolderRef(path: ""), onConflict: .keepBoth)]
        )
    }

    /// No folders or conditions: the whole Trash, every Monday.
    public static let emptyTrashWeekly = RuleTemplate(
        id: "emptyTrashWeekly",
        title: localized("Empty Trash weekly"),
        subtitle: localized("Permanently delete everything in the Trash every Monday"),
        systemImage: "trash.slash"
    ) { _ in
        Rule(
            name: localized("Empty Trash weekly"),
            trigger: .weekly(weekdays: [2], hour: 9, minute: 0),
            actions: [.emptyTrash]
        )
    }
}
