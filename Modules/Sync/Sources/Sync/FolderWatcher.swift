import CoreServices
import Events
import Foundation

// MARK: - What the watcher reports

/// One folder to watch, spelled the way its consumer spells it (ROADMAP item 5).
///
/// **The spelling is the consumer's, the watch is the disk's.** FSEvents watches the resolved
/// folder and reports what it finds there in resolved spelling: on this Mac iCloud Drive ▸
/// Documents is a link to `~/Documents`, and a temp folder under `/var` lives under `/private/var`.
/// A root handed over through the link is watched at its target and its events come back spelled
/// through the link again (``FolderWatchEvent/path``), so a consumer never meets a second spelling
/// of its own folder. The resolved one rides along as ``FolderWatchEvent/realPath``.
public struct FolderWatchRoot: Hashable, Sendable {
    /// Tilde expanded, trailing slashes trimmed (`PathBoundary.normalizedRoot`) — nothing more,
    /// so the events say exactly what the consumer said.
    public let path: String

    public init(path: String) {
        self.path = PathBoundary.normalizedRoot(path)
    }
}

/// One change FSEvents reported under a watched root. **A hint, never a listing**: the watcher
/// says *something happened here*, and a walk of the folder decides what is there now.
public struct FolderWatchEvent: Equatable, Sendable {

    /// What happened to the item, as FSEvents' item flags say it. Several can be set at once —
    /// FSEvents folds a burst on one item into one event — so read it as "at least these".
    public struct Change: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let created = Change(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
        public static let removed = Change(rawValue: UInt32(kFSEventStreamEventFlagItemRemoved))
        public static let renamed = Change(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
        public static let modified = Change(rawValue: UInt32(kFSEventStreamEventFlagItemModified))
        public static let inodeMetadata = Change(rawValue: UInt32(kFSEventStreamEventFlagItemInodeMetaMod))
        public static let finderInfo = Change(rawValue: UInt32(kFSEventStreamEventFlagItemFinderInfoMod))
        public static let owner = Change(rawValue: UInt32(kFSEventStreamEventFlagItemChangeOwner))
        public static let extendedAttributes = Change(rawValue: UInt32(kFSEventStreamEventFlagItemXattrMod))
        public static let isFile = Change(rawValue: UInt32(kFSEventStreamEventFlagItemIsFile))
        public static let isDirectory = Change(rawValue: UInt32(kFSEventStreamEventFlagItemIsDir))
        public static let isSymlink = Change(rawValue: UInt32(kFSEventStreamEventFlagItemIsSymlink))

        /// Every bit this type names — what an event's raw flags are masked to.
        static let all: Change = [.created, .removed, .renamed, .modified, .inodeMetadata, .finderInfo,
                                  .owner, .extendedAttributes, .isFile, .isDirectory, .isSymlink]
    }

    /// FSEvents' id for the change: system-wide and increasing, so it orders this change against
    /// any moment ``FolderWatcher/currentEventId()`` was read — the "was this before or after that
    /// walk started?" a consumer needs, which a delivery time cannot answer (delivery lags the
    /// change by the stream's latency).
    public let id: UInt64
    /// The watched root this event is under, as the consumer spelled it.
    public let root: String
    /// The changed item, spelled under ``root`` the way the consumer spells the root.
    public let path: String
    /// The changed item as FSEvents spelled it — the resolved location on disk.
    public let realPath: String
    public let change: Change
    /// The item's inode number, when FSEvents gave one.
    public let fileID: UInt64?
    /// The item's document id (`kFSEventStreamCreateWithDocID`), when FSEvents gave one — stable
    /// across the safe-save rename dance an app's save does, so a consumer can follow one document
    /// through a burst that removes and recreates its path.
    public let documentID: UInt64?
    /// This process made the change (`kFSEventStreamCreateFlagMarkSelf`). Never set on a replayed
    /// event: FSEvents does not record who made a change in its history.
    public let isOwn: Bool
    /// Replayed from FSEvents' history (the stream started from a stored event id and has not yet
    /// reached its `HistoryDone` sentinel) rather than seen as it happened.
    ///
    /// **False does not prove the change came after watching began.** fseventsd numbers a change
    /// when it reads it from the kernel, a moment after the write, and a change it had not read
    /// when the stream started arrives after the sentinel as a live event (measured,
    /// `aRestartReplaysWhatChangedWhileNothingWatched`). Order by ``id``, never by this flag.
    public let isHistorical: Bool

    public init(id: UInt64, root: String, path: String, realPath: String, change: Change,
                fileID: UInt64? = nil, documentID: UInt64? = nil, isOwn: Bool = false,
                isHistorical: Bool = false) {
        self.id = id
        self.root = root
        self.path = path
        self.realPath = realPath
        self.change = change
        self.fileID = fileID
        self.documentID = documentID
        self.isOwn = isOwn
        self.isHistorical = isHistorical
    }
}

/// **FSEvents cannot say what changed under ``path``** — treat everything there as changed and
/// list it again. The watcher's way of never claiming more than the events give.
public struct FolderWatchRescan: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// `MustScanSubDirs`: FSEvents coalesced too much under this folder to name the items.
        case mustScanSubDirs
        /// `UserDropped` / `KernelDropped`: events were lost somewhere on the way here.
        case eventsDropped
        /// `EventIdsWrapped`: the ids rolled over, so no stored id orders anything any more.
        case eventIdsWrapped
        /// `RootChanged`: the watched folder itself, or a folder above it, moved or went away.
        case rootChanged
        /// `Mount` / `Unmount` at or under the root: a different volume is there now.
        case volumeChanged
        /// No stored event id for this volume — nothing to replay since the last time we looked.
        case noHistory
        /// The volume's FSEvents history is not the one the stored id belongs to (its
        /// `FSEventsCopyUUIDForDevice` changed: history purged, volume erased or replaced).
        case historyLost
    }

    /// The watched root, as the consumer spelled it.
    public let root: String
    /// Where to list again, spelled under ``root`` — the root itself for every reason but
    /// `.mustScanSubDirs`, which can name a folder below it.
    public let path: String
    public let reason: Reason
    /// Everything up to this id may be missing from what a consumer has seen; a listing that
    /// started after it is clear.
    public let id: UInt64

    public init(root: String, path: String, reason: Reason, id: UInt64) {
        self.root = root
        self.path = path
        self.reason = reason
        self.id = id
    }
}

