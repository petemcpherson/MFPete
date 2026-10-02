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

    init(now: Date? = nil, clock: TestClock? = nil, configuration: RuleEngine.Configuration = RuleEngine.Configuration()) throws {
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
            now: { clock?.now ?? now ?? Date() }
        )
        engine = RuleEngine(activityStore: activity, processedStore: processed, environment: environment, configuration: configuration)
    }

    var executor: ActionExecutor { ActionExecutor(environment: environment) }

    func log() async throws -> [ActivityRecord] {
        try await activity.recent(limit: 1000)
    }
}

/// Collects engine events in the background.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [EngineEvent] = []
    private var task: Task<Void, Never>?

    init(_ engine: RuleEngine) {
        let stream = engine.events
        task = Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
        }
    }

    deinit { task?.cancel() }

    private func append(_ event: EngineEvent) {
        lock.lock(); _events.append(event); lock.unlock()
    }

    var events: [EngineEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    var summaries: [RunSummary] {
        events.compactMap { if case .runFinished(let summary) = $0 { return summary } else { return nil } }
    }

    var bulkRequests: [BulkApprovalRequest] {
        events.compactMap { if case .bulkApprovalRequested(let request) = $0 { return request } else { return nil } }
    }

    var applyRequests: [ApplyExistingRequest] {
        events.compactMap { if case .applyExistingRequested(let request) = $0 { return request } else { return nil } }
    }

    var loops: [LoopAlert] {
        events.compactMap { if case .loopDetected(let alert) = $0 { return alert } else { return nil } }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: TimeInterval = 5, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return try await condition()
}

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ now: Date) { _now = now }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    func set(_ date: Date) {
        lock.lock(); _now = date; lock.unlock()
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock()
    }
}
