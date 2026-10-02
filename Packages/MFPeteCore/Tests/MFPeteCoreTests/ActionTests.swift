import Foundation
import Testing
@testable import MFPeteCore

private func rule(_ actions: [Action] = [], name: String = "Test rule") -> Rule {
    Rule(name: name, actions: actions)
}

struct ActionExecutorTests {
    @Test func moveWithConflictPolicies() async throws {
        let h = try EngineHarness(now: testNow)
        let file = try h.sandbox.file("in/a.txt", contents: "new")
        try h.sandbox.file("out/a.txt", contents: "old")
        let out = h.sandbox.ref("out")

        let skipped = await h.executor.execute(.move(to: out, onConflict: .skip), on: file, rule: rule())
        #expect(skipped.result == .skipped)
        #expect(skipped.message == "Skipped: name exists")
        #expect(h.sandbox.exists("in/a.txt"))

        let kept = await h.executor.execute(.move(to: out, onConflict: .keepBoth), on: file, rule: rule())
        #expect(kept.result == .success)
        #expect(kept.currentURL?.lastPathComponent == "a 2.txt")
        #expect(h.sandbox.contents(of: "out") == ["a 2.txt", "a.txt"])

        let other = try h.sandbox.file("in/a.txt", contents: "newest")
        let replaced = await h.executor.execute(.move(to: out, onConflict: .replace), on: other, rule: rule())
        #expect(replaced.result == .success)
        #expect(h.trash.trashed == ["a.txt"])
        let text = try String(contentsOf: h.sandbox.root.appendingPathComponent("out/a.txt"), encoding: .utf8)
        #expect(text == "newest")
    }

