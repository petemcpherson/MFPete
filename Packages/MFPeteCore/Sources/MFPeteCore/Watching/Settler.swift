import Foundation

/// Waits for files to finish writing before rules see them (spec §5.3).
/// A file is ready when its size and modification date stay the same for
/// the settle delay. Files that vanish first are dropped silently.
public actor Settler {
    public struct Item: Hashable, Sendable {
        public var url: URL
        public var kind: FileEvent.Kind
        /// A rule that may run on this file needs its contents (Copy,
        /// Unarchive). Online-only placeholders wait until downloaded (§12).
        public var needsContents: Bool

        public init(url: URL, kind: FileEvent.Kind, needsContents: Bool = false) {
            self.url = url
            self.kind = kind
            self.needsContents = needsContents
        }
    }

    /// What the settler compares between checks.
    struct Signature: Equatable {
        var size: Int64
        var modified: TimeInterval
        var isDataless: Bool
    }

    private struct Pending {
        var item: Item
        var last: Signature
        var startedAt: Date
        var requestedDownload = false
        var task: Task<Void, Never>?
    }

    /// Ready files, in the order they settled.
    public nonisolated let ready: AsyncStream<Item>
    private let continuation: AsyncStream<Item>.Continuation

    private var delay: TimeInterval
    /// Give up on files that never settle (a stuck download).
    private let maxWait: TimeInterval
    private var pending: [String: Pending] = [:]

    public static let defaultDelay: TimeInterval = 2
    public static let delayRange: ClosedRange<TimeInterval> = 1...30

    public init(delay: TimeInterval = Settler.defaultDelay, maxWait: TimeInterval = 600) {
        self.delay = delay
        self.maxWait = maxWait
        (ready, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        continuation.finish()
    }

    /// Settle delay in seconds. The app clamps it to 1–30 s; tests use less.
    public func setDelay(_ seconds: TimeInterval) {
        delay = max(0.05, seconds)
    }

    public var pendingCount: Int { pending.count }

    /// Starts watching `item`. A file already waiting keeps its timer; an
    /// "added" event wins over "modified".
    public func submit(_ item: Item) {
        let key = item.url.standardizedFileURL.path
        if IgnoreFilter.isInProgress(name: item.url.lastPathComponent) { return }
        if var existing = pending[key] {
            if item.kind == .added { existing.item.kind = .added }
            existing.item.needsContents = existing.item.needsContents || item.needsContents
            pending[key] = existing
            return
        }
        guard let signature = Settler.signature(of: item.url) else { return }
        pending[key] = Pending(item: item, last: signature, startedAt: Date())
        schedule(key)
    }

    /// Drops everything waiting (global pause).
    public func cancelAll() {
        for entry in pending.values { entry.task?.cancel() }
        pending = [:]
    }

    private func schedule(_ key: String) {
        let delay = delay
        pending[key]?.task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.check(key)
        }
    }

    private func check(_ key: String) {
        guard var entry = pending[key] else { return }
        guard let signature = Settler.signature(of: entry.item.url),
              Date().timeIntervalSince(entry.startedAt) < maxWait
        else {
            pending[key] = nil
            return
        }
        let waitingForDownload = entry.item.needsContents && signature.isDataless
        if signature == entry.last && !waitingForDownload {
            pending[key] = nil
            continuation.yield(entry.item)
            return
        }
        if waitingForDownload && !entry.requestedDownload {
            // The action will read the file, so fetch it now (spec §12).
            try? FileManager.default.startDownloadingUbiquitousItem(at: entry.item.url)
            entry.requestedDownload = true
        }
        entry.last = signature
        pending[key] = entry
        schedule(key)
    }

    /// Size, modification date, and dataless flag, read fresh from disk.
    static func signature(of url: URL) -> Signature? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return Signature(
            size: Int64(info.st_size),
            modified: modified,
            isDataless: info.st_flags & FileSnapshot.datalessFlag != 0
        )
    }
}
