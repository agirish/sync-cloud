import Foundation
import Events

/// Writing the open document without being asked to.
///
/// **The decision, separated from the timer and the alerts.** The host owns when to attempt a save
/// (a debounce on the buffer's version counter, plus a flush at every point the document is about
/// to leave the screen) and owns the modal; what belongs here is the part with rules in it — when
/// a write is allowed at all, and what stops one. That half is pure over a document and a real
/// directory, so every branch below is reachable from a test without a view or a timer.
public enum EditorAutosave {

    /// How long the typing has to settle before a write is attempted.
    ///
    /// **Two seconds, and the number is a compromise rather than a default.** Shorter turns an
    /// ordinary paragraph into a dozen writes, and these are real cloud folders — every write is an
    /// upload, a version in somebody's history, and a chance for a sync client to produce a conflict
    /// copy. Longer is more work at risk when something goes wrong. Two seconds is about the length
    /// of a pause for thought, which is the moment a save is least likely to be noticed.
    ///
    /// The debounce is not the only thing that writes: every route out of the document flushes
    /// synchronously, so the window this number leaves open is only ever "typing, then a crash".
    public static let quietInterval = Duration.milliseconds(2000)

    /// What the debounce is keyed on.
    ///
    /// **The path is in here as well as the version, and that is not belt-and-braces.** Two
    /// documents can sit at the same version — a file opened at version 0 moments after another was
    /// closed at version 0 — and `.task(id:)` only restarts when the id CHANGES, so a key that
    /// could not tell them apart would leave a pending write aimed at a file that is no longer
    /// open. Keyed on the counter rather than on the text for the reason
    /// ``EditorDocument/textVersion`` exists at all.
    ///
    /// **And the stamp, so a write that commits re-arms the wait** (FR51). The host writes one
    /// snapshot at a time and turns the debounce away while one is out; typing that paused while a
    /// slow write was still out — an iCloud volume, an external disk — had its debounce fire into
    /// that refusal, and with the version and the path unchanged nothing restarted it: the rest sat
    /// unsaved, the dot lit, until the next keystroke or a flush. Every commit moves the stamp, so
    /// the wait starts again; a document the commit left clean schedules nothing, and one still
    /// dirty is written a quiet interval later.
    public struct Key: Equatable, Sendable {
        public var version: Int
        public var path: String?
        public var stamp: EditorFileStore.Stamp?
        public init(version: Int, path: String?, stamp: EditorFileStore.Stamp? = nil) {
            self.version = version
            self.path = path
            self.stamp = stamp
        }
    }

    /// What an attempt did, in terms the host can log and act on.
    public enum Outcome: Equatable, Sendable {
        /// Nothing to write — no document, nothing changed, or a document that cannot be saved.
        case nothingToDo
        /// Written, and the document's stamp has moved with it.
        case wrote
        /// **Refused, because the file moved under the buffer.** Autosave stops here rather than
        /// resolving it: overwriting would discard whatever arrived from another device, and for a
        /// file an Organize run has moved it would recreate it at the old path — two copies, which
        /// is the failure ``EditorFileStore/Divergence/missing`` exists to prevent.
        case blocked(EditorFileStore.Divergence)
        /// The write itself failed; the message is already reader-facing.
        case failed(String)
        /// **The bytes are on disk, and the look afterwards failed** (TE114) — the stat that stamps
        /// the write read nothing, or read another file. The clause follows "Saved “name”, but …".
        /// Not marked saved: there is no stamp to hold, so the host stops autosave rather than write
        /// again blind.
        case savedUnchecked(String)

        /// What a write that threw comes to — a landed write's own outcome where the store says so.
        static func of(_ error: Error) -> Outcome {
            if let clause = (error as? EditorFileStore.Failure)?.savedBut { return .savedUnchecked(clause) }
            return .failed(error.localizedDescription)
        }
    }

    /// Attempts one write, **synchronously and on the main actor**.
    ///
    /// **Never resolves a divergence, and never asks.** A background write that could answer "the
    /// file changed underneath you" by picking a side would be the one place in this app that makes
    /// that choice for somebody. It reports, and the host decides what to put on screen.
    ///
    /// **This is the path for the moments a document is LEAVING** — ⌘S, the flush before another
    /// file is opened, the flush at ⌘Q — where the write has to have finished before the next line
    /// of code runs, and where blocking the main actor for a few milliseconds is the correct trade.
    /// The debounce uses ``write(_:into:)`` instead; see ``Snapshot`` for why.
    @MainActor
    public static func attempt(_ document: EditorDocument) -> Outcome {
        guard document.canSave, let path = document.path, let stamp = document.stamp else {
            return .nothingToDo
        }
        if let divergence = EditorFileStore.divergence(atPath: path, from: stamp) {
            // **The file may be newer only because autosave's own write is out** (FR50) — see
            // ``settleLandedWrite(into:waitingUpTo:)``. Settled, it is compared again against the
            // stamp that write left; whatever was typed since the snapshot is written by this attempt.
            guard settleLandedWrite(into: document), let settled = document.stamp else {
                return .blocked(divergence)
            }
            guard document.canSave else { return .wrote }
            if let divergence = EditorFileStore.divergence(atPath: path, from: settled) {
                return .blocked(divergence)
            }
        }
        do {
            document.markSaved(stamp: try EditorFileStore.write(document))
            return .wrote
        } catch {
            return .of(error)
        }
    }

