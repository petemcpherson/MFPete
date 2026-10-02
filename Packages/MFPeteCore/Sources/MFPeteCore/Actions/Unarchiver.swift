import Foundation

/// Extracts `.zip` archives with `/usr/bin/ditto`, which keeps macOS metadata
/// and handles Finder-made zips (spec §6.1).
enum Unarchiver {
    /// Extracts into a temporary folder on the destination's volume, then
    /// moves each top-level item into `folder` with Keep both naming.
    /// Returns the final URLs of the extracted items. On failure nothing is
    /// left in `folder` and the archive is untouched.
    static func extractZip(_ archive: URL, into folder: URL, resolver: ConflictResolver) async throws -> [URL] {
        let fileManager = FileManager.default
        let staging = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: folder,
            create: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        try await runDitto(["-x", "-k", archive.path, staging.path])

        let items = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !items.isEmpty else { throw ActionError.unarchiveFailed(localized("The archive is empty")) }

        var placed: [URL] = []
        for item in items {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let target = folder.appendingPathComponent(item.lastPathComponent, isDirectory: isDirectory)
            guard case .proceed(let destination) = resolver.resolve(destination: target, policy: .keepBoth) else {
                continue
            }
            try fileManager.moveItem(at: item, to: destination)
            placed.append(destination)
        }
        return placed
    }

    private static func runDitto(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ActionError.unarchiveFailed(message.isEmpty ? "ditto exited with status \(status)" : message)
        }
    }
}
