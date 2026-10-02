import Foundation

/// Locations macOS guards with a privacy (TCC) prompt the first time the app
/// touches them (spec §10). The editor explains the prompt the first time the
/// user picks a folder in one of them.
public enum ProtectedLocation: String, Hashable, Sendable, CaseIterable {
    case desktop
    case documents
    case downloads
    case iCloudDrive
    case removableVolume
    case networkVolume

    public var displayName: String {
        switch self {
        case .desktop: return localized("Desktop")
        case .documents: return localized("Documents")
        case .downloads: return localized("Downloads")
        case .iCloudDrive: return localized("iCloud Drive")
        case .removableVolume: return localized("removable volumes")
        case .networkVolume: return localized("network volumes")
        }
    }

    /// The protected location a folder is in, or nil. Checks the home folder
    /// locations by path first, then the volume type for paths under
    /// `/Volumes`.
    public static func of(_ folder: FolderRef, home: String = FolderRef.homePath) -> ProtectedLocation? {
        if let location = homeLocation(of: folder.path, home: home) {
            return location
        }
        guard FolderHealth.volumeRoot(of: folder.path) != nil else { return nil }
        let values = try? folder.url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey])
        if values?.volumeIsLocal == false { return .networkVolume }
        if values?.volumeIsRemovable == true || values?.volumeIsEjectable == true { return .removableVolume }
        return nil
    }

    /// Path-only check for the folders inside the home folder.
    static func homeLocation(of path: String, home: String) -> ProtectedLocation? {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        let standardized = (path as NSString).standardizingPath
        let places: [(String, ProtectedLocation)] = [
            ("Desktop", .desktop),
            ("Documents", .documents),
            ("Downloads", .downloads),
            ("Library/Mobile Documents", .iCloudDrive),
        ]
        for (relative, location) in places {
            let root = home + "/" + relative
            if standardized == root || standardized.hasPrefix(root + "/") {
                return location
            }
        }
        return nil
    }
}
