import AppKit
import Combine
import Events
import Sync

/// What happened to the open document's file since the editor last read or wrote it (TE59).
///
/// **Decided from the file system's present state, never from the event that prompted the look.**
/// Events come in bursts, out of order, and from the editor's own saves; the stamp at the path
/// compared with ``EditorDocument/diskStamp`` gives one answer for all of them.
public enum EditorDiskChange: Equatable, Sendable {
    /// The file is what the document last read or wrote — including just after the editor's own
    /// save, which moved the document's stamp to the one it read back.
    case none
    /// Something else is at the path now: edited in place, or replaced by an atomic save.
    case changed
    /// The path is empty and the file is somewhere else — renamed or moved.
    case moved(to: String)
    /// The path is empty and the file is gone: deleted, put in the Trash, moved to another volume
    /// (a copy and a delete), or replaced at the path by something that is not a file.
    case deleted

    /// What the file system says, read in one place so the rule below is a function of values.
    struct Observation: Equatable {
        /// The stamp of whatever is at the document's path, `nil` when nothing is.
        var atPath: EditorFileStore.Stamp?
        /// Whether that is a regular file — a folder given the note's name is not the note.
        var isRegularFile: Bool = true
        /// Where the watched file is now (``EditorFileWatcher/trackedPath``): `nil` when nothing is
        /// watched, or when its last link is gone.
        var trackedPath: String?
    }

    /// **The path first, then the descriptor** — and the order is the rule.
    ///
    /// An atomic save renames a NEW file over the path; the descriptor still holds the old one,
    /// which the save may have moved aside under a backup name before deleting it. Asked first,
    /// the descriptor would call every atomic save a move to `.rollback_…` or `note.md~`. So
    /// anything at the path settles it, and only an empty path asks where the file went.
    static func assess(path: String, known: EditorFileStore.Stamp?, observation: Observation) -> EditorDiskChange {
        if let atPath = observation.atPath {
            guard observation.isRegularFile else { return .deleted }
            guard atPath == known else { return .changed }
            // **A rename that only changes the case**: on a case-insensitive volume the old spelling
            // still finds the same file, stamp and all, so only the descriptor's name tells.
            if let tracked = observation.trackedPath, isCaseOnlyRename(tracked, of: path) {
                return .moved(to: spelled(tracked, like: path))
            }
            return .none
        }
        if let tracked = observation.trackedPath, !isSamePlace(tracked, path), !isInTrash(tracked) {
            return .moved(to: spelled(tracked, like: path))
        }
        return .deleted
    }

    /// **A rename keeps the folder as the document spelled it.** `F_GETPATH` answers with the real
    /// path, so a note opened through `~/OneDrive/…` (a link to `~/Library/CloudStorage/…`) would
    /// otherwise come back from a rename under the other spelling, and the header's location with
    /// it. A move to another folder has no spelling of its own to keep, and takes the real one.
    static func spelled(_ tracked: String, like original: String) -> String {
        let folder = (original as NSString).deletingLastPathComponent
        guard EditorFileStore.resolved(folder)
                == EditorFileStore.resolved((tracked as NSString).deletingLastPathComponent) else { return tracked }
        return (folder as NSString).appendingPathComponent((tracked as NSString).lastPathComponent)
    }

    /// The same name in the same folder, differing only in case — `note.md` and `Note.md`.
    static func isCaseOnlyRename(_ tracked: String, of path: String) -> Bool {
        let now = (tracked as NSString).lastPathComponent, was = (path as NSString).lastPathComponent
        guard now != was, now.compare(was, options: .caseInsensitive) == .orderedSame else { return false }
        return EditorDiskWatch.isInSameFolder(tracked, path)
    }

    /// Whether a path is inside a Trash — `~/.Trash`, a volume's `.Trashes`, iCloud Drive's
    /// `.Trash`. Finder's Move to Trash is a rename, and the file is followed nowhere: it was deleted.
    static func isInTrash(_ path: String) -> Bool {
        (path as NSString).pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Two spellings of one place — `F_GETPATH` answers with `/private/var/…` where the document may
    /// hold `/var/…`. The folders are resolved (they exist); the names are compared as written.
    static func isSamePlace(_ a: String, _ b: String) -> Bool {
        func folder(_ p: String) -> String {
            EditorFileStore.resolved((p as NSString).deletingLastPathComponent)
        }
        return (a as NSString).lastPathComponent == (b as NSString).lastPathComponent && folder(a) == folder(b)
    }
}

/// The banner over the document while a change from elsewhere waits for an answer (TE59).
public enum EditorDiskBanner: Equatable, Sendable {
    /// The file changed while the buffer held typing that is not on disk — Compare, Keep Mine,
    /// Use Disk Version.
    case changed
    /// The file is gone — Close, Save Again.
    case deleted

