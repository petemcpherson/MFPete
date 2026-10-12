import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MFPeteCore

private let evaluator = ConditionEvaluator(calendar: utcCalendar)
private let day: TimeInterval = 24 * 60 * 60

private func snap(
    _ name: String,
    size: Int? = 2_000_000,
    added: Date? = testNow.addingTimeInterval(-2 * day),
    created: Date? = testNow.addingTimeInterval(-10 * day),
    modified: Date? = testNow.addingTimeInterval(-40 * day),
    tags: [String] = [],
    sources: [String] = [],
    isDirectory: Bool = false,
    isPackage: Bool = false,
    isAlias: Bool = false
) -> FileSnapshot {
    FileSnapshot(
        url: URL(fileURLWithPath: "/tmp/in/\(name)"),
        isDirectory: isDirectory,
        isPackage: isPackage,
        isAlias: isAlias,
        fileSize: size,
        dateAdded: added,
        dateCreated: created,
        dateModified: modified,
        tags: tags,
        downloadedFrom: sources
    )
}

private func check(_ attribute: Attribute, _ op: Operator, _ value: ConditionValue, _ snapshot: FileSnapshot) -> Bool {
    evaluator.matches(Condition(attribute: attribute, op: op, value: value), snapshot: snapshot, now: testNow)
}

struct KindClassifierTests {
    @Test(arguments: [
        ("photo.jpg", FileKind.image),
        ("clip.mov", .movie),
        ("song.mp3", .audio),
        ("paper.pdf", .pdf),
        ("notes.txt", .text),
        ("readme.md", .text),
        ("page.html", .text),
        ("report.docx", .document),
        ("sheet.xlsx", .document),
        ("bundle.zip", .archive),
        ("source.tar.gz", .archive),
        ("photos.rar", .archive),
        ("backup.RAR", .archive),
        ("logs.tar.xz", .archive),
        ("installer.dmg", .diskImage),
        ("blob.qqqzzz", .other),
    ])
    func classifiesByType(name: String, kind: FileKind) {
        #expect(snap(name).kind == kind)
    }

    /// The editor shows these extensions next to each kind, so they must be true.
    @Test(arguments: FileKind.allCases)
    func sampleExtensionsMatchKind(kind: FileKind) {
        for ext in kind.sampleExtensions where kind != .application {
            #expect(snap("sample.\(ext)").kind == kind, "\(ext)")
        }
    }

    @Test func precedence() {
        // .app bundles are directories and packages; Application wins over Folder.
        #expect(snap("Safari.app", isDirectory: true, isPackage: true).kind == .application)
        // Alias wins over the type of the name.
        #expect(snap("photo.jpg", isAlias: true).kind == .alias)
        #expect(snap("Projects", isDirectory: true).kind == .folder)
        // A folder whose name looks like a file is still a folder.
        #expect(snap("backup.zip", isDirectory: true).kind == .folder)
    }
}

struct WildcardTests {
    @Test func wildcards() {
        #expect(WildcardPattern.matches("Screenshot 2026-01-01", pattern: "Screenshot*"))
        #expect(WildcardPattern.matches("IMG_0001", pattern: "img_????"))
        #expect(!WildcardPattern.matches("IMG_001", pattern: "IMG_????"))
        #expect(WildcardPattern.matches("a.b.c", pattern: "*.*.*"))
        #expect(WildcardPattern.matches("anything", pattern: "*"))
        #expect(WildcardPattern.matches("", pattern: "*"))
        #expect(!WildcardPattern.matches("abc", pattern: "a*d"))
        #expect(WildcardPattern.matches("[draft] x", pattern: "[draft]*"))
        #expect(!WildcardPattern.matches("ABC", pattern: "abc", caseSensitive: true))
    }
}

struct ConditionEvaluatorTests {
    let file = snap("Invoice March.pdf", tags: ["Red", "Work"], sources: ["https://github.com/x/y.pdf", "https://github.com/"])

