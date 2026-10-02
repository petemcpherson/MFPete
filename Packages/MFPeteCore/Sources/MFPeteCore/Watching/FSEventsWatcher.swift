import CoreServices
import Foundation

/// Watches folders with one FSEvents stream and delivers changes as an
/// `AsyncStream` (spec §5.1). The C callback is a thin bridge; all decisions
/// happen in the consumer (D13).
///
/// Thread safety: the stream is created, stopped, and called back on a
/// private serial queue. `latestEventID` is guarded by a lock.
public final class FSEventsWatcher: @unchecked Sendable {
    public static let sinceNow = UInt64(kFSEventStreamEventIdSinceNow)

    /// One batch per callback. Survives `stop()` / `start()`, so a single
    /// consumer can read it for the watcher's whole life.
    public let batches: AsyncStream<FileEventBatch>
    private let continuation: AsyncStream<FileEventBatch>.Continuation

    private let queue = DispatchQueue(label: "com.mftpete.MFPete.fsevents")
    private var stream: FSEventStreamRef?
    /// True while FSEvents replays history from a stored event ID. Only
    /// touched on `queue`.
    private var replaying = false
    private let lock = NSLock()
    private var _latestEventID: UInt64?
    private var _paths: [String] = []

    public init() {
        (batches, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        stop()
        continuation.finish()
    }

    /// The newest event ID delivered so far. Persist this to resume later.
    public var latestEventID: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return _latestEventID
    }

    public var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return _paths
    }

    public var isRunning: Bool {
        queue.sync { stream != nil }
    }

    /// The system's current event ID.
    public static var currentEventID: UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Starts (or restarts) the stream on `paths`. Pass a stored event ID as
    /// `since` to replay what happened while the app was not watching.
    /// Returns false if the stream could not start.
    @discardableResult
    public func start(paths: [String], since: UInt64 = FSEventsWatcher.sinceNow, latency: TimeInterval = 0.3) -> Bool {
        stop()
        guard !paths.isEmpty else { return true }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        return queue.sync {
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                FSEventsWatcher.callback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(since),
                latency,
                flags
            ) else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            replaying = since != FSEventsWatcher.sinceNow
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            lock.lock(); _paths = paths; lock.unlock()
            return true
        }
    }

    /// Delivers pending events, then stops the stream. Flushing happens
    /// outside the queue, because the callback runs on it.
    public func stop() {
        guard let current = queue.sync(execute: { stream }) else { return }
        FSEventStreamFlushSync(current)
        queue.sync {
            FSEventStreamStop(current)
            FSEventStreamInvalidate(current)
            FSEventStreamRelease(current)
            stream = nil
            lock.lock(); _paths = []; lock.unlock()
        }
    }

    /// Delivers pending events now instead of after the latency.
    public func flush() {
        guard let current = queue.sync(execute: { stream }) else { return }
        FSEventStreamFlushSync(current)
    }

    // MARK: - Callback

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        watcher.deliver(
            paths: paths,
            flags: Array(UnsafeBufferPointer(start: flags, count: count)),
            ids: Array(UnsafeBufferPointer(start: ids, count: count))
        )
    }

    private func deliver(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        let now = Date()
        let batch = FSEventsWatcher.makeBatch(paths: paths, flags: flags, ids: ids, replaying: &replaying) { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return (false, nil) }
            let birth = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)
                + TimeInterval(info.st_birthtimespec.tv_nsec) / 1e9)
            return (true, now.timeIntervalSince(birth))
        }
        if let last = batch.lastEventID {
            lock.lock()
            _latestEventID = max(_latestEventID ?? 0, last)
            lock.unlock()
        }
        continuation.yield(batch)
    }

    /// Turns raw callback data into a batch. Separate from the callback so
    /// flag handling can be tested without a stream. `inspect` returns
    /// whether the path exists and how many seconds ago it was created.
    /// `replaying` turns false at the history-done marker.
    static func makeBatch(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        ids: [FSEventStreamEventId],
        replaying: inout Bool,
        inspect: (String) -> (exists: Bool, age: TimeInterval?)
    ) -> FileEventBatch {
        func has(_ value: FSEventStreamEventFlags, _ flag: Int) -> Bool {
            value & FSEventStreamEventFlags(flag) != 0
        }
        var batch = FileEventBatch()
        for index in 0..<min(paths.count, flags.count, ids.count) {
            let path = paths[index]
            let value = flags[index]
            if ids[index] != 0 {
                batch.lastEventID = max(batch.lastEventID ?? 0, UInt64(ids[index]))
            }
            if has(value, kFSEventStreamEventFlagHistoryDone) {
                batch.historyDone = true
                replaying = false
                continue
            }
            if has(value, kFSEventStreamEventFlagEventIdsWrapped) {
                batch.rescanAll = true
                continue
            }
            if has(value, kFSEventStreamEventFlagMustScanSubDirs)
                || has(value, kFSEventStreamEventFlagUserDropped)
                || has(value, kFSEventStreamEventFlagKernelDropped) {
                batch.rescanFolders.append(URL(fileURLWithPath: path, isDirectory: true))
                continue
            }
            let (exists, age) = inspect(path)
            let createdLongAgo = !replaying && (age ?? 0) > FileEvent.stickyCreatedWindow
            guard let kind = FileEvent.kind(flags: value, exists: exists, createdLongAgo: createdLongAgo) else { continue }
            batch.events.append(FileEvent(url: URL(fileURLWithPath: path), kind: kind))
        }
        return batch
    }
}