    @Test func moveToMissingFolderFails() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt")
        let outcome = await h.executor.execute(.move(to: h.sandbox.ref("nowhere"), onConflict: .keepBoth), on: file, rule: rule())
        #expect(outcome.result == .failed)
        #expect(outcome.message?.hasPrefix("Destination folder missing") == true)
        #expect(h.sandbox.exists("in/a.txt"))
    }

    @Test func moveIntoSameFolderIsNoOp() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt")
        let outcome = await h.executor.execute(.move(to: h.sandbox.ref("in"), onConflict: .keepBoth), on: file, rule: rule())
        #expect(outcome.result == .success)
        #expect(h.sandbox.contents(of: "in") == ["a.txt"])
    }

    @Test func copyKeepsOriginal() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt")
        try h.sandbox.folder("backup")
        let outcome = await h.executor.execute(.copy(to: h.sandbox.ref("backup"), onConflict: .keepBoth), on: file, rule: rule())
        #expect(outcome.result == .success)
        #expect(outcome.currentURL == file)
        #expect(h.sandbox.exists("in/a.txt"))
        #expect(h.sandbox.exists("backup/a.txt"))
        #expect(outcome.producedURLs.map(\.lastPathComponent) == ["a.txt"])
    }

    @Test func renameWithPatternAndCounter() async throws {
        let h = try EngineHarness(now: testNow)
        let file = try h.sandbox.file("in/scan.pdf")
        let renamed = await h.executor.execute(.rename(pattern: "{name}-{today}.{extension}", onConflict: .keepBoth), on: file, rule: rule())
        #expect(renamed.result == .success)
        #expect(h.sandbox.contents(of: "in") == ["scan-2026-10-01.pdf"])

        // {counter} counts up past existing names instead of " 2" suffixes.
        try h.sandbox.file("in/Doc 1.txt")
        try h.sandbox.file("in/Doc 2.txt")
        let next = try h.sandbox.file("in/x.txt")
        let counted = await h.executor.execute(.rename(pattern: "Doc {counter}.{extension}", onConflict: .skip), on: next, rule: rule())
        #expect(counted.result == .success)
        #expect(counted.currentURL?.lastPathComponent == "Doc 3.txt")
    }

    @Test func renameConflictKeepBoth() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/final.txt")
        let file = try h.sandbox.file("in/draft.txt")
        let outcome = await h.executor.execute(.rename(pattern: "final.{extension}", onConflict: .keepBoth), on: file, rule: rule())
        #expect(outcome.currentURL?.lastPathComponent == "final 2.txt")
    }

    @Test func changeExtension() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/notes.txt")
        let outcome = await h.executor.execute(.changeExtension(".md"), on: file, rule: rule())
        #expect(outcome.result == .success)
        #expect(h.sandbox.contents(of: "in") == ["notes.md"])
    }

    @Test func trash() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/Setup.dmg")
        let outcome = await h.executor.execute(.trash, on: file, rule: rule())
        #expect(outcome.result == .success)
        #expect(outcome.currentURL == nil)
        #expect(outcome.destinationPath?.contains(".FakeTrash") == true)
        #expect(!h.sandbox.exists("in/Setup.dmg"))
    }

    @Test func sortIntoNestedSubfolders() async throws {
        let h = try EngineHarness(now: testNow)
        try h.sandbox.folder("Archive")
        let file = try h.sandbox.file("in/a.pdf")
        let outcome = await h.executor.execute(.sortIntoSubfolder(base: h.sandbox.ref("Archive"), pattern: "{extension}/{year}"), on: file, rule: rule())
        #expect(outcome.result == .success)
        let year = String(utcCalendar.component(.year, from: try FileSnapshot(reading: outcome.currentURL!).dateAdded!))
        #expect(h.sandbox.exists("Archive/pdf/\(year)/a.pdf"))
        #expect(outcome.producedURLs.count == 3)

        // Base folder must exist.
        let other = try h.sandbox.file("in/b.pdf")
        let missing = await h.executor.execute(.sortIntoSubfolder(base: h.sandbox.ref("Nope"), pattern: "{extension}"), on: other, rule: rule())
        #expect(missing.result == .failed)
    }

    @Test func addAndRemoveTags() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt")
        _ = await h.executor.execute(.addTags(["Red", " Work "]), on: file, rule: rule())
        #expect(Set(h.sandbox.tags("in/a.txt")) == ["Red", "Work"])
        _ = await h.executor.execute(.addTags(["red", "Blue"]), on: file, rule: rule())
        #expect(Set(h.sandbox.tags("in/a.txt")) == ["Red", "Work", "Blue"])
        _ = await h.executor.execute(.removeTags(["WORK"]), on: file, rule: rule())
        #expect(Set(h.sandbox.tags("in/a.txt")) == ["Red", "Blue"])
    }

    @Test func unarchiveFinderStyleZip() async throws {
        let h = try EngineHarness()
        let source = try h.sandbox.folder("src/assets")
        try h.sandbox.file("src/assets/logo.txt", contents: "logo")
        try h.sandbox.file("src/assets/sub/icon.txt", contents: "icon")
        let zip = h.sandbox.root.appendingPathComponent("in/assets.zip")
        try h.sandbox.folder("in")
        try runProcess("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, zip.path])
        // An existing "assets" folder forces Keep both naming.
        try h.sandbox.folder("in/assets")

        let outcome = await h.executor.execute(.unarchive(destination: nil, trashArchive: true), on: zip, rule: rule())
        #expect(outcome.result == .success)
        #expect(outcome.currentURL == nil)
        #expect(h.sandbox.exists("in/assets 2/logo.txt"))
        #expect(h.sandbox.exists("in/assets 2/sub/icon.txt"))
        #expect(!h.sandbox.exists("in/__MACOSX"))
        #expect(!h.sandbox.exists("in/assets.zip"))
        #expect(h.trash.trashed == ["assets.zip"])
        #expect(outcome.producedURLs.map(\.lastPathComponent) == ["assets 2"])
    }

    @Test func unarchiveIntoChosenFolderKeepsArchive() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("src/readme.txt")
        try h.sandbox.folder("in")
        try h.sandbox.folder("out")
        let zip = h.sandbox.root.appendingPathComponent("in/r.zip")
        try runProcess("/usr/bin/ditto", ["-c", "-k", h.sandbox.root.appendingPathComponent("src/readme.txt").path, zip.path])

        let outcome = await h.executor.execute(.unarchive(destination: h.sandbox.ref("out"), trashArchive: false), on: zip, rule: rule())
        #expect(outcome.result == .success)
        #expect(outcome.currentURL == zip)
        #expect(h.sandbox.exists("out/readme.txt"))
        #expect(h.sandbox.exists("in/r.zip"))
    }

    @Test func unarchiveCorruptZipFailsAndLeavesArchive() async throws {
        let h = try EngineHarness()
        let zip = try h.sandbox.file("in/broken.zip", contents: "this is not a zip")
        let outcome = await h.executor.execute(.unarchive(destination: nil, trashArchive: true), on: zip, rule: rule())
        #expect(outcome.result == .failed)
        #expect(outcome.message?.hasPrefix("Could not unarchive") == true)
        #expect(h.sandbox.contents(of: "in") == ["broken.zip"])
        #expect(h.trash.trashed.isEmpty)
    }

    @Test func unarchiveRejectsNonZip() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.rar")
        let outcome = await h.executor.execute(.unarchive(destination: nil, trashArchive: false), on: file, rule: rule())
        #expect(outcome.result == .failed)
        #expect(outcome.message == "Only .zip archives can be unarchived")
    }

    @Test func workspaceAndNotificationActions() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt")
        let app = URL(fileURLWithPath: "/Applications/TextEdit.app")
        _ = await h.executor.execute(.open(withApp: app), on: file, rule: rule())
        _ = await h.executor.execute(.revealInFinder, on: file, rule: rule())
        let notified = await h.executor.execute(.notify(message: "Got {fullname}"), on: file, rule: rule(name: "Inbox"))
        #expect(notified.result == .success)
        #expect(h.workspace.opened.first?.0 == file)
        #expect(h.workspace.opened.first?.1 == app)
        #expect(h.workspace.revealed == [file])
        #expect(h.notifier.posted.first?.title == "Inbox")
        #expect(h.notifier.posted.first?.body == "Got a.txt")
    }

    @Test func vanishedFileIsSkipped() async throws {
        let h = try EngineHarness()
        let gone = h.sandbox.root.appendingPathComponent("in/gone.txt")
        let outcome = await h.executor.execute(.trash, on: gone, rule: rule())
        #expect(outcome.result == .skipped)
        #expect(outcome.message == "File no longer exists")
    }

    @Test func errorClassification() {
        #expect(ActionExecutor.classify(CocoaError(.fileWriteNoPermission)) == .permission)
        #expect(ActionExecutor.classify(POSIXError(.EACCES)) == .permission)
        #expect(ActionExecutor.classify(CocoaError(.fileWriteOutOfSpace)) == .diskFull)
        #expect(ActionExecutor.classify(POSIXError(.ENOSPC)) == .diskFull)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM) as NSError])
        #expect(ActionExecutor.classify(wrapped) == .permission)
        #expect(ActionExecutor.classify(CocoaError(.fileReadCorruptFile)) == .other)
    }

    @Test func permissionDeniedIsFlagged() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt")
        let locked = try h.sandbox.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let outcome = await h.executor.execute(.move(to: h.sandbox.ref("locked"), onConflict: .keepBoth), on: file, rule: rule())
        #expect(outcome.result == .failed)
        #expect(outcome.permissionDenied)
        #expect(outcome.message == "Permission denied")
    }
}

func runProcess(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