/// What the watcher hands its consumer at once: everything since the last batch, coalesced.
public struct FolderWatchBatch: Equatable, Sendable {
    public var events: [FolderWatchEvent] = []
    public var rescans: [FolderWatchRescan] = []

    public init(events: [FolderWatchEvent] = [], rescans: [FolderWatchRescan] = []) {
        self.events = events
        self.rescans = rescans
    }

    public var isEmpty: Bool { events.isEmpty && rescans.isEmpty }
    /// The newest id the batch speaks for, or 0 when it is empty.
    public var latestId: UInt64 { max(events.map(\.id).max() ?? 0, rescans.map(\.id).max() ?? 0) }
}

// MARK: - The stored history

/// The last event id seen per volume, and which FSEvents history it belongs to — what lets the next
/// launch replay what changed while the app was closed, and tell when it cannot.
///
/// Keyed by the volume's own UUID (`volumeUUIDStringKey`), which survives a reboot; the stored
/// `deviceUUID` is FSEvents' identity for that volume's history (`FSEventsCopyUUIDForDevice`),
/// which changes when the history is purged and is how a replay knows its stored id has gone
/// meaningless.
public struct FolderWatchHistory: Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var deviceUUID: String
        public var lastEventId: UInt64
        public init(deviceUUID: String, lastEventId: UInt64) {
            self.deviceUUID = deviceUUID
            self.lastEventId = lastEventId
        }
    }

    let load: @Sendable () -> [String: Record]
    let save: @Sendable ([String: Record]) -> Void

    public init(load: @escaping @Sendable () -> [String: Record],
                save: @escaping @Sendable ([String: Record]) -> Void) {
        self.load = load
        self.save = save
    }

    /// The defaults key the app's history lives under.
    public static let defaultsKey = "folderWatchHistory"

    /// One JSON blob under ``defaultsKey`` in `defaults` — the app's, and only the app's.
    public static func userDefaults(_ defaults: UserDefaults, key: String = defaultsKey) -> FolderWatchHistory {
        nonisolated(unsafe) let defaults = defaults
        return FolderWatchHistory(
            load: {
                guard let data = defaults.data(forKey: key) else { return [:] }
                return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
            },
            save: { records in
                guard let data = try? JSONEncoder().encode(records) else { return }
                defaults.set(data, forKey: key)
            })
    }

    /// Held in memory and nowhere else — for a test, or a consumer that wants no replay.
    public static func inMemory(_ initial: [String: Record] = [:]) -> FolderWatchHistory {
        let box = Box(initial)
        return FolderWatchHistory(load: { box.value }, save: { box.value = $0 })
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Record]
        init(_ initial: [String: Record]) { stored = initial }
        var value: [String: Record] {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}

