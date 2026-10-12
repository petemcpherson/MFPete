import Foundation

/// What to do when the destination name already exists (spec §6.3).
public enum ConflictPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Append " 2", " 3", … before the extension (Finder style). Default.
    case keepBoth
    /// Move the existing item to the Trash, then place the new one.
    case replace
    /// Leave the file and log "Skipped: name exists".
    case skip
}

/// One operation on a matching file (spec §6.1). Actions run in order.
public enum Action: Codable, Hashable, Sendable {
    case move(to: FolderRef, onConflict: ConflictPolicy)
    case copy(to: FolderRef, onConflict: ConflictPolicy)
    case rename(pattern: String, onConflict: ConflictPolicy)
    case changeExtension(String)
    case trash
    case sortIntoSubfolder(base: FolderRef, pattern: String)
    case addTags([String])
    case removeTags([String])
    /// `destination` nil = same folder as the archive.
    case unarchive(destination: FolderRef?, trashArchive: Bool)
    /// `withApp` nil = default app.
    case open(withApp: URL?)
    case revealInFinder
    case notify(message: String)
    /// Empties the whole Trash once per run. Not a per-file action: a rule
    /// with it has no folders or conditions and runs on a schedule.
    case emptyTrash
    /// An action from a newer app version. Kept as raw JSON; the containing
    /// rule loads disabled.
    case unknown(JSONValue)

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// Short label used in auto-generated rule names ("Move to Trash").
    public var displayName: String {
        switch self {
        case .move(let folder, _): return localized("Move to \(folder.displayName)")
        case .copy(let folder, _): return localized("Copy to \(folder.displayName)")
        case .rename: return localized("Rename")
        case .changeExtension(let ext): return localized("Change extension to \(ext)")
        case .trash: return localized("Move to Trash")
        case .sortIntoSubfolder: return localized("Sort into subfolders")
        case .addTags: return localized("Add tags")
        case .removeTags: return localized("Remove tags")
        case .unarchive: return localized("Unarchive")
        case .open: return localized("Open")
        case .revealInFinder: return localized("Reveal in Finder")
        case .notify: return localized("Show notification")
        case .emptyTrash: return localized("Empty Trash")
        case .unknown: return localized("Unknown action")
        }
    }

    private enum Kind: String {
        case move, copy, rename, changeExtension, trash, sortIntoSubfolder
        case addTags, removeTags, unarchive, open, revealInFinder, notify, emptyTrash
    }

    private enum CodingKeys: String, CodingKey {
        case type, destination, onConflict, pattern, `extension`, base, tags
        case trashArchive, app, message
    }

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        do {
            self = try Action.decodeKnown(from: decoder)
        } catch is UnknownCaseError {
            self = .unknown(raw)
        }
    }

    private static func decodeKnown(from decoder: Decoder) throws -> Action {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeKnown(Kind.self, forKey: .type) {
        case .move:
            return .move(
                to: try container.decode(FolderRef.self, forKey: .destination),
                onConflict: try container.decodeKnown(ConflictPolicy.self, forKey: .onConflict)
            )
        case .copy:
            return .copy(
                to: try container.decode(FolderRef.self, forKey: .destination),
                onConflict: try container.decodeKnown(ConflictPolicy.self, forKey: .onConflict)
            )
        case .rename:
            return .rename(
                pattern: try container.decode(String.self, forKey: .pattern),
                onConflict: try container.decodeKnown(ConflictPolicy.self, forKey: .onConflict)
            )
        case .changeExtension:
            return .changeExtension(try container.decode(String.self, forKey: .extension))
        case .trash:
            return .trash
        case .sortIntoSubfolder:
            return .sortIntoSubfolder(
                base: try container.decode(FolderRef.self, forKey: .base),
                pattern: try container.decode(String.self, forKey: .pattern)
            )
        case .addTags:
            return .addTags(try container.decode([String].self, forKey: .tags))
        case .removeTags:
            return .removeTags(try container.decode([String].self, forKey: .tags))
        case .unarchive:
            return .unarchive(
                destination: try container.decodeIfPresent(FolderRef.self, forKey: .destination),
                trashArchive: try container.decodeIfPresent(Bool.self, forKey: .trashArchive) ?? false
            )
        case .open:
            let appPath = try container.decodeIfPresent(String.self, forKey: .app)
            return .open(withApp: appPath.map { URL(fileURLWithPath: $0) })
        case .revealInFinder:
            return .revealInFinder
        case .notify:
            return .notify(message: try container.decode(String.self, forKey: .message))
        case .emptyTrash:
            return .emptyTrash
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(let raw) = self {
            try raw.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .move(let folder, let policy):
            try container.encode(Kind.move.rawValue, forKey: .type)
            try container.encode(folder, forKey: .destination)
            try container.encode(policy.rawValue, forKey: .onConflict)
        case .copy(let folder, let policy):
            try container.encode(Kind.copy.rawValue, forKey: .type)
            try container.encode(folder, forKey: .destination)
            try container.encode(policy.rawValue, forKey: .onConflict)
        case .rename(let pattern, let policy):
            try container.encode(Kind.rename.rawValue, forKey: .type)
            try container.encode(pattern, forKey: .pattern)
            try container.encode(policy.rawValue, forKey: .onConflict)
        case .changeExtension(let ext):
            try container.encode(Kind.changeExtension.rawValue, forKey: .type)
            try container.encode(ext, forKey: .extension)
        case .trash:
            try container.encode(Kind.trash.rawValue, forKey: .type)
        case .sortIntoSubfolder(let base, let pattern):
            try container.encode(Kind.sortIntoSubfolder.rawValue, forKey: .type)
            try container.encode(base, forKey: .base)
            try container.encode(pattern, forKey: .pattern)
        case .addTags(let tags):
            try container.encode(Kind.addTags.rawValue, forKey: .type)
            try container.encode(tags, forKey: .tags)
        case .removeTags(let tags):
            try container.encode(Kind.removeTags.rawValue, forKey: .type)
            try container.encode(tags, forKey: .tags)
        case .unarchive(let destination, let trashArchive):
            try container.encode(Kind.unarchive.rawValue, forKey: .type)
            try container.encodeIfPresent(destination, forKey: .destination)
            try container.encode(trashArchive, forKey: .trashArchive)
        case .open(let app):
            try container.encode(Kind.open.rawValue, forKey: .type)
            try container.encodeIfPresent(app?.path, forKey: .app)
        case .revealInFinder:
            try container.encode(Kind.revealInFinder.rawValue, forKey: .type)
        case .notify(let message):
            try container.encode(Kind.notify.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
        case .emptyTrash:
            try container.encode(Kind.emptyTrash.rawValue, forKey: .type)
        case .unknown:
            break
        }
    }

    /// Returns a copy with every folder path transformed (used for tilde
    /// abbreviation on export).
    public func mappingFolders(_ transform: (FolderRef) -> FolderRef) -> Action {
        switch self {
        case .move(let folder, let policy): return .move(to: transform(folder), onConflict: policy)
        case .copy(let folder, let policy): return .copy(to: transform(folder), onConflict: policy)
        case .sortIntoSubfolder(let base, let pattern): return .sortIntoSubfolder(base: transform(base), pattern: pattern)
        case .unarchive(let destination, let trashArchive):
            return .unarchive(destination: destination.map(transform), trashArchive: trashArchive)
        default: return self
        }
    }
}
