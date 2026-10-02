import Foundation

/// Renders name patterns such as `{name}-{date-added}.{extension}` (spec §6.2).
///
/// - Unknown tokens render literally, braces included.
/// - Rendered file names have `:` and `/` replaced with `-`.
/// - `{year}`, `{month}`, `{day}` come from date added, falling back to date
///   created, then to `now`.
/// - `{counter}` renders as the given counter, or `1` when none is given.
/// - If `{extension}` is empty and directly follows a `.`, the dot is dropped,
///   so `{name}.{extension}` renders as `README` for a file with no extension.
public struct PatternRenderer: Sendable {
    public static let tokens = [
        "name", "extension", "fullname", "date-added", "date-created", "date-modified",
        "year", "month", "day", "today", "time", "counter", "folder", "kind",
    ]

    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Renders a single file name (Rename).
    public func render(_ pattern: String, snapshot: FileSnapshot, now: Date, counter: Int? = nil) -> String {
        PatternRenderer.sanitize(renderText(pattern, snapshot: snapshot, now: now, counter: counter))
    }

    /// Renders free text without sanitizing (notification messages).
    public func renderText(_ pattern: String, snapshot: FileSnapshot, now: Date, counter: Int? = nil) -> String {
        var output = ""
        for piece in PatternRenderer.parse(pattern) {
            switch piece {
            case .literal(let text):
                output += text
            case .token(let token):
                guard let value = value(of: token, snapshot: snapshot, now: now, counter: counter) else {
                    output += "{\(token)}"
                    continue
                }
                if token == "extension", value.isEmpty, output.hasSuffix(".") {
                    output.removeLast()
                }
                output += value
            }
        }
        return output
    }

    /// Renders a subfolder path (Sort into subfolder). The pattern is split on
    /// `/` first, so `{year}/{month}` gives nested folders; then each segment
    /// is sanitized. Empty segments are dropped.
    public func renderPathSegments(_ pattern: String, snapshot: FileSnapshot, now: Date) -> [String] {
        pattern.split(separator: "/", omittingEmptySubsequences: true)
            .map { render(String($0), snapshot: snapshot, now: now) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Replaces characters that are not allowed in file names, and keeps a
    /// name from meaning "this folder" or "parent folder".
    public static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        if cleaned == "." || cleaned == ".." { return "-" }
        return cleaned
    }

    /// Tokens in the pattern that this version does not know (the editor flags them).
    public static func unknownTokens(in pattern: String) -> [String] {
        parse(pattern).compactMap { piece in
            if case .token(let token) = piece, !tokens.contains(token) { return token }
            return nil
        }
    }

    public static func containsCounter(_ pattern: String) -> Bool {
        parse(pattern).contains { $0 == .token("counter") }
    }

    // MARK: - Internals

    enum Piece: Equatable {
        case literal(String)
        case token(String)
    }

    static func parse(_ pattern: String) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            if pattern[index] == "{", let close = pattern[index...].firstIndex(of: "}") {
                let token = String(pattern[pattern.index(after: index)..<close])
                if !token.isEmpty, !token.contains("{") {
                    if !literal.isEmpty { pieces.append(.literal(literal)); literal = "" }
                    pieces.append(.token(token))
                    index = pattern.index(after: close)
                    continue
                }
            }
            literal.append(pattern[index])
            index = pattern.index(after: index)
        }
        if !literal.isEmpty { pieces.append(.literal(literal)) }
        return pieces
    }

    private func value(of token: String, snapshot: FileSnapshot, now: Date, counter: Int?) -> String? {
        let anchor = snapshot.dateAdded ?? snapshot.dateCreated ?? now
        switch token {
        case "name": return snapshot.name
        case "extension": return snapshot.fileExtension
        case "fullname": return snapshot.fullName
        case "date-added": return format(snapshot.dateAdded ?? now, "yyyy-MM-dd")
        case "date-created": return format(snapshot.dateCreated ?? now, "yyyy-MM-dd")
        case "date-modified": return format(snapshot.dateModified ?? now, "yyyy-MM-dd")
        case "year": return format(anchor, "yyyy")
        case "month": return format(anchor, "MM")
        case "day": return format(anchor, "dd")
        case "today": return format(now, "yyyy-MM-dd")
        case "time": return format(now, "HHmmss")
        case "counter": return String(counter ?? 1)
        case "folder": return snapshot.folderName
        case "kind": return snapshot.kind.displayName
        default: return nil
        }
    }

    private func format(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