// MARK: - Coalescing

/// When a batch is due: once the events have been quiet for `quiet`, or `maxDelay` after the first
/// one, whichever comes first — so a provider's burst of hundreds of changes reaches the consumer
/// once, and a provider that never stops still reaches it every `maxDelay`.
struct FolderWatchCoalescer: Equatable {
    let quiet: TimeInterval
    let maxDelay: TimeInterval
    private(set) var firstAt: Date?
    private(set) var lastAt: Date?

    init(quiet: TimeInterval, maxDelay: TimeInterval) {
        self.quiet = quiet
        self.maxDelay = maxDelay
    }

    /// Notes an arrival and answers when the pending batch is now due.
    mutating func note(at now: Date) -> Date {
        if firstAt == nil { firstAt = now }
        lastAt = now
        return deadline!
    }

    var deadline: Date? {
        guard let firstAt, let lastAt else { return nil }
        return min(lastAt.addingTimeInterval(quiet), firstAt.addingTimeInterval(maxDelay))
    }

    func isDue(at now: Date) -> Bool { deadline.map { now >= $0 } ?? false }

    mutating func reset() {
        firstAt = nil
        lastAt = nil
    }
}

// MARK: - Interpreting raw events

/// One event as the FSEvents callback hands it over, before it is placed under a root.
struct RawFolderEvent: Equatable {
    var id: UInt64
    var flags: UInt32
    var path: String
    var fileID: UInt64? = nil
    var documentID: UInt64? = nil
}

/// A watched root with its resolved location: the pair the spelling is translated between.
struct ResolvedWatchRoot: Hashable {
    /// The consumer's spelling.
    var spelled: String
    /// Where it really is, as FSEvents will spell its events.
    var real: String
}

extension FolderWatcher {