    @Test func nameOperators() {
        #expect(check(.name, .is, .text("invoice march"), file))
        #expect(!check(.name, .is, .text("Invoice March.pdf"), file))
        #expect(check(.name, .isNot, .text("other"), file))
        #expect(check(.name, .contains, .text("MARCH"), file))
        #expect(check(.name, .doesNotContain, .text("april"), file))
        #expect(check(.name, .startsWith, .text("inv"), file))
        #expect(!check(.name, .startsWith, .text("march"), file))
        #expect(check(.name, .endsWith, .text("march"), file))
        #expect(check(.name, .matchesPattern, .text("invoice*"), file))
        #expect(!check(.name, .matchesPattern, .text("*.pdf"), file))
    }

    @Test func fullNameOperators() {
        #expect(check(.fullName, .is, .text("invoice march.PDF"), file))
        #expect(check(.fullName, .isNot, .text("invoice march"), file))
        #expect(check(.fullName, .contains, .text("h.p"), file))
        #expect(check(.fullName, .doesNotContain, .text("zip"), file))
        #expect(check(.fullName, .startsWith, .text("Invoice "), file))
        #expect(check(.fullName, .endsWith, .text(".pdf"), file))
        #expect(check(.fullName, .matchesPattern, .text("*.pdf"), file))
    }

    @Test func caseSensitiveFlag() {
        let condition = Condition(attribute: .name, op: .contains, value: .text("MARCH"), caseSensitive: true)
        #expect(!evaluator.matches(condition, snapshot: file, now: testNow))
    }

    @Test func extensionOperators() {
        #expect(check(.extension, .is, .text(".PDF "), file))
        #expect(check(.extension, .isNot, .text("zip"), file))
        #expect(check(.extension, .isAnyOf, .text("dmg, .Pdf ,zip"), file))
        #expect(!check(.extension, .isAnyOf, .text("dmg,zip"), file))
        #expect(check(.extension, .is, .text(""), snap("Makefile")))
    }

    @Test func kindOperators() {
        #expect(check(.kind, .is, .kind(.pdf), file))
        #expect(!check(.kind, .is, .kind(.document), file))
        #expect(check(.kind, .isNot, .kind(.alias), file))
    }

    @Test func sizeOperatorsUseDecimalUnits() {
        // 2,000,000 bytes = 2 MB decimal.
        #expect(check(.size, .greaterThan, .size(1.5, .mb), file))
        #expect(!check(.size, .greaterThan, .size(2, .mb), file))
        #expect(check(.size, .lessThan, .size(2001, .kb), file))
        #expect(check(.size, .lessThan, .size(1, .gb), file))
        // Folders have no size in v1.
        let folder = snap("Folder", size: nil, isDirectory: true)
        #expect(!check(.size, .greaterThan, .size(0, .kb), folder))
        #expect(!check(.size, .lessThan, .size(1, .gb), folder))
    }

