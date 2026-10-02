import AppKit
import MFPeteCore
import SwiftUI

/// One titled card in the rule editor (WHEN, IF, THEN).
struct EditorCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

/// A small note under a card section: info, warning, or error style.
struct EditorHint: View {
    enum Style {
        case info, warning, error
    }

    let text: String
    var style: Style = .info

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .font(.callout)
        .foregroundStyle(style == .info ? .secondary : .primary)
    }

    private var icon: String {
        switch style {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch style {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Small borderless icon button used for add / remove in editor rows.
struct RowIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// Folder field: tilde-abbreviated path, a Choose button, and drag-in from
/// Finder. Empty paths show "Choose a folder…".
struct FolderField: View {
    let folder: FolderRef?
    var placeholder: LocalizedStringKey = "Choose a folder…"
    let onChoose: (FolderRef) -> Void

    @Environment(FolderGate.self) private var gate

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let folder, !folder.path.isEmpty {
                Text(folder.tildeAbbreviated())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
            } else {
                Text(placeholder)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Choose…") {
                gate.chooseFolder(startingAt: folder, then: onChoose)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || FolderGate.isDirectory(url) else { return false }
            gate.accept(url, then: onChoose)
            return true
        }
        .accessibilityElement(children: .combine)
    }
}

/// Folder picking for the editor. Shows a one-time explainer before the
/// first folder in a privacy-protected location is used, so the macOS prompt
/// that follows makes sense (spec §10).
@MainActor
@Observable
final class FolderGate {
    struct Pending: Identifiable {
        let id = UUID()
        let folder: FolderRef
        let location: ProtectedLocation
        let completion: (FolderRef) -> Void
    }

    var pending: Pending?

    @ObservationIgnored private let defaults: UserDefaults
    static let explainedKey = "explainedProtectedLocations"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func chooseFolder(startingAt folder: FolderRef?, then completion: @escaping (FolderRef) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if let folder, !folder.path.isEmpty {
            panel.directoryURL = folder.url
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(url, then: completion)
    }

    /// Uses the folder now, or after the explainer if it is the first one in
    /// a protected location.
    func accept(_ url: URL, then completion: @escaping (FolderRef) -> Void) {
        let folder = FolderRef(path: url.standardizedFileURL.path)
        guard let location = ProtectedLocation.of(folder), !explained.contains(location.rawValue) else {
            completion(folder)
            return
        }
        pending = Pending(folder: folder, location: location, completion: completion)
    }

    func confirmPending() {
        guard let pending else { return }
        self.pending = nil
        defaults.set(Array(explained.union([pending.location.rawValue])), forKey: Self.explainedKey)
        pending.completion(pending.folder)
    }

    func cancelPending() {
        pending = nil
    }

    private var explained: Set<String> {
        Set(defaults.stringArray(forKey: Self.explainedKey) ?? [])
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// Comma-separated text bound to a list of strings ("work, urgent").
/// Keeps the user's typing as-is and only parses it into the list.
struct CommaListField: View {
    let placeholder: LocalizedStringKey
    @Binding var items: [String]
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .onAppear { text = items.joined(separator: ", ") }
            .onChange(of: text) { _, newValue in
                let parsed = splitCommaList(newValue)
                if parsed != items { items = parsed }
            }
            .onChange(of: items) { _, newValue in
                if splitCommaList(text) != newValue { text = newValue.joined(separator: ", ") }
            }
    }
}

/// Inserts `{token}` chips into a pattern, with a live preview against a
/// sample file from the rule's folders.
struct PatternField: View {
    let placeholder: LocalizedStringKey
    @Binding var pattern: String
    /// Renders the pattern for the preview line, or nil when there is no sample.
    var preview: ((String) -> String?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField(placeholder, text: $pattern)
                    .font(.body.monospaced())
                Menu {
                    ForEach(PatternRenderer.tokens, id: \.self) { token in
                        Button("{\(token)}") { pattern += "{\(token)}" }
                    }
                } label: {
                    Image(systemName: "curlybraces")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Insert a token")
                .accessibilityLabel(Text("Insert a token"))
            }
            let unknown = PatternRenderer.unknownTokens(in: pattern)
            if !unknown.isEmpty {
                EditorHint(
                    text: String(localized: "Unknown token: \(unknown.map { "{\($0)}" }.joined(separator: ", "))"),
                    style: .warning
                )
            } else if let rendered = preview?(pattern) {
                Text("Example: \(rendered)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// Integer text field that clamps to a minimum.
struct NumberField: View {
    @Binding var value: Int
    var minimum = 1

    var body: some View {
        TextField("", value: Binding(get: { value }, set: { value = max(minimum, $0) }), format: .number)
            .frame(width: 56)
            .multilineTextAlignment(.trailing)
            .labelsHidden()
    }
}