    /// Places one stream's raw events under its roots: an ordinary change becomes an event per
    /// root that holds it, a flag that means "FSEvents does not know" becomes a rescan, and the
    /// `HistoryDone` sentinel ends the replay. Pure, so every flag is testable without FSEvents.
    ///
    /// - Parameter replaying: whether the stream is still replaying history when the first of
    ///   `raw` arrives; the answer after the last comes back, so the next callback continues it.
    /// - Parameter now: ``currentEventId()`` as the callback runs. **Every rescan is dated no
    ///   earlier than this**, because the ids FSEvents puts on these flags do not say when:
    ///   `RootChanged` arrives with id ZERO (FSEvents.h), and a consumer ordering it against a walk
    ///   would find every walk newer — a moved root that marked nothing. Dated now, it reads as
    ///   "anything listed before this moment is suspect", which is what each of them means.
    static func interpret(_ raw: [RawFolderEvent], roots: [ResolvedWatchRoot],
                          replaying: Bool, now: UInt64) -> (batch: FolderWatchBatch, replaying: Bool) {
        var batch = FolderWatchBatch()
        var replaying = replaying
        for event in raw {
            let flags = Int(event.flags)
            if flags & kFSEventStreamEventFlagHistoryDone != 0 {
                replaying = false
                continue
            }
            let rescanId = max(event.id, now)
            func rescanAll(_ reason: FolderWatchRescan.Reason) {
                for root in roots {
                    batch.rescans.append(FolderWatchRescan(root: root.spelled, path: root.spelled,
                                                           reason: reason, id: rescanId))
                }
            }
            if flags & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                rescanAll(.eventsDropped)
                continue
            }
            if flags & kFSEventStreamEventFlagEventIdsWrapped != 0 {
                rescanAll(.eventIdsWrapped)
                continue
            }
            if flags & kFSEventStreamEventFlagRootChanged != 0 {
                // Reported with the root's own path; a root it does not name is untouched.
                for root in roots where root.real == event.path || root.spelled == event.path {
                    batch.rescans.append(FolderWatchRescan(root: root.spelled, path: root.spelled,
                                                           reason: .rootChanged, id: rescanId))
                }
                continue
            }
            if flags & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 {
                // A volume came or went at `path`: every root at, under or above it.
                for root in roots
                where PathBoundary.lexicalRelativize(event.path, under: root.real) != nil
                    || PathBoundary.lexicalRelativize(root.real, under: event.path) != nil {
                    batch.rescans.append(FolderWatchRescan(root: root.spelled, path: root.spelled,
                                                           reason: .volumeChanged, id: rescanId))
                }
                continue
            }
            let placed = spell(event.path, in: roots)
            if flags & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                // A folder no root places is still a folder FSEvents lost track of under one of
                // them: the whole stream, rather than nothing.
                guard !placed.isEmpty else {
                    rescanAll(.mustScanSubDirs)
                    continue
                }
                for (root, path) in placed {
                    batch.rescans.append(FolderWatchRescan(root: root.spelled, path: path,
                                                           reason: .mustScanSubDirs, id: rescanId))
                }
                continue
            }
            let change = FolderWatchEvent.Change(rawValue: event.flags & FolderWatchEvent.Change.all.rawValue)
            let isOwn = flags & kFSEventStreamEventFlagOwnEvent != 0
            for (root, path) in placed {
                batch.events.append(FolderWatchEvent(
                    id: event.id, root: root.spelled, path: path, realPath: event.path, change: change,
                    fileID: event.fileID, documentID: event.documentID, isOwn: isOwn,
                    isHistorical: replaying))
            }
        }
        return (batch, replaying)
    }

    /// Every root holding `realPath`, with the path spelled under that root. Exact first; then
    /// case-insensitively, because the default macOS volume is, and a root typed in another case
    /// than the disk's would otherwise hear nothing.
    static func spell(_ realPath: String, in roots: [ResolvedWatchRoot]) -> [(ResolvedWatchRoot, String)] {
        var placed: [(ResolvedWatchRoot, String)] = []
        for root in roots {
            let relative: String
            if let exact = PathBoundary.lexicalRelativize(realPath, under: root.real) {
                relative = exact
            } else if let folded = PathBoundary.lexicalRelativize(realPath.lowercased(),
                                                                 under: root.real.lowercased()) {
                // The tail in the disk's own case: the folded match only says where the root ends.
                relative = folded.isEmpty ? "" : String(realPath.suffix(folded.count))
            } else {
                continue
            }
            placed.append((root, relative.isEmpty ? root.spelled : root.spelled + "/" + relative))
        }
        return placed
    }
}

// MARK: - The watcher

/// Where a newly watched root's stream starts.
public enum FolderWatchReplay: Hashable, Sendable {
    /// From now. Nothing before the stream started is reported, and nothing is claimed about it.
    case none
    /// From the last id stored for the root's volume (``FolderWatchHistory``) — what happened while
    /// nobody watched, since the last launch. With no stored id, or one from a history that has
    /// since gone (`FSEventsCopyUUIDForDevice` changed), the root gets a `.noHistory` /
    /// `.historyLost` rescan as of the start instead.
    ///
    /// **Per volume, not per root**: a root this watcher has never watched replays from wherever
    /// the volume's record stands, which says nothing about that root's past before it. A consumer
    /// starting on a new root has no listing to compare against anyway, and lists it in full.
    case stored
    /// From this id, read earlier in this boot with ``FolderWatcher/currentEventId()`` — for a
    /// consumer holding a listing it made while nothing watched the root. A history that has gone
    /// since the stored record was written makes it a `.historyLost` rescan.
    case since(UInt64)
}

