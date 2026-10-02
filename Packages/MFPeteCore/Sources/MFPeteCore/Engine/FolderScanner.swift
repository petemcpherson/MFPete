import Foundation

/// Health of one scope folder (spec §10).
public enum FolderHealth: Hashable, Sendable {
    case ok
    case missing
    case noPermission

    /// Checks that the folder exists, is a directory, and can be listed.
    /// Listing is the real test: TCC denies `opendir`, not `stat`.
    public static func check(_ folder: FolderRef) -> FolderHealth {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing
        }
        guard let directory = opendir(folder.path) else {
            return errno == EACCES || errno == EPERM ? .noPermission : .missing
        }
        closedir(directory)
        return .ok
    }
}

/// Lists candidate files for full scans (scheduled runs, Run Now).
public enum FolderScanner {
    /// Direct children by default; recursive with "Include subfolders".
    /// Never descends into packages (spec §5.2). Applies the ignore filter.
    /// Sorted by path so runs are deterministic.
    public static func candidates(in folder: FolderRef, options: RuleOptions) -> [URL] {
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includeSubfolders { enumeratorOptions.insert(.skipsSubdirectoryDescendants) }
        if !options.includeHidden { enumeratorOptions.insert(.skipsHiddenFiles) }

        guard let enumerator = FileManager.default.enumerator(
            at: folder.url,
            includingPropertiesForKeys: FileSnapshot.resourceKeys,
            options: enumeratorOptions
        ) else { return [] }

        let filter = IgnoreFilter(includeHidden: options.includeHidden)
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if filter.isIgnored(url) {
                // Do not descend into an ignored folder either.
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// True if `url` is a candidate location for the rule: a direct child of
    /// a scope folder, or any descendant with "Include subfolders".
    public static func rule(_ rule: Rule, covers url: URL) -> Bool {
        let parent = canonicalPath(url.deletingLastPathComponent())
        return rule.scope.contains { folder in
            let root = canonicalPath(folder.url)
            if parent == root { return true }
            return rule.options.includeSubfolders && parent.hasPrefix(root + "/")
        }
    }

    /// Resolves symlinks such as `/var` → `/private/var` so paths compare.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
