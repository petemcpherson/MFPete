import Foundation

/// File locations under `~/Library/Application Support/MFPete` (D4).
public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MFPete", isDirectory: true)
    }

    public static var rulesFile: URL {
        supportDirectory.appendingPathComponent(RulesStore.fileName)
    }

    public static var dataStoreFile: URL {
        supportDirectory.appendingPathComponent("MFPete.store")
    }
}
