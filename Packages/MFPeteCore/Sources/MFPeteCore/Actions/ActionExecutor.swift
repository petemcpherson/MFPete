import Foundation

/// The result of one action on one file.
public struct ActionOutcome: Hashable, Sendable {
    public var result: ActivityResultKind
    /// Where the file is after the action. Later actions use this location.
    /// Nil if the file is gone (trashed, archive trashed, or vanished).
    public var currentURL: URL?
    /// For the activity log (and later undo, D7).
    public var destinationPath: String?
    /// Failure or skip reason.
    public var message: String?
    /// Items this action created or moved into place (copies, extracted
    /// files, new subfolders, the moved file). Used for self-change tracking.
    public var producedURLs: [URL]
    /// Permission was denied. The engine marks the rule "No permission".
    public var permissionDenied: Bool

    public init(
        result: ActivityResultKind,
        currentURL: URL?,
        destinationPath: String? = nil,
        message: String? = nil,
        producedURLs: [URL] = [],
        permissionDenied: Bool = false
    ) {
        self.result = result
        self.currentURL = currentURL
        self.destinationPath = destinationPath
        self.message = message
        self.producedURLs = producedURLs
        self.permissionDenied = permissionDenied
    }

    static func success(_ url: URL?, destination: URL? = nil, produced: [URL] = [], message: String? = nil) -> ActionOutcome {
        ActionOutcome(result: .success, currentURL: url, destinationPath: destination?.path, message: message, producedURLs: produced)
    }

    static func skipped(_ url: URL?, _ message: String) -> ActionOutcome {
        ActionOutcome(result: .skipped, currentURL: url, message: message)
    }
}

/// Errors actions raise themselves (as opposed to file system errors).
enum ActionError: LocalizedError {
    case destinationMissing(String)
    case emptyName
    case unsupportedArchive
    case unarchiveFailed(String)
    case emptyTrashUnavailable
    case emptyTrashPerFile

    var errorDescription: String? {
        switch self {
        case .destinationMissing(let path): return localized("Destination folder missing: \(path)")
        case .emptyName: return localized("The name pattern produced an empty name")
        case .unsupportedArchive: return localized("Only .zip archives can be unarchived")
        case .unarchiveFailed(let reason): return localized("Could not unarchive: \(reason)")
        case .emptyTrashUnavailable: return localized("Empty Trash is not available")
        case .emptyTrashPerFile: return localized("Empty Trash runs once per rule, not on single files")
        }
    }
}

/// Performs rule actions on files (spec §6.1).
///
/// Notes:
/// - A missing destination folder fails the action (auto-create is v1.x,
///   spec §13). Sort into subfolder creates subfolders under an existing base.
/// - Moving a file to the folder it is already in, or renaming it to its
///   current name, succeeds with no change.
/// - Error mapping: file vanished = skipped; permission denied = failed and
///   flagged; disk full = failed.
public struct ActionExecutor: Sendable {
    public var environment: ActionEnvironment
    public var renderer: PatternRenderer
    public var resolver: ConflictResolver

    public init(environment: ActionEnvironment = ActionEnvironment(), resolver: ConflictResolver = ConflictResolver()) {
        self.environment = environment
        self.renderer = PatternRenderer(calendar: environment.calendar)
        self.resolver = resolver
    }

    public func execute(_ action: Action, on url: URL, rule: Rule) async -> ActionOutcome {
        guard let snapshot = try? FileSnapshot(reading: url) else {
            return .skipped(nil, localized("File no longer exists"))
        }
        do {
            return try await perform(action, snapshot: snapshot, rule: rule)
        } catch {
            return ActionExecutor.outcome(for: error, at: url)
        }
    }