    @Test func dateOperatorsForEachDateAttribute() {
        // added 2 days ago, created 10 days ago, modified 40 days ago.
        #expect(check(.dateAdded, .inTheLast, .duration(3, .days), file))
        #expect(!check(.dateAdded, .notInTheLast, .duration(3, .days), file))
        #expect(check(.dateAdded, .inTheLast, .duration(49, .hours), file))
        #expect(!check(.dateAdded, .inTheLast, .duration(47, .hours), file))
        #expect(check(.dateAdded, .notInTheLast, .duration(2880 - 1, .minutes), file))
        #expect(check(.dateCreated, .notInTheLast, .duration(1, .weeks), file))
        #expect(check(.dateCreated, .inTheLast, .duration(2, .weeks), file))
        #expect(check(.dateModified, .notInTheLast, .duration(1, .months), file))
        #expect(check(.dateModified, .inTheLast, .duration(2, .months), file))

        // Modified 2026-08-22 12:00 UTC.
        let aug22 = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 23))!
        #expect(!check(.dateModified, .before, .date(aug22), file))
        #expect(!check(.dateModified, .after, .date(aug22), file))
        let aug23 = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 23))!
        #expect(check(.dateModified, .before, .date(aug23), file))
        let aug21 = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 21))!
        #expect(check(.dateModified, .after, .date(aug21), file))

        // Missing dates never match.
        let undated = snap("x.txt", added: nil)
        #expect(!check(.dateAdded, .inTheLast, .duration(1, .days), undated))
        #expect(!check(.dateAdded, .notInTheLast, .duration(1, .days), undated))
    }

    @Test func tagOperators() {
        #expect(check(.tags, .containsTag, .tags(["red"]), file))
        #expect(check(.tags, .containsTag, .tags(["Blue", "Work"]), file))
        #expect(!check(.tags, .containsTag, .tags(["Blue"]), file))
        #expect(check(.tags, .doesNotContainTag, .tags(["Blue"]), file))
        #expect(!check(.tags, .doesNotContainTag, .tags(["Blue", "work"]), file))
        #expect(!check(.tags, .hasNoTags, .none, file))
        #expect(check(.tags, .hasNoTags, .none, snap("plain.txt")))
    }

    @Test func downloadedFromOperators() {
        #expect(check(.downloadedFrom, .contains, .text("GitHub.com"), file))
        #expect(check(.downloadedFrom, .doesNotContain, .text("gitlab"), file))
        #expect(check(.downloadedFrom, .is, .text("https://github.com/"), file))
        #expect(!check(.downloadedFrom, .is, .text("github.com"), file))
        let local = snap("local.txt")
        #expect(!check(.downloadedFrom, .contains, .text("github"), local))
        #expect(check(.downloadedFrom, .doesNotContain, .text("github"), local))
    }

    @Test func anyFileAndMalformed() {
        #expect(check(.anyFile, .always, .none, file))
        // Operator not allowed for the attribute.
        #expect(!check(.size, .contains, .text("1"), file))
        // Wrong value type.
        #expect(!check(.name, .is, .size(1, .kb), file))
    }

    @Test func groups() {
        let pdf = ConditionItem.condition(Condition(attribute: .extension, op: .is, value: .text("pdf")))
        let zip = ConditionItem.condition(Condition(attribute: .extension, op: .is, value: .text("zip")))
        let big = ConditionItem.condition(Condition(attribute: .size, op: .greaterThan, value: .size(1, .mb)))

        #expect(evaluator.matches(ConditionGroup(), snapshot: file, now: testNow))
        #expect(!evaluator.matches(ConditionGroup(match: .all, items: [pdf, zip]), snapshot: file, now: testNow))
        #expect(evaluator.matches(ConditionGroup(match: .any, items: [pdf, zip]), snapshot: file, now: testNow))

        // All { size > 1 MB, Any { zip, pdf } }
        let nested = ConditionGroup(match: .all, items: [big, .group(ConditionGroup(match: .any, items: [zip, pdf]))])
        #expect(evaluator.matches(nested, snapshot: file, now: testNow))
        #expect(!evaluator.matches(nested, snapshot: snap("x.zip", size: 10), now: testNow))

        // Deeper nesting works in the data model.
        let deep = ConditionGroup(items: [.group(ConditionGroup(items: [.group(ConditionGroup(match: .any, items: [zip]))]))])
        #expect(!evaluator.matches(deep, snapshot: file, now: testNow))

        // Unknown items never match.
        let unknown = ConditionGroup(match: .any, items: [.unknown(.object(["type": .string("future")]))])
        #expect(!evaluator.matches(unknown, snapshot: file, now: testNow))
    }
}

