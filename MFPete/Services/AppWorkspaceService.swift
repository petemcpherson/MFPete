import AppKit
import MFPeteCore

/// Open and Reveal in Finder actions, backed by `NSWorkspace`.
nonisolated struct AppWorkspaceService: WorkspaceService {
    func open(_ url: URL, withApplicationAt app: URL?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        if let app {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        }
    }

    func revealInFinder(_ url: URL) async {
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