    private func perform(_ action: Action, snapshot: FileSnapshot, rule: Rule) async throws -> ActionOutcome {
        let url = snapshot.url
        let now = environment.now()
        switch action {
        case .move(let folder, let policy):
            return try place(url, in: try existingFolder(folder), named: snapshot.fullName, policy: policy, copy: false)

        case .copy(let folder, let policy):
            return try place(url, in: try existingFolder(folder), named: snapshot.fullName, policy: policy, copy: true)

        case .rename(let pattern, let policy):
            return try rename(snapshot, pattern: pattern, policy: policy, now: now)

        case .changeExtension(let newExtension):
            let ext = ConditionEvaluator.normalizeExtension(newExtension)
            let name = ext.isEmpty ? snapshot.name : "\(snapshot.name).\(ext)"
            return try place(url, in: url.deletingLastPathComponent(), named: name, policy: .keepBoth, copy: false)

        case .trash:
            let trashed = try environment.trash(url)
            return .success(nil, destination: trashed)

        case .sortIntoSubfolder(let base, let pattern):
            let baseURL = try existingFolder(base)
            var folder = baseURL
            var created: [URL] = []
            for segment in renderer.renderPathSegments(pattern, snapshot: snapshot, now: now) {
                folder.appendPathComponent(segment, isDirectory: true)
                if !FileManager.default.fileExists(atPath: folder.path) {
                    // Another file may create the same subfolder at the same
                    // time; creating with intermediates does not fail if it exists.
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    created.append(folder)
                }
            }
            var outcome = try place(url, in: folder, named: snapshot.fullName, policy: .keepBoth, copy: false)
            outcome.producedURLs = created + outcome.producedURLs
            return outcome

        case .addTags(let tags):
            var merged = snapshot.tags
            for tag in tags.map(trimmed) where !tag.isEmpty
                && !merged.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                merged.append(tag)
            }
            try setTags(merged, on: url)
            return .success(url, produced: [url])

        case .removeTags(let tags):
            let removing = Set(tags.map { trimmed($0).lowercased() })
            try setTags(snapshot.tags.filter { !removing.contains($0.lowercased()) }, on: url)
            return .success(url, produced: [url])

        case .unarchive(let destination, let trashArchive):
            return try await unarchive(snapshot, into: destination, trashArchive: trashArchive)

        case .open(let app):
            try await environment.workspace.open(url, withApplicationAt: app)
            return .success(url)

        case .revealInFinder:
            await environment.workspace.revealInFinder(url)
            return .success(url)

        case .notify(let message):
            let body = renderer.renderText(message, snapshot: snapshot, now: now)
            await environment.notifier.showActionNotification(title: rule.name, body: body, ruleID: rule.id)
            return .success(url)

        case .emptyTrash:
            // The engine runs Empty Trash rules itself (`RuleEngine.emptyTrash`).
            throw ActionError.emptyTrashPerFile

        case .unknown:
            return ActionOutcome(result: .failed, currentURL: url, message: localized("Unknown action"))
        }
    }

    // MARK: - Moving and naming

    private func existingFolder(_ folder: FolderRef) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ActionError.destinationMissing(folder.tildeAbbreviated())
        }
        return folder.url
    }

    /// Moves or copies `url` to `folder/name`, applying the conflict policy.
    private func place(_ url: URL, in folder: URL, named name: String, policy: ConflictPolicy, copy: Bool) throws -> ActionOutcome {
        let isDirectory = url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let target = folder.appendingPathComponent(name, isDirectory: isDirectory)
        if !copy, ActionExecutor.samePath(url, target) {
            return .success(url, message: localized("Already in place"))
        }
        // Files run in parallel, so another file may take a free name between
        // resolving and moving. Resolve again a few times before giving up.
        var attempt = 1
        while true {
            do {
                switch resolver.resolve(destination: target, policy: policy, source: copy ? nil : url) {
                case .skip:
                    return .skipped(url, localized("Skipped: name exists"))
                case .replaceAfterTrashing(let existing):
                    _ = try environment.trash(existing)
                    return try transfer(url, to: existing, copy: copy)
                case .proceed(let destination):
                    return try transfer(url, to: destination, copy: copy)
                }
            } catch CocoaError.fileWriteFileExists where attempt < 3 {
                attempt += 1
            }
        }
    }

    private func transfer(_ url: URL, to destination: URL, copy: Bool) throws -> ActionOutcome {
        if copy {
            try FileCoordination.copy(from: url, to: destination)
            return .success(url, destination: destination, produced: [destination])
        }
        try FileCoordination.move(from: url, to: destination)
        return .success(destination, destination: destination, produced: [destination])
    }

    private func rename(_ snapshot: FileSnapshot, pattern: String, policy: ConflictPolicy, now: Date) throws -> ActionOutcome {
        let url = snapshot.url
        let folder = url.deletingLastPathComponent()
        guard PatternRenderer.containsCounter(pattern) else {
            let name = renderer.render(pattern, snapshot: snapshot, now: now)
            guard !name.isEmpty else { throw ActionError.emptyName }
            return try place(url, in: folder, named: name, policy: policy, copy: false)
        }
        // `{counter}` takes priority over the conflict policy: count up until free.
        var counter = 1
        while true {
            let name = renderer.render(pattern, snapshot: snapshot, now: now, counter: counter)
            guard !name.isEmpty else { throw ActionError.emptyName }
            let target = folder.appendingPathComponent(name)
            if ActionExecutor.samePath(url, target) {
                return .success(url, message: localized("Already in place"))
            }
            if !resolver.itemExists(target) {
                return try transfer(url, to: target, copy: false)
            }
            counter += 1
        }
    }

    private func setTags(_ tags: [String], on url: URL) throws {
        try FileCoordination.write(url) { url in
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    // MARK: - Unarchive

    private func unarchive(_ snapshot: FileSnapshot, into destination: FolderRef?, trashArchive: Bool) async throws -> ActionOutcome {
        let archive = snapshot.url
        guard snapshot.fileExtension.lowercased() == "zip", !snapshot.isDirectory else {
            throw ActionError.unsupportedArchive
        }
        let folder = try destination.map(existingFolder) ?? archive.deletingLastPathComponent()
        let extracted = try await Unarchiver.extractZip(archive, into: folder, resolver: resolver)
        var current: URL? = archive
        var trashedTo: URL?
        if trashArchive {
            trashedTo = try environment.trash(archive)
            current = nil
        }
        return ActionOutcome(
            result: .success,
            currentURL: current,
            destinationPath: extracted.count == 1 ? extracted[0].path : folder.path,
            message: trashedTo == nil ? nil : localized("Archive moved to Trash"),
            producedURLs: extracted
        )
    }

    // MARK: - Error mapping

    static func outcome(for error: Error, at url: URL) -> ActionOutcome {
        let exists = (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
        if !exists {
            return .skipped(nil, localized("File no longer exists"))
        }
        if let actionError = error as? ActionError {
            return ActionOutcome(result: .failed, currentURL: url, message: actionError.errorDescription)
        }
        switch classify(error) {
        case .permission:
            return ActionOutcome(result: .failed, currentURL: url, message: localized("Permission denied"), permissionDenied: true)
        case .diskFull:
            return ActionOutcome(result: .failed, currentURL: url, message: localized("Disk full"))
        case .other:
            return ActionOutcome(result: .failed, currentURL: url, message: error.localizedDescription)
        }
    }

    enum ErrorClass { case permission, diskFull, other }

    static func classify(_ error: Error) -> ErrorClass {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permission
            case NSFileWriteOutOfSpaceError: return .diskFull
            default: break
            }
        }
        let posix = (nsError.domain == NSPOSIXErrorDomain ? nsError : nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
        if let posix, posix.domain == NSPOSIXErrorDomain {
            switch Int32(posix.code) {
            case EACCES, EPERM: return .permission
            case ENOSPC: return .diskFull
            default: break
            }
        }
        return .other
    }
}