/// **Watches folders with FSEvents and says, coalesced, what changed under them** — the "when
/// files change" trigger ROADMAP item 5 describes, shared by the panes' freshness and RD67's
/// one-way sync. Free of any UI concern: it reports, the consumer decides.
///
/// - **File-level, with document ids** (`FileEvents | UseCFTypes | UseExtendedData | WithDocID`),
///   and marked when this process made the change (`MarkSelf`), so a consumer can leave its own
///   writes to the paths that already account for them.
/// - **Hints, not listings.** A consumer re-lists before it acts; the watcher only says where.
/// - **Never more freshness than the events give.** Where FSEvents cannot name the items —
///   `MustScanSubDirs`, dropped events, wrapped ids, a moved root, a volume change — and where the
///   history it would replay is gone, it says so with a ``FolderWatchRescan``.
/// - **Replays across launches**, when asked (``FolderWatchReplay/stored``). The last id delivered
///   is stored per volume (``FolderWatchHistory``).
///
/// **One stream per root, and a root's stream is never restarted while it stays watched.** A
/// restart has to replay from the old stream's last delivered id to lose nothing in between, and a
/// replay drops the mark FSEvents puts on this process's own writes (`MarkSelf` "has no effect on
/// historical events") — so a write the consumer made a moment before would come back as someone
/// else's. Measured: one shared stream, restarted when the second pane's folder was added, replayed
/// the fixture's own writes unmarked and flagged the first pane changed.
///
/// Everything mutable lives on one serial queue; the handler runs there, so it must not call back
/// into ``watch(_:)``, ``stop()`` or ``roots`` synchronously — each is a `queue.sync`.
public final class FolderWatcher: @unchecked Sendable {

    public typealias Handler = @Sendable (FolderWatchBatch) -> Void

    /// FSEvents' most recently generated event id, system-wide. Read it before listing a folder,
    /// and an event with a greater id is a change the listing may not have seen.
    public static func currentEventId() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    private let history: FolderWatchHistory
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.abhishekgirish.SyncCloud.FolderWatcher")
    /// Marks `queue`, so `deinit` can tell whether it is already running on it.
    private static let queueKey = DispatchSpecificKey<Bool>()

    // Queue-confined.
    private var coalescer: FolderWatchCoalescer
    private var pending = FolderWatchBatch()
    private var flushToken = 0
    private var streams: [FolderWatchRoot: Stream] = [:]
    /// The roots with a live stream. A root asked for that could not be watched is not in here,
    /// so the next ``watch(_:)`` asking for it tries again rather than taking the set as settled.
    private var watched: Set<FolderWatchRoot> = []
    /// Roots already logged as unwatchable — the retry above is quiet after the first line.
    private var reportedUnwatchable: Set<FolderWatchRoot> = []
    /// The history as last read or written — read once, so a burst's callbacks do not each decode it.
    private var storedRecords: [String: FolderWatchHistory.Record]?