struct FileSnapshotDiskTests {
    @Test func readsAttributesFromDisk() throws {
        let sandbox = try Sandbox()
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try sandbox.file("in/Report Final.pdf", contents: String(repeating: "x", count: 1500), modified: modified)
        try (url as NSURL).setResourceValue(["Red", "Work"], forKey: .tagNamesKey)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["https://example.com/report.pdf", "https://example.com/"],
            format: .binary, options: 0
        )
        try url.withUnsafeFileSystemRepresentation { path in
            let status = plist.withUnsafeBytes { setxattr(path, FileSnapshot.whereFromsAttribute, $0.baseAddress, plist.count, 0, 0) }
            #expect(status == 0)
        }

        let snapshot = try FileSnapshot(reading: url)
        #expect(snapshot.name == "Report Final")
        #expect(snapshot.fileExtension == "pdf")
        #expect(snapshot.fullName == "Report Final.pdf")
        #expect(snapshot.kind == .pdf)
        #expect(snapshot.fileSize == 1500)
        #expect(snapshot.dateModified == modified)
        #expect(snapshot.dateCreated == modified)
        #expect(snapshot.dateAdded != nil)
        #expect(Set(snapshot.tags) == ["Red", "Work"])
        #expect(snapshot.downloadedFrom == ["https://example.com/report.pdf", "https://example.com/"])
        #expect(snapshot.folderName == "in")
        #expect(!snapshot.isDataless)

        // Key is volume + inode, so it survives a rename.
        #expect(snapshot.fileKey.contains(":"))
        #expect(!snapshot.fileKey.hasPrefix("path:"))
        let renamed = url.deletingLastPathComponent().appendingPathComponent("renamed.pdf")
        try FileManager.default.moveItem(at: url, to: renamed)
        #expect(try FileSnapshot(reading: renamed).fileKey == snapshot.fileKey)

        // Conditions against real attributes.
        let tagged = Condition(attribute: .tags, op: .containsTag, value: .tags(["work"]))
        #expect(evaluator.matches(tagged, snapshot: snapshot, now: testNow))
        let source = Condition(attribute: .downloadedFrom, op: .contains, value: .text("example.com"))
        #expect(evaluator.matches(source, snapshot: snapshot, now: testNow))
        let old = Condition(attribute: .dateModified, op: .notInTheLast, value: .duration(30, .days))
        #expect(evaluator.matches(old, snapshot: snapshot, now: testNow))
        let added = Condition(attribute: .dateAdded, op: .inTheLast, value: .duration(5, .minutes))
        #expect(evaluator.matches(added, snapshot: snapshot, now: Date()))
    }

    @Test func folderAndPackageFromDisk() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder("in/Projects")
        let app = try sandbox.folder("in/Tool.app")
        #expect(try FileSnapshot(reading: folder).kind == .folder)
        #expect(try FileSnapshot(reading: folder).fileSize == nil)
        #expect(try FileSnapshot(reading: app).kind == .application)
    }

    @Test func symlinkIsAlias() throws {
        let sandbox = try Sandbox()
        let target = try sandbox.file("in/target.txt")
        let link = sandbox.root.appendingPathComponent("in/link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try FileSnapshot(reading: link).kind == .alias)
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) {
            try FileSnapshot(reading: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        }
    }
}

struct IgnoreFilterTests {
    @Test func ignoresSystemHiddenAndInProgress() {
        let filter = IgnoreFilter()
        for name in [".DS_Store", "Icon\r", ".localized", ".hidden", "file.crdownload", "movie.download",
                     "a.part", "a.PARTIAL", "x.tmp", "y.opdownload", ".com.google.Chrome.abc123"] {
            #expect(filter.isIgnored(name: name), "\(name)")
        }
        #expect(!filter.isIgnored(name: "invoice.pdf"))

        let withHidden = IgnoreFilter(includeHidden: true)
        #expect(!withHidden.isIgnored(name: ".env"))
        #expect(withHidden.isIgnored(name: ".DS_Store"))
        #expect(withHidden.isIgnored(name: "x.crdownload"))
    }
}
