import Foundation

/// A folder referenced by a rule. Stored as an absolute path (D2: no sandbox,
/// no bookmarks). Encodes as a plain JSON string.
public struct FolderRef: Codable, Hashable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }

    /// Creates a reference from a path that may start with `~`.
    public init(expanding path: String, home: String = FolderRef.homePath) {
        self.path = FolderRef.expandTilde(in: path, home: home)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Expanding on decode lets exported (tilde-abbreviated) rules import as-is.
        self.init(expanding: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }

    public static var homePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Folder name for summaries and auto-generated rule names ("Downloads").
    public var displayName: String {
        url.lastPathComponent
    }

    /// Path with the home folder shown as `~`, for display and export.
    public func tildeAbbreviated(home: String = FolderRef.homePath) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func expandTilde(in path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}