    // MARK: - The debounce's write, which does not run on the main actor

    /// Everything a write needs, taken from the document at the moment the write is dispatched.
    ///
    /// **A snapshot, because the buffer does not hold still while the disk is being written to.**
    /// The write is a divergence `stat` (with a symlink resolve), an `attributesOfItem`, an O(n)
    /// encode, a `Data.write`, an `F_FULLFSYNC` — tens of milliseconds on an internal SSD and
    /// considerably more on an external or iCloud volume — a `replaceItem`, a `removeItem` and a
    /// re-`stat`. All of it used to happen on the main actor, two seconds after the typing paused,
    /// which is very often the moment the typing resumes.
    ///
    /// Carrying the text rather than the document is what makes the move safe. A keystroke landing
    /// while those bytes are in flight is *not* what went to disk, so the document is marked saved
    /// against ``text`` — see ``EditorDocument/markSaved(text:stamp:)`` — and correctly stays dirty
    /// for the rest.
    public struct Snapshot: Sendable {
        public var text: String
        /// The buffer's version when the snapshot was taken. Kept for the log and for tests: the
        /// commit is decided by the path and the stamp, which is what can actually change.
        public var version: Int
        public var path: String
        public var stamp: EditorFileStore.Stamp
        /// The store's ordering ticket — see `EditorFileStore.issueWriteTicket()`.
        var ticket: UInt64
        var encoding: BoundedTextRead.TextEncoding
    }

    /// What the document must be for a background write to be worth dispatching, or `nil` when
    /// there is nothing to do.
    ///
    /// Asks exactly the questions ``attempt(_:)`` asks before it writes; the divergence check is
    /// not among them, because that is a `stat` and stat'ing an iCloud path is one of the things
    /// being moved off the main actor.
    @MainActor
    public static func snapshot(of document: EditorDocument) -> Snapshot? {
        guard document.canSave, let path = document.path, let stamp = document.stamp,
              let encoding = document.encoding else { return nil }
        return Snapshot(text: document.text, version: document.textVersion, path: path,
                        stamp: stamp, ticket: EditorFileStore.issueWriteTicket(),
                        encoding: encoding)
    }

    /// Writes a snapshot off the main actor and commits the result back onto it.
    ///
    /// **The commit is guarded on the document still being the one that was snapshotted.** While
    /// the bytes were in flight the user can have opened another file, and a ⌘S or a quit flush can
    /// have written the newer buffer already — in which case this result describes a file that has
    /// since moved on, and acting on it would either mark the wrong text saved or raise a
    /// divergence alert about a change this app made itself a moment ago. Both are answered the
    /// same way: the result is dropped, and the document is left exactly as the newer write left
    /// it. `EditorFileStore`'s write order guarantees the older bytes were never written in that
    /// case, so there is nothing to undo.
    ///
    /// **Counted on the document while it is out** (``EditorDocument/backgroundWrites``), so the disk
    /// watch does not read the file this write installed — newer than the document's stamp until
    /// the commit below — as a change made elsewhere (TE59). Begun before the bytes leave, ended
    /// after the commit, both on the main actor where the watch runs.
    @MainActor
    public static func write(_ snapshot: Snapshot, into document: EditorDocument) async -> Outcome {
        document.beginBackgroundWrite()
        defer { document.endBackgroundWrite() }
        let landings = document.landings
        landings.dispatched()
        let result = await Task.detached(priority: .utility) { () -> Result in
            // Told on every way out, so a settle waiting for this write never waits past it.
            var landed: Landing?
            defer { landings.finished(landed) }
            if let divergence = EditorFileStore.divergence(atPath: snapshot.path,
                                                           from: snapshot.stamp) {
                return .blocked(divergence)
            }
            do {
                guard let stamp = try EditorFileStore.write(snapshot.text, toPath: snapshot.path,
                                                            encoding: snapshot.encoding,
                                                            ticket: snapshot.ticket,
                                                            expected: snapshot.stamp) else {
                    return .overtaken
                }
                landed = Landing(ticket: snapshot.ticket, path: snapshot.path, from: snapshot.stamp,
                                 text: snapshot.text, stamp: stamp)
                return .wrote(stamp)
            } catch {
                return .ended(.of(error))
            }
        }.value
        // The commit is this write's word on it from here — unless a settle took it first, in which
        // case the stamp has moved and the guard below drops the result.
        _ = landings.take(ticket: snapshot.ticket)

        // The document moved on while the write was out: whatever this says is about a state that
        // is no longer the one on screen.
        guard document.path == snapshot.path, document.stamp == snapshot.stamp else {
            return .nothingToDo
        }
        switch result {
        case .overtaken:
            return .nothingToDo
        case .wrote(let stamp):
            document.markSaved(text: snapshot.text, stamp: stamp)
            return .wrote
        case .blocked(let divergence):
            return .blocked(divergence)
        case .ended(let outcome):
            // Landed, unchecked: remembered, so the disk can be compared with it later (TE147).
            if case .savedUnchecked = outcome { document.noteUncheckedWrite(snapshot.text) }
            return outcome
        }
    }

