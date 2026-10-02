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

    /// Settings › Advanced › Export All Rules.
    static func exportAll(_ rules: [Rule]) {
        export(rules, suggestedName: String(localized: "MFPete Rules"))
    }

    /// Asks for a rules file and appends its rules, disabled (spec §9).
    @MainActor
    static func importRules(into appState: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        AppActivation.bringToFront()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        do {
            let data = try Data(contentsOf: url)
            let result = try RuleImporter().importRules(from: data, startOrder: appState.rules.count)
            appState.append(result.rules)
            alert.messageText = result.rules.count == 1
                ? String(localized: "Imported 1 rule")
                : String(localized: "Imported \(result.rules.count) rules")
            var info = String(localized: "Imported rules start disabled. Check their folders, then turn them on in the Rules window.")
            if !result.unknownRuleNames.isEmpty {
                let names = ListFormatter.localizedString(byJoining: result.unknownRuleNames)
                info += "\n\n" + String(localized: "These rules use features from a newer version of MFPete and cannot run: \(names).")
            }
            alert.informativeText = info
        } catch {
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Could not import rules")
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