    /// The banner in the log's words.
    var logName: String {
        switch self {
        case .changed: return "changed on disk"
        case .deleted: return "no longer on disk"
        }
    }

    /// The banner's sentence.
    public func message(name: String) -> String {
        switch self {
        case .changed: return "“\(name)” changed on disk while you were typing."
        // **What is known, and no more**: a delete, the Trash, a disk ejected and the app's own
        // Move to Trash all leave the path empty with nowhere to follow — the header's "not saving
        // — no longer on disk" says the same.
        case .deleted: return "“\(name)” is no longer on disk."
        }
    }
}

/// What the watch does about one look at the disk — a pure answer, so every branch is a test.
enum EditorDiskResponse: Equatable {
    case nothing
    /// The disk agrees with the document again — a Keep Mine or a Save Again landed — so a standing
    /// banner has nothing left to ask.
    case clearBanner
    /// Re-read the file and replace the buffer, quietly, with the undo history emptied.
    case reload
    /// Leave the buffer alone and ask.
    case raise(EditorDiskBanner)
    /// Keep editing the same file at its new path.
    case follow(to: String)

    /// **Typing that is not on disk is never reloaded over** — that is the one rule with a cost if
    /// it is wrong, and everything else follows from it:
    ///
    /// - nothing changed: nothing to do, and a standing banner goes (the disk agrees again);
    /// - changed, nothing unsaved and no question standing about typing: reload;
    /// - changed with unsaved typing, or while the changed banner is already up: ask, and keep
    ///   asking — the banner is answered, never answered for you;
    /// - moved: follow, whatever the buffer holds — the file is the same one;
    /// - deleted: ask, whatever the buffer holds — the text on screen is now the only copy.
    static func to(_ change: EditorDiskChange, hasUnsavedTyping: Bool,
                   banner: EditorDiskBanner?) -> EditorDiskResponse {
        switch change {
        case .none:
            return banner == nil ? .nothing : .clearBanner
        case .changed:
            return hasUnsavedTyping || banner == .changed ? .raise(.changed) : .reload
        case .moved(let path):
            return .follow(to: path)
        case .deleted:
            return .raise(.deleted)
        }
    }
}

/// **Edit notices a change to the open file from elsewhere when it happens** (TE59), not only at
/// the next save.
///
/// One per app, beside the document it watches and outliving the window for the document's reason.
/// It watches the open document only — re-armed whenever ``EditorDocument/path`` moves, stopped
/// when nothing is open — and answers each change by ``EditorDiskResponse``'s rule:
///
/// - **Nothing typed since the last save: reload, quietly**, as the smallest edit to the shared
///   storage (so Source, Split and Edit in Preview all follow, and the caret stays put), with the
///   undo history emptied — after a reload ⌘Z does nothing. The status line says so briefly.
/// - **Typing not on disk: a banner, and no reload** — Compare, Keep Mine, Use Disk Version. The
///   history stays intact while it is up. The host stops autosave for as long as it stands
///   (``onBannerChange``), so nothing is written over either version while the question is open.
/// - **Moved or renamed: followed** — the document, its undo history, its caret and the host's
///   path-keyed state (``onMoved``) all move to the new path, and editing carries on.
/// - **Deleted: a banner** — Close, Save Again — with the text left on screen.
///
/// **The editor's own writes are never a change from elsewhere**: every write moves the document's
/// stamp to the one it read back, so a look afterwards finds the two equal; and while an autosave
/// write is out on a background thread — the one window where the file is newer than the stamp —
/// the look waits (``EditorDocument/backgroundWrites``). The save-time divergence check stays where
/// it was, as the backstop.
@MainActor
public final class EditorDiskWatch: ObservableObject {

    /// The question standing over the document, or `nil`.
    @Published public private(set) var banner: EditorDiskBanner?
    /// A few seconds of words for the status line — "Reloaded — changed elsewhere".
    @Published public private(set) var notice: Notice?

    public struct Notice: Equatable, Sendable {
        public var text: String
        var token: Int
    }

    /// The file moved and the document followed: the host moves what it keys by path.
    /// `byThisApp` when the look that followed it was the one after the app's own file operation
    /// (``reconcile(afterOwnFileOperation:)``), whose refresh has re-read the panes already.
    public var onMoved: ((_ from: String, _ to: String, _ byThisApp: Bool) -> Void)?
    /// The banner came or went — the host stops autosave while one stands, and resumes it after.
    public var onBannerChange: ((EditorDiskBanner?) -> Void)?

    /// How long events are left to settle before the disk is looked at. A save is often several
    /// events — a temporary file, a rename, a delete of the backup — and `vim` renames the file
    /// aside before it writes the new one, a moment in which the path is empty.
    let settle: Duration
    /// How long a notice stays up.
    let noticeDuration: Duration
    private let isCloudOnly: (String) -> Bool

