import Foundation

/// Decides what to do when an action's destination name already exists
/// (spec §6.3).
public struct ConflictResolver: Sendable {
    public enum Resolution: Equatable, Sendable {
        /// Destination is free (possibly with a " 2" suffix). Go ahead.
        case proceed(URL)
        /// Trash the existing item at this URL first, then place the file there.
        case replaceAfterTrashing(URL)
        /// Leave the file alone and log "Skipped: name exists".
        case skip
    }

    /// Reports whether an item exists at a URL. The dry run passes a closure
    /// that also sees planned (not yet real) files.
    public var itemExists: @Sendable (URL) -> Bool

    public init(itemExists: @escaping @Sendable (URL) -> Bool = ConflictResolver.diskItemExists) {
        self.itemExists = itemExists
    }

    public static let diskItemExists: @Sendable (URL) -> Bool = { url in
        // Unlike `fileExists`, this does not follow symlinks, so a broken
        // link still counts as occupying the name.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// - Parameter source: the file being placed. If the destination is the
    ///   same item (for example a case-only rename), there is no conflict.
    public func resolve(destination: URL, policy: ConflictPolicy, source: URL? = nil) -> Resolution {
        guard itemExists(destination), !isSameItem(source, destination) else {
            return .proceed(destination)
        }
        switch policy {
        case .keepBoth: return .proceed(firstFreeName(for: destination))
        case .replace: return .replaceAfterTrashing(destination)
        case .skip: return .skip
        }
    }

    /// Finder-style "name 2.ext", "name 3.ext"… Only the last extension is
    /// kept apart ("archive.tar 2.gz"), matching Finder. Folders get the
    /// suffix at the end of the name.
    public func firstFreeName(for destination: URL) -> URL {
        var number = 2
        while true {
            let candidate = ConflictResolver.numbered(destination, number)
            if !itemExists(candidate) { return candidate }
            number += 1
        }
    }

    static func numbered(_ url: URL, _ number: Int) -> URL {
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let isDirectory = url.hasDirectoryPath
        if ext.isEmpty || isDirectory {
            return folder.appendingPathComponent("\(url.lastPathComponent) \(number)", isDirectory: isDirectory)
        }
        let base = url.deletingPathExtension().lastPathComponent
        return folder.appendingPathComponent("\(base) \(number).\(ext)")
    }

    private func isSameItem(_ source: URL?, _ destination: URL) -> Bool {
        guard let source else { return false }
        if source.standardizedFileURL.path == destination.standardizedFileURL.path { return true }
        // Case-insensitive volumes: "a.txt" and "A.txt" are the same file.
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard
            let a = try? source.resourceValues(forKeys: key).fileResourceIdentifier,
            let b = try? destination.resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return a.isEqual(b)
    }
}