    /// - Parameters:
    ///   - history: where the last id per volume is kept. No default: only the real app may write
    ///     the real defaults domain.
    ///   - latency: FSEvents' own coalescing window, the first fold of a burst.
    ///   - quiet: how long the events must stop before a batch goes out — the second fold.
    ///   - maxDelay: the longest a batch waits however busy the folder stays.
    public init(history: FolderWatchHistory, latency: TimeInterval = 0.3,
                quiet: TimeInterval = 1, maxDelay: TimeInterval = 5, handler: @escaping Handler) {
        self.history = history
        self.latency = latency
        self.coalescer = FolderWatchCoalescer(quiet: quiet, maxDelay: maxDelay)
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    /// Invalidates on the queue the streams deliver on, so no callback is mid-flight while its
    /// stream goes. Whatever is still being coalesced is dropped, and so is its id: nothing was
    /// persisted past what was delivered (``persist()``), so a `.stored` replay brings it back.
    deinit {
        let streams = self.streams
        let invalidate = { for stream in streams.values { stream.invalidate() } }
        if DispatchQueue.getSpecific(key: Self.queueKey) == true { invalidate() } else { queue.sync(execute: invalidate) }
    }

    /// The roots being watched now — those with a live stream.
    public var roots: Set<FolderWatchRoot> {
        queue.sync { watched }
    }

    /// How many FSEvents callbacks have arrived — for a test showing that a batch joined several.
    var callbackCount: Int { queue.sync { callbacks } }
    private var callbacks = 0

    /// Watches exactly `roots` from now on, every newly added one replaying as `replay` says. A
    /// root already watched keeps its stream; one no longer listed stops. Synchronous: when it
    /// returns, a change made afterwards under any of them will be reported.
    public func watch(_ roots: Set<FolderWatchRoot>, replay: FolderWatchReplay = .stored) {
        watch(Dictionary(uniqueKeysWithValues: roots.map { ($0, replay) }))
    }

    /// ``watch(_:replay:)`` with a replay per root — read only for the roots not yet watched.
    public func watch(_ roots: [FolderWatchRoot: FolderWatchReplay]) {
        queue.sync {
            let wanted = Set(roots.keys)
            guard wanted != watched else { return }
            for root in watched.subtracting(wanted) {
                streams.removeValue(forKey: root)?.invalidate()
            }
            // Judged against the history as it stood BEFORE this call: the first new root on a
            // volume rewrites the record, and a second root judged against that would find it
            // intact and be told nothing about the history the first one found gone.
            let before = storedRecords ?? history.load()
            var records = before
            var recordsChanged = false
            for root in wanted where streams[root] == nil {
                if let stream = start(root, replay: roots[root] ?? .none, judgedAgainst: before,
                                      records: &records, recordsChanged: &recordsChanged) {
                    streams[root] = stream
                }
            }
            watched = Set(streams.keys)
            storedRecords = records
            if recordsChanged { history.save(records) }
            if !pending.isEmpty { schedule() }
            Logger.shared.debug("[watch] watching \(watched.count) folder(s), \(streams.count) stream(s) live")
        }
    }

    /// Stops watching. A batch still being coalesced goes out first.
    public func stop() {
        queue.sync {
            for stream in streams.values { stream.invalidate() }
            flush()
            streams = [:]
            watched = []
        }
    }

    // MARK: Streams (queue-confined)

    /// One FSEvents stream: one root, and where its replay stands.
    private final class Stream {
        let volumeKey: String
        let deviceUUID: String?
        let root: ResolvedWatchRoot
        var ref: FSEventStreamRef?
        var replaying: Bool
        var latestId: UInt64
        weak var owner: FolderWatcher?

        init(volumeKey: String, deviceUUID: String?, root: ResolvedWatchRoot, replaying: Bool,
             latestId: UInt64) {
            self.volumeKey = volumeKey
            self.deviceUUID = deviceUUID
            self.root = root
            self.replaying = replaying
            self.latestId = latestId
        }

        func invalidate() {
            guard let ref else { return }
            FSEventStreamStop(ref)
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
            self.ref = nil
        }
    }

    private func start(_ watchRoot: FolderWatchRoot, replay: FolderWatchReplay,
                       judgedAgainst before: [String: FolderWatchHistory.Record],
                       records: inout [String: FolderWatchHistory.Record], recordsChanged: inout Bool) -> Stream? {
        guard let real = Self.resolve(watchRoot.path) else {
            if reportedUnwatchable.insert(watchRoot).inserted {
                Logger.shared.info("[watch] cannot watch “\(watchRoot.path)”: it does not resolve to a folder on disk")
            }
            return nil
        }
        reportedUnwatchable.remove(watchRoot)
        var info = stat()
        guard stat(real, &info) == 0 else { return nil }
        let root = ResolvedWatchRoot(spelled: watchRoot.path, real: real)
        let volumeKey = Self.volumeKey(for: real, device: info.st_dev)
        let deviceUUID = Self.deviceUUID(info.st_dev)
        let stored = before[volumeKey]
        let historyIntact = stored != nil && deviceUUID != nil && stored?.deviceUUID == deviceUUID
        let now = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

        var since = now
        var lost: FolderWatchRescan.Reason?
        switch replay {
        case .none:
            break
        case .stored:
            if historyIntact, let stored { since = stored.lastEventId } else { lost = stored == nil ? .noHistory : .historyLost }
        case .since(let id):
            if stored == nil || historyIntact { since = id } else { lost = .historyLost }
        }
        let replaying = since != now
        let stream = Stream(volumeKey: volumeKey, deviceUUID: deviceUUID, root: root, replaying: replaying,
                            latestId: replaying ? since : 0)
        stream.owner = self
        guard create(stream, since: since) else {
            Logger.shared.warning("[watch] FSEvents refused a stream for “\(real)”; it is not watched")
            return nil
        }
        // Read once the stream is up, so the gap before it started is inside what this id covers:
        // a listing that starts after it is clear of everything the stream might have missed.
        let startMark = Self.currentEventId()
        if !replaying { stream.latestId = startMark }
        if let lost {
            // Nothing to replay, so nothing since the last look can be vouched for: the root is
            // changed as of now.
            pending.rescans.append(FolderWatchRescan(root: root.spelled, path: root.spelled, reason: lost, id: startMark))
            Logger.shared.info("[watch] \(lost == .noHistory ? "no stored history" : "the stored history is gone")"
                               + " for “\(root.real)”; treating it as changed")
        }
        // A record for the volume from now on, so the next `.stored` start has one and the next
        // change of history is noticed.
        if let deviceUUID, !historyIntact, records[volumeKey]?.deviceUUID != deviceUUID {
            records[volumeKey] = FolderWatchHistory.Record(deviceUUID: deviceUUID, lastEventId: startMark)
            recordsChanged = true
        }
        return stream
    }

    private func create(_ stream: Stream, since: FSEventStreamEventId) -> Bool {
        // The stream holds its own reference to `Stream` (retain/release below), so a callback
        // FSEvents has already queued can never meet a freed one, whatever order teardown runs in.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(stream).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Stream>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Stream>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateWithDocID
                | kFSEventStreamCreateFlagMarkSelf | kFSEventStreamCreateFlagWatchRoot)
        guard let ref = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context,
                                            [stream.root.real] as CFArray, since, latency, flags) else { return false }
        FSEventStreamSetDispatchQueue(ref, queue)
        guard FSEventStreamStart(ref) else {
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
            return false
        }
        stream.ref = ref
        return true
    }

    /// Stores, per volume, the OLDEST newest-delivered id among its live streams: a `.stored` replay
    /// from it then misses nothing any of them had yet to deliver, at the price of repeating what
    /// the others had. Only ids that reached the HANDLER — called from ``flush()`` once a batch has
    /// gone out, never as a callback arrives: a batch still being coalesced is lost with the
    /// process, and an id stored ahead of it would make the next replay skip it for good.
    private func persist() {
        var records = storedRecords ?? history.load()
        var oldest: [String: (uuid: String, id: UInt64)] = [:]
        for stream in streams.values {
            guard let uuid = stream.deviceUUID else { continue }
            if let seen = oldest[stream.volumeKey], seen.id <= stream.latestId { continue }
            oldest[stream.volumeKey] = (uuid, stream.latestId)
        }
        var changed = false
        for (key, value) in oldest {
            let record = FolderWatchHistory.Record(deviceUUID: value.uuid, lastEventId: value.id)
            if records[key] != record {
                records[key] = record
                changed = true
            }
        }
        storedRecords = records
        if changed { history.save(records) }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let stream = Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue()
        let entries = unsafeBitCast(paths, to: NSArray.self)
        var raw: [RawFolderEvent] = []
        raw.reserveCapacity(count)
        for index in 0..<count {
            let entry = entries[index] as? NSDictionary
            raw.append(RawFolderEvent(
                id: ids[index], flags: flags[index],
                path: (entry?[kFSEventStreamEventExtendedDataPathKey as String] as? String) ?? "",
                fileID: (entry?[kFSEventStreamEventExtendedFileIDKey as String] as? NSNumber)?.uint64Value,
                documentID: (entry?[kFSEventStreamEventExtendedDocIDKey as String] as? NSNumber)?.uint64Value))
        }
        stream.owner?.receive(raw, from: stream)
    }

    /// On the queue, from the callback.
    private func receive(_ raw: [RawFolderEvent], from stream: Stream) {
        // A stream invalidated while this callback waited on the queue speaks for nothing.
        guard stream.ref != nil else { return }
        callbacks += 1
        let (batch, replaying) = Self.interpret(raw, roots: [stream.root], replaying: stream.replaying,
                                                now: Self.currentEventId())
        stream.replaying = replaying
        if let newest = raw.map(\.id).max(), newest > stream.latestId {
            stream.latestId = newest
        }
        guard !batch.isEmpty else { return }
        pending.events += batch.events
        pending.rescans += batch.rescans
        schedule()
    }

    private func schedule() {
        let deadline = coalescer.note(at: Date())
        flushToken &+= 1
        let token = flushToken
        queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in
            guard let self, token == self.flushToken else { return }
            self.flush()
        }
    }

    private func flush() {
        coalescer.reset()
        if !pending.isEmpty {
            let batch = pending
            pending = FolderWatchBatch()
            handler(batch)
        }
        persist()
    }

    // MARK: Resolution

    /// `realpath(3)`: the folder's location with every link resolved, as FSEvents spells it — nil
    /// when nothing is there, or it is not a folder.
    static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let real = String(cString: resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return real
    }

    static func volumeKey(for path: String, device: dev_t) -> String {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString ?? "device-\(device)"
    }

    static func deviceUUID(_ device: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
