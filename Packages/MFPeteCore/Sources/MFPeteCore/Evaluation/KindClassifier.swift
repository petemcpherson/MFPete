import Foundation
import UniformTypeIdentifiers

/// Maps a file's type to the Kind attribute (spec §4.2).
///
/// Precedence, first match wins:
/// 1. Alias/Symlink (the link itself, not its target)
/// 2. Application (`.app` bundles are folders on disk, so this comes before Folder)
/// 3. Folder (plain directories only; other packages fall through to their type)
/// 4. PDF (PDF conforms to more general content types, so it comes before Document)
/// 5. Disk Image (before Archive: some disk image types also conform to archive)
/// 6. Archive
/// 7. Image, Movie, Audio
/// 8. Text (plain text, rich text, source code, HTML, JSON…)
/// 9. Document (any other user content: Office, iWork, presentations, spreadsheets)
/// 10. Other
public enum KindClassifier {
    private static let extraArchiveTypes: [UTType] = [
        .zip, .gzip, .bz2,
        UTType("public.tar-archive"),
        UTType("org.7-zip.7-zip-archive"),
        UTType("com.rarlab.rar-archive"),
        UTType("org.tukaani.xz-archive"),
    ].compactMap { $0 }

    public static func classify(
        contentType: UTType?,
        isDirectory: Bool,
        isPackage: Bool,
        isAlias: Bool
    ) -> FileKind {
        if isAlias { return .alias }
        if let type = contentType, type.conforms(to: .application) || type.conforms(to: .applicationBundle) {
            return .application
        }
        if isDirectory && !isPackage { return .folder }
        guard let type = contentType else { return isDirectory ? .folder : .other }

        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .archive) || extraArchiveTypes.contains(where: { type.conforms(to: $0) }) {
            return .archive
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .movie }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) { return .text }
        if type.conforms(to: .content)
            || type.conforms(to: .compositeContent)
            || type.conforms(to: .spreadsheet)
            || type.conforms(to: .presentation) {
            return .document
        }
        return isDirectory && !isPackage ? .folder : .other
    }
}