    private weak var document: EditorDocument?
    private weak var undoStore: EditorUndoStore?
    private var watcher: EditorFileWatcher?
    private var subscription: AnyCancellable?
    private var conversions: AnyCancellable?
    /// Held, never removed: the watch lives as long as the app, and the block holds it weakly.
    private var activation: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    /// Set across the document's own move to a new path, so the path observer re-arms the watch
    /// without treating it as another file being opened.
    private var isFollowing = false
    /// A rename within the folder seen by one look, waiting for the next — see
    /// ``renameHasSettled(to:from:)``.
    private var pendingRename: String?
    /// The path a download is being waited on for, so a burst of events asks for it once.
    private var downloading: String?
    /// When a download of which path was last asked for — so a provider that answers and still
    /// leaves the file in the cloud is asked again a patience later, not in a loop.
    private var lastDownload: (path: String, at: ContinuousClock.Instant)?
    /// The file whose version on disk "Use Disk Version" is waiting to take once it has downloaded.
    private var useDisksWhenDownloaded: String?
    /// Paths whose download read is out on ``downloadQueue`` — at most one each.
    private var readsOut: Set<String> = []

    /// The serial queue every download read runs on — see ``download(_:)``.
    static let downloadQueueLabel = "SyncCloud.EditorDiskWatch.download"
    private static let downloadQueue = DispatchQueue(label: downloadQueueLabel, qos: .utility)

    // The download's seams, for the tests: the provider's API, the read that asks a provider with
    // none, how long a download is waited on before the watch looks anyway, and how often it checks.
    var startDownload: (String) throws -> Void = { try MaterializationStatus.download(atPath: $0) }
    var readFirstByte: @Sendable (String) -> Void = { _ = FileHandle(forReadingAtPath: $0)?.readData(ofLength: 1) }
    var downloadPatience: Duration = .seconds(60)
    var downloadPoll: Duration = .seconds(1)
    private var noticeToken = 0

    public init(settle: Duration = .milliseconds(250), noticeDuration: Duration = .seconds(4),
                isCloudOnly: @escaping (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }) {
        self.settle = settle
        self.noticeDuration = noticeDuration
        self.isCloudOnly = isCloudOnly
    }

    /// Starts watching `document` — whatever it has open now, and every file it opens from here on.
    /// Once; a second call with the same document does nothing.
    public func attach(document: EditorDocument, undoStore: EditorUndoStore) {
        guard self.document !== document else { return }
        self.document = document
        self.undoStore = undoStore
        // `$path` publishes in `willSet`, with the incoming value — which is all the watch needs:
        // a path to arm on. Nothing is compared until an event, by when the load has finished.
        subscription = document.$path.sink { [weak self] path in
            MainActor.assumeIsolated { self?.documentPathWillChange(to: path) }
        }
        // **The status line's other few seconds of words** (TE104): an edit converted a CRLF or CR
        // file to LF. Said here because this is where the status line's notices live, so a newer
        // one replaces an older one rather than two competing for the line.
        conversions = document.buffer.convertedToLF.sink { [weak self] in
            MainActor.assumeIsolated { self?.showNotice(Self.convertedToLFNotice) }
        }
        // **The net under the events**: a change made while the app was in the background is looked
        // for again when it comes forward, which also covers a download finishing with no event.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.reconcile() }
            }
    }

    // MARK: Following the open document

    private func documentPathWillChange(to path: String?) {
        if isFollowing {
            arm(path)
            return
        }
        // Another file — or the same one opened again, which is what "Reload from Disk" does: any
        // question about the last one is over.
        pending?.cancel()
        downloading = nil
        useDisksWhenDownloaded = nil
        notice = nil
        setBanner(nil)
        arm(path)
    }

    private func arm(_ path: String?) {
        watcher?.cancel()
        watcher = path.map { path in
            EditorFileWatcher(path: path, isCloudOnly: isCloudOnly) { [weak self] in
                Task { @MainActor in
                    self?.eventsHeard += 1
                    self?.eventArrived()
                }
            }
        }
    }

    /// How many kernel events have reached the watch — for the tests, which have no other way to see
    /// that closing a document cancelled its sources.
    private(set) var eventsHeard = 0

