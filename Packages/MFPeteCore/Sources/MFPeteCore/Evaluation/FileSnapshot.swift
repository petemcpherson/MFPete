import Foundation
import UniformTypeIdentifiers

/// The attributes of one file at one moment, read once and then used for
/// condition evaluation, name patterns, and the processed-file record.
public struct FileSnapshot: Hashable, Sendable {
    public var url: URL
    /// Name without extension ("invoice" for "invoice.pdf").
    public var name: String
    /// Extension without dot, as on disk ("pdf"). Empty if none.
    public var fileExtension: String
    /// Name with extension.
    public var fullName: String
    public var isDirectory: Bool
    public var isPackage: Bool
    /// Symbolic link or Finder alias.
    public var isAlias: Bool
    public var contentType: UTType?
    public var kind: FileKind
    /// Logical size in bytes. Nil for folders and packages (folder size is v2).
    public var fileSize: Int?
    public var totalFileAllocatedSize: Int?
    public var dateAdded: Date?
    public var dateCreated: Date?
    public var dateModified: Date?
    public var tags: [String]
    /// `kMDItemWhereFroms`: download URL and referrer, if any.
    public var downloadedFrom: [String]
    public var volumeUUID: String?
    public var fileIdentifier: UInt64?
    /// Online-only cloud placeholder whose contents are not on disk (spec §12).
    public var isDataless: Bool

    public init(
        url: URL,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        isAlias: Bool = false,
        contentType: UTType? = nil,
        kind: FileKind? = nil,
        fileSize: Int? = nil,
        totalFileAllocatedSize: Int? = nil,
        dateAdded: Date? = nil,
        dateCreated: Date? = nil,
        dateModified: Date? = nil,
        tags: [String] = [],
        downloadedFrom: [String] = [],
        volumeUUID: String? = nil,
        fileIdentifier: UInt64? = nil,
        isDataless: Bool = false
    ) {
        self.url = url
        self.fullName = url.lastPathComponent
        self.fileExtension = url.pathExtension
        self.name = url.pathExtension.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isAlias = isAlias
        let type = contentType ?? UTType(filenameExtension: url.pathExtension)
        self.contentType = type
        self.kind = kind ?? KindClassifier.classify(
            contentType: type,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isAlias: isAlias
        )
        self.fileSize = fileSize
        self.totalFileAllocatedSize = totalFileAllocatedSize
        self.dateAdded = dateAdded
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.tags = tags
        self.downloadedFrom = downloadedFrom
        self.volumeUUID = volumeUUID
        self.fileIdentifier = fileIdentifier
        self.isDataless = isDataless
    }

    /// Resource keys read for every snapshot. Pass these to directory
    /// enumerators so the values are prefetched.
    public static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
        .contentTypeKey, .fileSizeKey, .totalFileAllocatedSizeKey,
        .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey,
        .tagNamesKey, .fileIdentifierKey, .volumeUUIDStringKey,
    ]

    /// Reads a snapshot from disk. Throws if the file does not exist.
    public init(reading url: URL) throws {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: Set(FileSnapshot.resourceKeys))
        let isDirectory = values.isDirectory ?? false
        self.init(
            url: url,
            isDirectory: isDirectory,
            isPackage: values.isPackage ?? false,
            isAlias: (values.isSymbolicLink ?? false) || (values.isAliasFile ?? false),
            contentType: values.contentType,
            fileSize: isDirectory ? nil : values.fileSize,
            totalFileAllocatedSize: values.totalFileAllocatedSize,
            dateAdded: values.addedToDirectoryDate,
            dateCreated: values.creationDate,
            dateModified: values.contentModificationDate,
            tags: values.tagNames ?? [],
            downloadedFrom: FileSnapshot.readWhereFroms(url),
            volumeUUID: values.volumeUUIDString,
            fileIdentifier: values.fileIdentifier,
            isDataless: FileSnapshot.isDataless(url)
        )
    }

    /// Stable file identity for the processed-file record (spec §5.5):
    /// volume UUID + inode, with the path as fallback.
    public var fileKey: String {
        if let volumeUUID, let fileIdentifier {
            return "\(volumeUUID):\(fileIdentifier)"
        }
        return "path:\(url.standardizedFileURL.path)"
    }

    /// The same attributes at a new location, with the name fields updated.
    /// Used by the dry run, which cannot re-read moved files from disk.
    public func relocated(to newURL: URL) -> FileSnapshot {
        var copy = self
        copy.url = newURL
        copy.fullName = newURL.lastPathComponent
        copy.fileExtension = newURL.pathExtension
        copy.name = newURL.pathExtension.isEmpty
            ? newURL.lastPathComponent
            : newURL.deletingPathExtension().lastPathComponent
        return copy
    }

    /// Parent folder name, for the `{folder}` token.
    public var folderName: String {
        url.deletingLastPathComponent().lastPathComponent
    }

    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"

    /// Reads the `kMDItemWhereFroms` extended attribute (a binary plist of
    /// strings). Returns an empty list if it is missing or unreadable.
    static func readWhereFroms(_ url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = getxattr(path, whereFromsAttribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { buffer in
                getxattr(path, whereFromsAttribute, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
            guard read > 0 else { return [] }
            let plist = try? PropertyListSerialization.propertyList(from: data.prefix(read), format: nil)
            return (plist as? [String]) ?? []
        }
    }

    /// `SF_DATALESS` from `<sys/stat.h>`.
    private static let datalessFlag: UInt32 = 0x4000_0000

    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & datalessFlag != 0
    }
}
