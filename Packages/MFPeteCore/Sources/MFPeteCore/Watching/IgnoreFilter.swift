import Foundation

/// Items the engine never treats as candidates (spec §5.3, §5.4).
public struct IgnoreFilter: Hashable, Sendable {
    /// Per-rule "Include hidden files".
    public var includeHidden: Bool

    public init(includeHidden: Bool = false) {
        self.includeHidden = includeHidden
    }

    /// Always ignored, even with "Include hidden files".
    public static let systemNames: Set<String> = [".DS_Store", "Icon\r", ".localized"]
    /// In-progress download extensions (lowercased, no dot).
    public static let inProgressExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]
    public static let inProgressPrefixes = [".com.google.Chrome."]

    public func isIgnored(_ url: URL) -> Bool {
        isIgnored(name: url.lastPathComponent)
    }

    public func isIgnored(name: String) -> Bool {
        if IgnoreFilter.systemNames.contains(name) { return true }
        if IgnoreFilter.isInProgress(name: name) { return true }
        if !includeHidden, name.hasPrefix(".") { return true }
        return false
    }

    /// A file a browser or sync client is still writing. When the final name
    /// appears, it arrives as a new item.
    public static func isInProgress(name: String) -> Bool {
        if inProgressPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return inProgressExtensions.contains(ext)
    }
}
