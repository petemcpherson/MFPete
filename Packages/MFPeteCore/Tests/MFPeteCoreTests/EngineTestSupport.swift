import Foundation
@testable import MFPeteCore

/// A temp folder that tests create files in.
struct Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFPeteEngineTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ path: String, contents: String = "hello", modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified, .creationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func ref(_ path: String) -> FolderRef {
        FolderRef(path: root.appendingPathComponent(path).path)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func contents(of path: String) -> [String] {
        let url = root.appendingPathComponent(path)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func tags(_ path: String) -> [String] {
        var url = root.appendingPathComponent(path)
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }
}

/// Stands in for the system Trash so tests do not fill the user's Trash.
final class FakeTrash: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var _trashed: [String] = []

    init(in sandbox: Sandbox) throws {
        folder = try sandbox.folder(".FakeTrash")
    }

    var trashed: [String] {
        lock.lock(); defer { lock.unlock() }
        return _trashed
    }

    func trash(_ url: URL) throws -> URL? {
        let destination = ConflictResolver().firstFreeName(for: folder.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.moveItem(at: url, to: destination)
        lock.lock(); _trashed.append(url.lastPathComponent); lock.unlock()
        return destination
    }
}

final class RecordingWorkspace: WorkspaceService, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var opened: [(URL, URL?)] = []
    private(set) var revealed: [URL] = []

    func open(_ url: URL, withApplicationAt app: URL?) async throws {
        lock.lock(); opened.append((url, app)); lock.unlock()
    }

    func revealInFinder(_ url: URL) async {
        lock.lock(); revealed.append(url); lock.unlock()
    }
}

final class RecordingNotifier: NotificationService, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var posted: [(title: String, body: String)] = []

    func showActionNotification(title: String, body: String, ruleID: UUID) async {
        lock.lock(); posted.append((title, body)); lock.unlock()
    }
}

/// UTC Gregorian calendar so date tokens are stable.
let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}()

/// 2026-10-01 12:00:00 UTC.
let testNow = Date(timeIntervalSince1970: 1_790_856_000)

struct EngineHarness {
    let sandbox: Sandbox
    let trash: FakeTrash
    let workspace = RecordingWorkspace()
    let notifier = RecordingNotifier()
    let activity: ActivityStore
    let processed: ProcessedStore
    let engine: RuleEngine
    let environment: ActionEnvironment

    init(now: Date? = nil) throws {
        sandbox = try Sandbox()
        trash = try FakeTrash(in: sandbox)
        let container = try DataStore.makeInMemoryContainer()
        activity = ActivityStore(modelContainer: container)
        processed = ProcessedStore(modelContainer: container)
        let trash = trash
        environment = ActionEnvironment(
            workspace: workspace,
            notifier: notifier,
            trash: { try trash.trash($0) },
            calendar: utcCalendar,
            now: { now ?? Date() }
        )
        engine = RuleEngine(activityStore: activity, processedStore: processed, environment: environment)
    }

    var executor: ActionExecutor { ActionExecutor(environment: environment) }

    func log() async throws -> [ActivityRecord] {
        try await activity.recent(limit: 1000)
    }
}