    /// Something happened: look once things have settled.
    func eventArrived() {
        pending?.cancel()
        let settle = self.settle
        pending = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.look(confirmingRenames: true)
        }
    }

    // MARK: Looking

    /// **Looks at the disk now and acts on what it finds** — what every event comes to after it has
    /// settled, and what the host calls straight after a write of its own or when autosave's own
    /// check finds the file diverged. Returns what it did.
    @discardableResult
    ///
    /// - Parameter afterOwnFileOperation: the look after one of the app's own file operations — a
    ///   rename, a move, Organize filing the note — so a move it follows is the app's, and the host
    ///   is told so (``onMoved``).
    public func reconcile(afterOwnFileOperation: Bool = false) -> Outcome {
        look(confirmingRenames: false, ownOperation: afterOwnFileOperation)
    }

    /// One look. **`confirmingRenames`** for a look an event prompted: a rename within the folder is
    /// then followed only once a second look, a settle later, still finds the path empty — see
    /// ``renameHasSettled(to:from:)``. The host's own looks follow at once.
    @discardableResult
    private func look(confirmingRenames: Bool, ownOperation: Bool = false) -> Outcome {
        guard let document, let path = document.path, document.refusal == nil else { return .nothing }
        // The editor's own write is out: the file is newer than the stamp, and it is ours. Look
        // again once it has committed.
        guard document.backgroundWrites == 0 else {
            eventArrived()
            return .nothing
        }
        let observation = observe(path)
        let change = EditorDiskChange.assess(path: path, known: document.diskStamp, observation: observation)
        // **A new stamp over the same bytes is not a change.** A `touch`, a sync client re-stamping
        // the file after uploading the editor's own save, a Time Machine restore of the identical
        // text: reloading for those would empty the undo history after every pause in typing, and
        // asking would put a question about nothing. Read once here, and handed on to the reload.
        let opened = change == .changed && !isCloudOnly(path) ? EditorFileStore.open(path: path) : nil
        if let opened, let stamp = Self.sameContentStamp(opened, as: document) {
            if needsRearm(observation) { arm(path) }
            document.restamp(stamp)
            Logger.shared.debug("[edit] \(path) was re-stamped with the same contents — nothing to reload")
            if let banner {
                Logger.shared.info("[edit] \(path) holds the text the document has as saved again — the “\(banner.logName)” question about it is over")
            }
            setBanner(nil)
            return .restamped
        }
        let response = EditorDiskResponse.to(change, hasUnsavedTyping: hasUnsavedTyping(document),
                                             banner: banner)
        if case .follow(let destination) = response {
            if confirmingRenames, observation.atPath == nil, Self.isInSameFolder(destination, path),
               !renameHasSettled(to: destination, from: path) {
                return .nothing
            }
        }
        pendingRename = nil
        // An atomic save — the editor's own included — leaves the file source on a deleted inode;
        // a re-arm puts it on the file the path holds now, or on the folder alone while it is gone.
        if case .follow = response {} else if needsRearm(observation) {
            arm(path)
        }
        switch response {
        case .nothing:
            return .nothing
        case .clearBanner:
            // Said, because the banner going on its own is something he sees happen.
            Logger.shared.info("[edit] \(path) agrees with the document again — the “\(banner?.logName ?? "")” question about it is over")
            setBanner(nil)
            return .settled
        case .raise(let kind):
            if banner != kind {
                Logger.shared.info(kind == .changed
                    ? "[edit] \(path) changed on disk while it held unsaved typing — asking, not reloading"
                    : "[edit] \(path) is no longer on disk (deleted, put in the Trash, or on a disk that went away) — keeping the text on screen")
            }
            setBanner(kind)
            // **A newer version still in the cloud is fetched while the question stands**, so Compare
            // and Use Disk Version have something to read when they are pressed.
            if kind == .changed, isCloudOnly(path) { download(path) }
            return .asked(kind)
        case .reload:
            return reloadQuietly(path, opened: opened)
        case .follow(let destination):
            follow(from: path, to: destination, byThisApp: ownOperation)
            // A move can carry an edit with it; the new path answers for both.
            _ = reconcile()
            return .followed(destination)
        }
    }

    /// **A rename within the folder is looked at twice before it is followed.** A save that renames
    /// the original aside and only then installs the new file — JetBrains' `___jb_old___`, Word's
    /// `~WRL…`, Emacs' backups — leaves the path empty for as long as the new file takes to write,
    /// which can outlast the settle; followed at the first look, the document went to the backup
    /// name, the backup's delete raised the deleted banner, and the new file was never loaded. So
    /// the first look only notes the rename and looks again a settle later: a path filled again by
    /// then is a change there, and one still empty is a rename, followed. A move to another folder
    /// is not a save's doing, and is followed at once.
    ///
    /// No clock is needed for "a settle later": every event-prompted look comes a full settle after
    /// the last event, so the second one to see the same rename is at least that far from the first.
    private func renameHasSettled(to destination: String, from path: String) -> Bool {
        if pendingRename == destination { return true }
        pendingRename = destination
        Logger.shared.info("[edit] \(path) was renamed to “\((destination as NSString).lastPathComponent)” — looking once more before following it, in case a save is putting a new file in its place")
        eventArrived()
        return false
    }

    /// Whether two paths are in one folder, however each spells it.
    nonisolated static func isInSameFolder(_ a: String, _ b: String) -> Bool {
        EditorFileStore.resolved((a as NSString).deletingLastPathComponent)
            == EditorFileStore.resolved((b as NSString).deletingLastPathComponent)
    }

    /// Whether a rename within the folder is waiting for its second look — for the tests.
    var isConfirmingRename: Bool { pendingRename != nil }

    /// The look an event prompts, taken now rather than a settle later — for the tests that put the
    /// file system's own steps between two such looks, which a clock under load cannot promise.
    @discardableResult
    func lookAsAnEventWould() -> Outcome { look(confirmingRenames: true) }

    /// Whether the watcher is on the wrong thing for what the path holds now: a different file (an
    /// atomic save installed a new inode), or a folder above one that has come back.
    private func needsRearm(_ observation: EditorDiskChange.Observation) -> Bool {
        (observation.atPath?.fileID ?? 0) != (watcher?.fileID ?? 0) || watcher?.watchesAboveAFolderThatIsBack == true
    }

    /// What Save Again's look found — see ``prepareSaveAgain()``.
    public enum SaveAgainCheck: Equatable, Sendable {
        /// Nothing is at the path: write.
        case write
        /// Something is at the path again; nothing is written, and the banner now says what.
        case notMissing
        /// The folder was gone too, and could not be made again — the reason, for the host to show.
        case failed(String)
    }

    /// **Save Again looks before it writes.** It is a write that skips the save-time divergence
    /// check — the file is gone, so there is nothing to diverge from — and a file can be back at the
    /// path by the time it is pressed (a restore, another device) without the watch having heard it
    /// yet. Writing then would replace that file unasked. So it writes only while the path is still
    /// empty; anything there is looked at instead, and the banner changes to say what it found.
    public func prepareSaveAgain() -> SaveAgainCheck {
        guard let document, let path = document.path else { return .notMissing }
        let missing = document.diskStamp.map { EditorFileStore.divergence(atPath: path, from: $0) == .missing }
            ?? (EditorFileStore.stamp(ofPath: path) == nil)
        guard missing else {
            Logger.shared.info("[edit] Save Again found something at \(path) again — not writing over it, looking at it instead")
            reconcile()
            return .notMissing
        }
        // **The folder went with it** — deleted, or the file's whole folder moved or put in the
        // Trash. The write stages its bytes beside the file, so with no folder it cannot happen at
        // all, and Close, which discards the only copy, would be the one answer left. Save Again
        // means "put it back where it was", so the folder is put back too, and the log says so.
        let folder = (path as NSString).deletingLastPathComponent
        var isFolder: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                Logger.shared.info("[edit] Save Again made the folder \(folder) again — it was gone with \(document.name) — to write it back")
            } catch {
                Logger.shared.warning("[edit] Save Again could not make the folder \(folder) again: \(error.localizedDescription)")
                return .failed("its folder “\((folder as NSString).lastPathComponent)” is gone and couldn’t be made again (\(error.localizedDescription))")
            }
        }
        return .write
    }

    /// What one look did — for the host, which reacts to a few of them, and for the tests.
    public enum Outcome: Equatable {
        case nothing
        case settled
        case reloaded
        case asked(EditorDiskBanner)
        case followed(String)
        /// The newer version is still in the cloud; it is being fetched, and looked at again after.
        case downloading
        /// The file has a new stamp and the same contents; the document took the stamp, and nothing
        /// else moved — not the buffer, not the history.
        case restamped
        /// The newer file cannot be read as text; the last text stays on screen, read-only, and the
        /// watch goes on looking.
        case unreadable
    }

    /// The stamp to take when `opened` is the text the document already has as saved — in the same
    /// encoding, so a file re-saved as UTF-16 with identical text is still a change (the next save
    /// would otherwise write it back as UTF-8). `nil` when it is not.
    static func sameContentStamp(_ opened: EditorFileStore.Opened, as document: EditorDocument) -> EditorFileStore.Stamp? {
        switch opened {
        case .editable(let text, let stamp, let encoding):
            guard !document.isReadOnly, encoding == document.encoding,
                  EditorSourceStorage.sameBytes(text, document.savedText) else { return nil }
            return stamp
        case .readOnly(let text, _, let stamp):
            guard document.isReadOnly, let stamp, EditorSourceStorage.sameBytes(text, document.savedText) else { return nil }
            return stamp
        case .refused:
            return nil
        }
    }

    private func observe(_ path: String) -> EditorDiskChange.Observation {
        let resolved = EditorFileStore.resolved(path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        return EditorDiskChange.Observation(
            atPath: attributes == nil ? nil : EditorFileStore.stamp(ofPath: path),
            isRegularFile: (attributes?[.type] as? FileAttributeType) == .typeRegular,
            trackedPath: watcher?.trackedPath)
    }

    /// Typing that is not on disk — the buffer differs from what was saved, or an input method is
    /// part-way through a word, which the buffer does not hold yet and a reload would end.
    private func hasUnsavedTyping(_ document: EditorDocument) -> Bool {
        if document.isDirty { return true }
        let source = document.buffer.source
        guard let view = source.textView, view.textStorage === source.textStorage else { return false }
        return view.hasMarkedText()
    }

    // MARK: Acting

    func reloadQuietly(_ path: String, opened: EditorFileStore.Opened?) -> Outcome {
        guard let document else { return .nothing }
        guard let opened, !isCloudOnly(path) else {
            download(path)
            return .downloading
        }
        // Another writer is part-way through its save. Look again once it has settled, rather than
        // putting a refusal where the text was.
        if opened == .refused(reason: EditorFileStore.keptChangingReason) {
            Logger.shared.info("[edit] \(path) kept changing while it was read — looking again once it settles")
            eventArrived()
            return .nothing
        }
        if case .refused(let reason) = opened {
            return keepTextOverUnreadable(document, path: path, reason: reason)
        }
        // Both stamps, so a reload that should not have happened can be told apart afterwards.
        let was = Self.describe(document.diskStamp)
        Self.reload(document, with: opened, undoManager: undoStore?.current)
        Logger.shared.info("[edit] Reloaded \(path) — it changed elsewhere (was \(was); now \(Self.describe(document.diskStamp))), and nothing typed was unsaved")
        setBanner(nil)
        showNotice(Self.reloadedNotice)
        return .reloaded
    }

    /// **The newer file cannot be read as text** — it became binary, grew past the read cap, or
    /// cannot be opened just now. Reloading into that refusal would empty the screen of text that is
    /// still correct as far as anybody knows, call it "Reloaded", and — a refusal being where the
    /// watch stops — never look again.
    ///
    /// So the text stays, **read-only** (the reason on screen says why), because saving it would
    /// write the last version over a file it no longer describes. The document is left with no disk
    /// stamp, so any file at the path reads as a change: every later look tries again, and the first
    /// one that can read text reloads it and opens it for editing. The history goes, as on any reload
    /// — the file it was measured against is gone.
    private func keepTextOverUnreadable(_ document: EditorDocument, path: String, reason: String) -> Outcome {
        let readOnlyReason = Self.unreadableReason(reason)
        // Already showing this — another event about the same unreadable file.
        guard document.readOnlyReason != readOnlyReason else { return .nothing }
        document.reload(.readOnly(text: document.text, reason: readOnlyReason, stamp: nil))
        undoStore?.current.removeAllActions()
        Logger.shared.info("[edit] \(path) changed elsewhere into something that can't be read as text (\(reason)) — keeping the last text on screen, read-only, until it can be read")
        setBanner(nil)
        showNotice(Self.unreadableNotice)
        return .unreadable
    }

    /// **The quiet reload itself**, separate so a test can run it on a document and a stack.
    ///
    /// The text goes into the shared storage as the smallest edit (``EditorSourceStorage/takeDiskText(_:)``),
    /// then the document takes the stamp, the encoding and the saved text the read produced — the
    /// same `Opened` an open would get (the watch never hands it a refusal — see
    /// ``keepTextOverUnreadable(_:path:reason:)``). Then the history is emptied: an undo registered against
    /// the text before the reload names ranges in text that is gone.
    static func reload(_ document: EditorDocument, with opened: EditorFileStore.Opened, undoManager: UndoManager?) {
        switch opened {
        case .editable(let text, _, _), .readOnly(let text, _, _):
            document.buffer.source.takeDiskText(text)
        case .refused:
            break
        }
        document.reload(opened)
        undoManager?.removeAllActions()
    }

    /// The newer version is a cloud placeholder: ask for it, and look again when it lands — or once
    /// ``downloadPatience`` has passed, whichever comes first.
    ///
    /// **iCloud is asked through its own API** (``MaterializationStatus/download(atPath:)``), which
    /// hands the request to the daemon and returns at once; nothing is read, and the landing is
    /// noticed by a cheap `lstat` every ``downloadPoll`` (materialising a file sends no event).
    ///
    /// **Any other provider has no such API**, and the only way to ask it is to read a byte — which
    /// waits on the provider, and a provider that is not running (OneDrive, 2026-10-02) makes it
    /// wait forever. So the read runs on a queue of its own, never the shared pool autosave's write
    /// needs, and **the download stays out until that read returns**: the patience runs out into a
    /// look, not into a second read. At most one read per path is ever blocked, and since the queue
    /// is serial, at most one thread in all.
    private func download(_ path: String) {
        guard downloading != path else { return }
        let now = ContinuousClock.now
        if let last = lastDownload, last.path == path, now - last.at < downloadPatience { return }
        lastDownload = (path, now)
        downloading = path
        Logger.shared.info("[edit] \(path) changed elsewhere and the new version is still in the cloud — downloading it")
        showNotice("Changed elsewhere — downloading the new version")
        do {
            try startDownload(path)
        } catch {
            readToDownload(path)
        }
        let patience = downloadPatience, poll = downloadPoll
        Task { [weak self] in
            let deadline = ContinuousClock.now + patience
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: min(poll, deadline - ContinuousClock.now))
                guard let self, self.downloading == path else { return }
                if !self.isCloudOnly(path) { break }
            }
            guard let self, self.downloading == path else { return }
            // The provider has not answered the read yet: the download stays out — the read's
            // return ends it, not the clock.
            if self.readsOut.contains(path), self.isCloudOnly(path) {
                Logger.shared.info("[edit] The new version of \(path) has not arrived after \(patience) — still waiting on its provider")
                return
            }
            self.downloadEnded(path)
        }
    }

    /// Asks a provider with no download API for the file, by reading a byte of it — once per path,
    /// on ``downloadQueue``.
    private func readToDownload(_ path: String) {
        guard !readsOut.contains(path) else { return }
        readsOut.insert(path)
        let read = readFirstByte
        Self.downloadQueue.async { [weak self] in
            read(path)
            Task { @MainActor [weak self] in
                self?.readsOut.remove(path)
                self?.downloadEnded(path)
            }
        }
    }

    private func downloadEnded(_ path: String) {
        guard downloading == path else { return }
        downloading = nil
        reconcile()
        // Use Disk Version was pressed while the version was in the cloud: take it now it is here.
        if useDisksWhenDownloaded == path, document?.path == path, banner == .changed, !isCloudOnly(path) {
            useDisksWhenDownloaded = nil
            if useDisksVersion() == .unreadable {
                Logger.shared.info("[edit] The version of \(path) on disk arrived and cannot be read as text — the typing stays")
            }
        }
    }

    private func follow(from old: String, to new: String, byThisApp: Bool) {
        guard let document else { return }
        isFollowing = true
        document.retarget(to: new)
        isFollowing = false
        undoStore?.move(from: old, to: new)
        document.caretAnchors.move(from: old, to: new)
        Logger.shared.info(byThisApp
            ? "[edit] \(old) was moved or renamed by this app — following it to \(new)"
            : "[edit] \(old) was moved or renamed elsewhere — following it to \(new)")
        onMoved?(old, new, byThisApp)
        showNotice(Self.followedNotice(from: old, to: new))
    }

    /// What a press on "Use Disk Version" came to.
    public enum UseDisksOutcome: Equatable, Sendable {
        /// The buffer is the version on disk now.
        case used
        /// The version on disk is still in the cloud; it is being fetched, and taken when it lands.
        case downloading
        /// The file cannot be read as editable text any more — nothing changed, and the host says why.
        case unreadable
    }

    /// **"Use Disk Version"**: the buffer becomes the file's version as ONE step ⌘Z takes back, so the
    /// typing can come back. A version still in the cloud is fetched first and taken when it lands
    /// (``UseDisksOutcome/downloading``); one that cannot be read as editable text changes nothing,
    /// and the banner stays.
    @discardableResult
    public func useDisksVersion() -> UseDisksOutcome {
        guard let document, let path = document.path else { return .unreadable }
        if isCloudOnly(path) {
            useDisksWhenDownloaded = path
            lastDownload = nil      // asked for by a press, not by a look: never held back
            download(path)
            Logger.shared.info("[edit] Use Disk Version for \(path) waits for the version on disk to download")
            return .downloading
        }
        guard case .editable(let text, let stamp, let encoding) = EditorFileStore.open(path: path) else {
            return .unreadable
        }
        let mine = document.diskRecord
        let changesText = !EditorSourceStorage.sameBytes(document.text, text)
        let undoManager = undoStore?.current
        document.buffer.source.replaceAll(with: text, undoManager: undoManager,
                                          actionName: Self.useDisksActionName)
        document.adoptDisk(text: text, stamp: stamp, encoding: encoding)
        // **In the same undo group as the text**, so the ⌘Z that brings the typing back brings the
        // question back with it — see ``takeBackUseDisks(restoring:redo:undoManager:)``.
        if changesText, let undoManager {
            registerTakeBack(restoring: mine, redo: document.diskRecord, undoManager: undoManager)
        }
        Logger.shared.info("[edit] Took the version of \(path) on disk over the unsaved typing — ⌘Z brings the typing back")
        setBanner(nil)
        showNotice(Self.usedDisksNotice)
        return .used
    }

    /// **⌘Z of "Use Disk Version" puts the question back, not only the typing.** The other version is
    /// still on disk, so the typing must not reach it without Keep Mine's consent — and with only
    /// the text undone, the document recorded the disk's version as saved, the banner was gone and
    /// the host's autosave stop with it: the next autosave wrote the typing over the other version
    /// without a word. So the document's record of the disk goes back to what it was before (the
    /// next look finds the disk changed under the typing again, and autosave's own check refuses
    /// it), and the banner — and through ``onBannerChange`` the stop — comes back. ⌘⇧Z takes the
    /// disk's version again, record and all.
    private func registerTakeBack(restoring mine: EditorDocument.DiskRecord, redo disks: EditorDocument.DiskRecord,
                                  undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { [weak undoManager] watch in
            guard let undoManager else { return }
            watch.takeBackUseDisks(restoring: mine, redo: disks, undoManager: undoManager)
        }
    }

    private func takeBackUseDisks(restoring mine: EditorDocument.DiskRecord, redo disks: EditorDocument.DiskRecord,
                                  undoManager: UndoManager) {
        // The stack is the file's own (``EditorUndoStore``), so it is only ever replayed with that
        // file open; a stack that is no longer the current one has nothing on screen to act on.
        guard let document, let path = document.path, undoStore?.current === undoManager else { return }
        document.restore(mine)
        Logger.shared.info("[edit] Took back Use Disk Version for \(path) — the typing is back, and so is the question: the other version is still on disk")
        setBanner(.changed)
        undoManager.registerUndo(withTarget: self) { [weak undoManager] watch in
            guard let undoManager else { return }
            watch.retakeUseDisks(restoring: disks, undo: mine, undoManager: undoManager)
        }
    }

    private func retakeUseDisks(restoring disks: EditorDocument.DiskRecord, undo mine: EditorDocument.DiskRecord,
                                undoManager: UndoManager) {
        guard let document, let path = document.path, undoStore?.current === undoManager else { return }
        document.restore(disks)
        Logger.shared.info("[edit] Took the version of \(path) on disk again (Redo)")
        setBanner(nil)
        registerTakeBack(restoring: mine, redo: disks, undoManager: undoManager)
    }

    // MARK: Words

    static let reloadedNotice = "Reloaded — changed elsewhere"

    /// A stamp in the log's words — its size, when it was modified (to the millisecond, in UTC) and
    /// its inode, so an atomic save reads as one.
    static func describe(_ stamp: EditorFileStore.Stamp?) -> String {
        guard let stamp else { return "no stamp" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let modified = stamp.modifiedAt.map { formatter.string(from: $0) } ?? "an unknown time"
        return "\(stamp.size) bytes, modified \(modified), inode \(stamp.fileID)"
    }
    static let unreadableNotice = "Changed elsewhere — can’t be read as text now"
    /// How the read-only reason over a kept text begins — the rest is the read's own refusal.
    static let unreadableReasonLead = "The file on disk changed and can’t be read as text now"

    static func unreadableReason(_ refusal: String) -> String {
        // A full stop, not a dash: the refusal is a sentence of its own, and Edit's too-large one
        // carries a dash already (TE103).
        "\(unreadableReasonLead). \(refusal) This is the last text that could be read, open for "
            + "reading only until the file can be read again."
    }
    static let usedDisksNotice = "Using the version on disk — ⌘Z brings your version back"
    /// An edit turned a CRLF or CR file into LF (TE104) — the first change to it, which ⌘Z takes
    /// back with the conversion (``EditorLineEndings``).
    static let convertedToLFNotice = "Converted to LF line endings — ⌘Z undoes"
    /// Edit ▸ Undo's word for Use Disk Version — the button's own (TE97).
    static let useDisksActionName = EditorDiskVerbs.useDiskVersion

    static func followedNotice(from old: String, to new: String) -> String {
        let oldFolder = (old as NSString).deletingLastPathComponent
        let newFolder = (new as NSString).deletingLastPathComponent
        if EditorFileStore.resolved(oldFolder) == EditorFileStore.resolved(newFolder) {
            return "Renamed elsewhere — now “\((new as NSString).lastPathComponent)”"
        }
        return "Moved elsewhere — now in “\((newFolder as NSString).lastPathComponent)”"
    }

    /// **Heard as well as seen**: what the watch did or asks is announced to VoiceOver, as the
    /// workspace's own status hints are. A seam, so a test can hear it.
    var announce: (String) -> Void = { text in
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app.mainWindow ?? app, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// **What an image import saved, in the status line's notice** (TE182) — through this watch,
    /// because this is where the line's few seconds of words live: a newer notice replaces an
    /// older one, the disk's or the import's, rather than two competing for the slot.
    public func noteImagesImported(_ report: EditorImageImport.Report) {
        if let text = EditorImageImport.notice(for: report) { showNotice(text) }
    }

    private func showNotice(_ text: String) {
        announce(text)
        noticeToken &+= 1
        let token = noticeToken
        notice = Notice(text: text, token: token)
        let duration = noticeDuration
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            if self?.notice?.token == token { self?.notice = nil }
        }
    }

    private func setBanner(_ next: EditorDiskBanner?) {
        if next == nil { useDisksWhenDownloaded = nil }
        guard banner != next else { return }
        banner = next
        onBannerChange?(next)
        if let next, let name = document?.name { announce(next.message(name: name)) }
    }
}
