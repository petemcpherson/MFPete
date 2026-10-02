import AppKit
import MFPeteCore
import UniformTypeIdentifiers

/// Saves rules as a `.json` file in the `rules.json` format, with folder
/// paths shown as `~` (spec §9).
enum RuleExporter {
    static func export(_ rules: [Rule], suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let safeName = suggestedName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeName).json"
        AppActivation.bringToFront()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try RulesFile(rules: rules.map { $0.tildeAbbreviated() }).encoded()
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
