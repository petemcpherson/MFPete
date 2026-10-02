import CoreServices
import Foundation

/// One file system change in a watched folder, after flag mapping (spec §5.1).
public struct FileEvent: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Created, moved in, or renamed into place.
        case added
        /// Contents or metadata changed.
        case modified
        /// Deleted, or moved or renamed out.
        case removed
    }

    public var url: URL
    public var kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    /// How long after an item's creation a "created" flag is still trusted.
    public static let stickyCreatedWindow: TimeInterval = 2

    /// Maps raw FSEvents flags to an event kind. `exists` says whether the
    /// item is on disk now, which tells the two halves of a rename apart:
    /// renamed into a folder = added, renamed out = removed.
    ///
    /// FSEvents keeps the "created" flag on later events for a recently
    /// created file, so a write to it can look like a new file. With
    /// `createdLongAgo` (the item was born more than
    /// `stickyCreatedWindow` ago, and this is a live event, not replay), a
    /// created-and-changed event counts as modified. Renames always count
    /// as added: that is how finished downloads arrive.
    ///
    /// Returns nil for events that are not about one item (root changes,
    /// mounts, history markers).
    public static func kind(flags: FSEventStreamEventFlags, exists: Bool, createdLongAgo: Bool = false) -> Kind? {
        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        let created = has(kFSEventStreamEventFlagItemCreated)
        let removed = has(kFSEventStreamEventFlagItemRemoved)
        let renamed = has(kFSEventStreamEventFlagItemRenamed)
        let changed = has(kFSEventStreamEventFlagItemModified)
            || has(kFSEventStreamEventFlagItemInodeMetaMod)
            || has(kFSEventStreamEventFlagItemXattrMod)
            || has(kFSEventStreamEventFlagItemFinderInfoMod)
            || has(kFSEventStreamEventFlagItemChangeOwner)

        if !exists {
            return removed || renamed ? .removed : nil
        }
        if created && changed && createdLongAgo && !renamed && !removed { return .modified }
        // Flags for one path can pile up within the stream latency, so a
        // file that was deleted and created again carries both. It exists,
        // so it counts as added.
        if created || renamed || removed { return .added }
        return changed ? .modified : nil
    }
}

/// Events delivered by one FSEvents callback.
public struct FileEventBatch: Sendable {
    public var events: [FileEvent] = []
    /// Folders whose events were dropped or coalesced. Scan them in full and
    /// compare against the processed-file record (spec §5.1).
    public var rescanFolders: [URL] = []
    /// Event IDs wrapped or history is unusable. Scan every watched folder.
    public var rescanAll = false
    /// Replay from the stored event ID has finished.
    public var historyDone = false
    /// Highest event ID in the batch.
    public var lastEventID: UInt64?

    public init() {}
}
