import Foundation

/// Opens and reveals files. The app target implements this with
/// `NSWorkspace`, which keeps this package free of AppKit.
public protocol WorkspaceService: Sendable {
    /// Opens the file with the given app, or the default app if `app` is nil.
    func open(_ url: URL, withApplicationAt app: URL?) async throws
    func revealInFinder(_ url: URL) async
}

/// Posts user notifications. The app target implements this with
/// `UNUserNotificationCenter`.
public protocol NotificationService: Sendable {
    /// The "Show notification" action. It is an explicit user choice, so it
    /// fires at every notification level, including Off (spec §8.8).
    func showActionNotification(title: String, body: String, ruleID: UUID) async
}

/// Does nothing. Default for headless use and tests.
public struct NoopWorkspaceService: WorkspaceService {
    public init() {}
    public func open(_ url: URL, withApplicationAt app: URL?) async throws {}
    public func revealInFinder(_ url: URL) async {}
}

/// Does nothing. Default for headless use and tests.
public struct NoopNotificationService: NotificationService {
    public init() {}
    public func showActionNotification(title: String, body: String, ruleID: UUID) async {}
}

/// Everything actions need from the outside world. Tests swap in a fake
/// trash, a fixed clock, and recording services.
public struct ActionEnvironment: Sendable {
    public var workspace: any WorkspaceService
    public var notifier: any NotificationService
    /// Moves an item to the Trash and returns where it ended up.
    public var trash: @Sendable (URL) throws -> URL?
    /// Empties the whole Trash and returns how many items it held. The app
    /// target asks Finder; the default throws.
    public var emptyTrash: @Sendable () async throws -> Int
    public var calendar: Calendar
    public var now: @Sendable () -> Date

    public init(
        workspace: any WorkspaceService = NoopWorkspaceService(),
        notifier: any NotificationService = NoopNotificationService(),
        trash: @escaping @Sendable (URL) throws -> URL? = ActionEnvironment.systemTrash,
        emptyTrash: @escaping @Sendable () async throws -> Int = ActionEnvironment.emptyTrashUnavailable,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.workspace = workspace
        self.notifier = notifier
        self.trash = trash
        self.emptyTrash = emptyTrash
        self.calendar = calendar
        self.now = now
    }

    /// Default for headless use: Empty Trash rules fail with a clear message.
    public static let emptyTrashUnavailable: @Sendable () async throws -> Int = {
        throw ActionError.emptyTrashUnavailable
    }

    /// `FileManager.trashItem`, so Finder's "Put Back" works.
    public static let systemTrash: @Sendable (URL) throws -> URL? = { url in
        var resulting: NSURL?
        try FileCoordination.delete(url) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        }
        return resulting as URL?
    }
}

/// Wraps file operations in `NSFileCoordinator` so apps that are writing the
/// same file get a chance to finish first (spec §5.7).
enum FileCoordination {
    static func move(from source: URL, to destination: URL) throws {
        try coordinate { coordinator, error, failure in
            coordinator.coordinate(
                writingItemAt: source, options: .forMoving,
                writingItemAt: destination, options: .forReplacing,
                error: error
            ) { from, to in
                do {
                    try FileManager.default.moveItem(at: from, to: to)
                    coordinator.item(at: from, didMoveTo: to)
                } catch { failure = error }
            }
        }
    }

    static func copy(from source: URL, to destination: URL) throws {
        try coordinate { coordinator, error, failure in
            coordinator.coordinate(
                readingItemAt: source, options: [],
                writingItemAt: destination, options: .forReplacing,
                error: error
            ) { from, to in
                do { try FileManager.default.copyItem(at: from, to: to) } catch { failure = error }
            }
        }
    }

    static func write(_ url: URL, _ body: (URL) throws -> Void) throws {
        try coordinate { coordinator, error, failure in
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: error) { url in
                do { try body(url) } catch { failure = error }
            }
        }
    }

    static func delete(_ url: URL, _ body: (URL) throws -> Void) throws {
        try coordinate { coordinator, error, failure in
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: error) { url in
                do { try body(url) } catch { failure = error }
            }
        }
    }

    private static func coordinate(
        _ body: (NSFileCoordinator, NSErrorPointer, inout Error?) -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var failure: Error?
        body(coordinator, &coordinationError, &failure)
        if let error = failure ?? coordinationError { throw error }
    }
}