    /// What the detached half answers, including the one case ``Outcome`` has no word for: a write
    /// that was overtaken by a newer one and therefore never happened.
    private enum Result: Sendable {
        case wrote(EditorFileStore.Stamp)
        case overtaken
        case blocked(EditorFileStore.Divergence)
        /// A write that threw — failed, or landed and could not be checked.
        case ended(Outcome)
    }

    // MARK: - A synchronous save meeting a background one (FR50)

    /// What a background write put on disk, known off the main actor before its commit is.
    struct Landing: Sendable {
        var ticket: UInt64
        var path: String
        /// The document's stamp the write was made against — what the commit guards on.
        var from: EditorFileStore.Stamp
        var text: String
        var stamp: EditorFileStore.Stamp
    }

    /// **Where a background write leaves word of what it installed, the moment it has** — kept on
    /// the document (``EditorDocument/landings``) and locked, because it is written off the main
    /// actor while the main actor may be waiting on it. See ``settleLandedWrite(into:waitingUpTo:)``.
    final class Landings: @unchecked Sendable {
        private let condition = NSCondition()
        private var outstanding = 0
        private var landed: Landing?

        /// A write is leaving — told on the main actor, before the bytes go.
        func dispatched() {
            condition.lock(); defer { condition.unlock() }
            outstanding += 1
        }

        /// The write is done with the disk, with what it installed when it installed something.
        func finished(_ landing: Landing?) {
            condition.lock(); defer { condition.unlock() }
            outstanding = max(0, outstanding - 1)
            if let landing { landed = landing }
            condition.broadcast()
        }

        /// Waits until no write is out on the disk; `false` when `limit` ran out first.
        func waitUntilNoneOut(upTo limit: Duration) -> Bool {
            let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
            let deadline = Date().addingTimeInterval(seconds)
            condition.lock(); defer { condition.unlock() }
            while outstanding > 0 {
                if !condition.wait(until: deadline) { return outstanding == 0 }
            }
            return true
        }

        /// Takes the word of the last write that landed — only `ticket`'s, when one is named.
        func take(ticket: UInt64? = nil) -> Landing? {
            condition.lock(); defer { condition.unlock() }
            guard let landed, ticket == nil || landed.ticket == ticket else { return nil }
            self.landed = nil
            return landed
        }
    }

    /// **Commits a background write that has landed but whose commit has not reached the main actor
    /// yet** — now, on the main actor, exactly as that commit would (FR50).
    ///
    /// Between the swap that installs autosave's bytes and the hop back that marks them saved, the
    /// file on disk is newer than the document's stamp — and it is the editor's own. The disk watch
    /// already waits out that window (``EditorDocument/backgroundWrites``); a synchronous save did
    /// not. ⌘S, the flush before another file opens and the flush at ⌘Q compared the disk with the
    /// old stamp, found "changed on disk", and asked — and Use Disk Version or Don't Save then threw
    /// away what was typed after the snapshot, and its undo history with it, over a change the app
    /// had made itself a moment before.
    ///
    /// So a synchronous save that finds the file diverged while a write is out **waits for that
    /// write to be done with the disk** — the swap has usually happened already, so what is left is
    /// a stat and a delete — and takes what it installed as saved, against the snapshot's text. The
    /// buffer is then compared with the stamp that write left, and anything typed since is still
    /// dirty for the caller to write. The commit, when it arrives, finds the stamp moved and drops
    /// its result, as it does after any newer save. A write that found a real change, failed, or was
    /// overtaken leaves no word, and the caller asks about the divergence as before.
    ///
    /// - Parameter limit: how long the main actor may wait — a ceiling for a volume that has stopped
    ///   answering, after which the divergence is asked about as it always was.
    /// - Returns: whether a landed write was committed.
    @MainActor
    @discardableResult
    public static func settleLandedWrite(into document: EditorDocument,
                                         waitingUpTo limit: Duration = .seconds(10)) -> Bool {
        guard document.backgroundWrites > 0 else { return false }
        guard document.landings.waitUntilNoneOut(upTo: limit) else {
            Logger.shared.warning("[edit] \(document.path ?? "") — autosave's write was still out after \(limit); asking about the file as it stands")
            return false
        }
        guard let landing = document.landings.take(),
              document.path == landing.path, document.stamp == landing.from else { return false }
        document.markSaved(text: landing.text, stamp: landing.stamp)
        return true
    }
}
