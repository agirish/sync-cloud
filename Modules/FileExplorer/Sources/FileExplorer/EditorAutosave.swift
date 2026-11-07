import Foundation
import Events

/// Writing the open document without being asked to.
///
/// The decision, separate from the timer and the alerts. The host owns when to attempt a save (a
/// debounce on the buffer's version counter, plus a flush whenever the document is about to leave
/// the screen) and owns the modal; this holds the rules: when a write is allowed, and what stops
/// one. It is pure over a document and a real directory, so every branch is reachable from a test.
public enum EditorAutosave {

    /// How long the typing has to settle before a write is attempted.
    ///
    /// Two seconds, as a compromise: shorter turns a paragraph into a dozen writes, and in a cloud
    /// folder every write is an upload, a version in someone's history and a chance for a conflict
    /// copy; longer leaves more work at risk. Every route out of the document flushes
    /// synchronously, so the window this leaves open is only "typing, then a crash".
    public static let quietInterval = Duration.milliseconds(2000)

    /// What the debounce is keyed on.
    ///
    /// The path as well as the version, because two documents can sit at the same version (one
    /// opened at 0 just after another closed at 0), and `.task(id:)` restarts only when the id
    /// changes, so a pending write could aim at a file no longer open. The counter, not the text,
    /// for the reason ``EditorDocument/textVersion`` exists.
    ///
    /// And the stamp, so a write that commits re-arms the wait. The host writes one snapshot at a
    /// time and turns the debounce away while one is out; without the stamp, typing that paused
    /// during a slow write (an iCloud volume, an external disk) would have its debounce fire into
    /// that refusal and never restart, leaving the rest unsaved until the next keystroke or flush.
    /// A document the commit left clean schedules nothing; one still dirty is written a quiet
    /// interval later.
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
        /// Nothing to write: no document, nothing changed, or a document that can't be saved.
        case nothingToDo
        /// Written, and the document's stamp has moved with it.
        case wrote
        /// Refused, because the file moved under the buffer. Autosave stops rather than resolve it:
        /// overwriting would discard what arrived from another device, and for a file Organize
        /// moved it would recreate it at the old path, two copies, which
        /// ``EditorFileStore/Divergence/missing`` exists to prevent.
        case blocked(EditorFileStore.Divergence)
        /// The write itself failed; the message is already reader-facing.
        case failed(String)
        /// The bytes are on disk, but the stat that stamps the write read nothing, or another file.
        /// The clause follows "Saved “name”, but …". Not marked saved: with no stamp to hold, the
        /// host stops autosave rather than write again blind.
        case savedUnchecked(String)
        /// Written and checked, and a different version the save displaced was kept beside it. A
        /// save, so the document is marked saved and nothing stops. The clause follows "Saved
        /// “name”, but …" and says where the other version went.
        case wroteKeepingAside(String)

        /// What a write that threw comes to, or a landed write's own outcome where the store says
        /// so.
        static func of(_ error: Error) -> Outcome {
            if let failure = error as? EditorFileStore.Failure, let clause = failure.savedBut {
                return failure.landed != nil ? .wroteKeepingAside(clause) : .savedUnchecked(clause)
            }
            return .failed(error.localizedDescription)
        }
    }

    /// Attempts one write, synchronously and on the main actor.
    ///
    /// **Never** resolves a divergence or asks: a background write that picked a side when the file
    /// changed underneath would make that choice for somebody. It reports; the host decides.
    ///
    /// The path for moments a document is leaving (⌘S, the flush before another file opens, the
    /// flush at ⌘Q), where the write must finish before the next line runs and blocking the main
    /// actor for a few milliseconds is the right trade. The debounce uses ``write(_:into:)``; see
    /// ``Snapshot``.
    @MainActor
    public static func attempt(_ document: EditorDocument) -> Outcome {
        guard document.canSave, let path = document.path, let stamp = document.stamp else {
            return .nothingToDo
        }
        if let divergence = EditorFileStore.divergence(atPath: path, from: stamp) {
            // The file may be newer only because autosave's own write is out; see
            // ``settleLandedWrite(into:waitingUpTo:)``. Settled, it is compared again against the
            // stamp that write left, and whatever was typed since the snapshot is written by this
            // attempt.
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

    /// Everything a write needs, taken from the document when the write is dispatched.
    ///
    /// A snapshot, because the buffer doesn't hold still while the disk is written. The write is a
    /// divergence `stat` (with a symlink resolve), an `attributesOfItem`, an O(n) encode, a
    /// `Data.write`, an `F_FULLFSYNC` (tens of milliseconds on an internal SSD, far more on an
    /// external or iCloud volume), a `replaceItem`, a `removeItem` and a re-`stat`: too much for
    /// the main actor two seconds after typing paused, often the moment it resumes.
    ///
    /// Carrying the text, not the document, makes that safe: a keystroke landing while the bytes
    /// are in flight isn't what went to disk, so the document is marked saved against ``text`` (see
    /// ``EditorDocument/markSaved(text:stamp:)``) and stays dirty for the rest.
    public struct Snapshot: Sendable {
        public var text: String
        /// The buffer's version when the snapshot was taken, for the log and tests; the commit is
        /// decided by the path and the stamp.
        public var version: Int
        public var path: String
        public var stamp: EditorFileStore.Stamp
        /// The store's ordering ticket; see `EditorFileStore.issueWriteTicket()`.
        var ticket: UInt64
        var encoding: BoundedTextRead.TextEncoding
    }

    /// What the document must be for a background write to be worth dispatching, or `nil` when
    /// there is nothing to do.
    ///
    /// Asks exactly what ``attempt(_:)`` asks before it writes, except the divergence check: that
    /// is a `stat`, and stat'ing an iCloud path is part of what is moved off the main actor.
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
    /// The commit is guarded on the document still being the one snapshotted. While the bytes were
    /// in flight the user may have opened another file, or a ⌘S or quit flush may have written the
    /// newer buffer; acting on this result would then mark the wrong text saved or raise a
    /// divergence alert about the app's own change. Either way the result is dropped and the
    /// document left as the newer write left it. `EditorFileStore`'s write order guarantees the
    /// older bytes were never written then, so there is nothing to undo.
    ///
    /// Counted on the document while out (``EditorDocument/backgroundWrites``), so the disk watch
    /// doesn't take the file this write installed, newer than the document's stamp until the
    /// commit, for a change made elsewhere. Begun before the bytes leave and ended after the
    /// commit, both on the main actor where the watch runs.
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
            } catch let failure as EditorFileStore.Failure where failure.landed != nil {
                // Landed and checked, another version kept beside it: a write to commit.
                landed = Landing(ticket: snapshot.ticket, path: snapshot.path, from: snapshot.stamp,
                                 text: snapshot.text, stamp: failure.landed!)
                return .keptAside(failure.landed!, failure.savedBut ?? "")
            } catch {
                return .ended(.of(error))
            }
        }.value
        // From here the commit owns the landing, unless a settle took it first; then the stamp has
        // moved and the guard below drops the result.
        _ = landings.take(ticket: snapshot.ticket)

        // The document moved on while the write was out, so the result describes a state no longer
        // on screen.
        guard document.path == snapshot.path, document.stamp == snapshot.stamp else {
            return .nothingToDo
        }
        switch result {
        case .overtaken:
            return .nothingToDo
        case .wrote(let stamp):
            document.markSaved(text: snapshot.text, stamp: stamp)
            return .wrote
        case .keptAside(let stamp, let clause):
            document.markSaved(text: snapshot.text, stamp: stamp)
            return .wroteKeepingAside(clause)
        case .blocked(let divergence):
            return .blocked(divergence)
        case .ended(let outcome):
            // Landed, unchecked: remembered, so the disk can be compared with it later.
            if case .savedUnchecked = outcome { document.noteUncheckedWrite(snapshot.text) }
            return outcome
        }
    }

    /// What the detached half answers, including the case ``Outcome`` has no word for: a write
    /// overtaken by a newer one, which therefore never happened.
    private enum Result: Sendable {
        case wrote(EditorFileStore.Stamp)
        /// Written and checked, with a displaced version kept beside it; the clause says where.
        case keptAside(EditorFileStore.Stamp, String)
        case overtaken
        case blocked(EditorFileStore.Divergence)
        /// A write that threw: failed, or landed and couldn't be checked.
        case ended(Outcome)
    }

    // MARK: - A synchronous save meeting a background one (FR50)

    /// What a background write put on disk, known off the main actor before its commit is.
    struct Landing: Sendable {
        var ticket: UInt64
        var path: String
        /// The document's stamp the write was made against, which the commit guards on.
        var from: EditorFileStore.Stamp
        var text: String
        var stamp: EditorFileStore.Stamp
    }

    /// Where a background write records what it installed, the moment it has. Kept on the document
    /// (``EditorDocument/landings``) and locked, because it is written off the main actor while the
    /// main actor may be waiting on it. See ``settleLandedWrite(into:waitingUpTo:)``.
    final class Landings: @unchecked Sendable {
        private let condition = NSCondition()
        private var outstanding = 0
        private var landed: Landing?

        /// A write is leaving: told on the main actor, before the bytes go.
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

        /// Takes the record of the last write that landed; only `ticket`'s, when one is named.
        func take(ticket: UInt64? = nil) -> Landing? {
            condition.lock(); defer { condition.unlock() }
            guard let landed, ticket == nil || landed.ticket == ticket else { return nil }
            self.landed = nil
            return landed
        }
    }

    /// Commits a background write that has landed but whose commit hasn't reached the main actor
    /// yet, now, on the main actor, exactly as that commit would.
    ///
    /// Between the swap that installs autosave's bytes and the hop back that marks them saved, the
    /// file on disk is newer than the document's stamp, and it is the editor's own. The disk watch
    /// waits out that window (``EditorDocument/backgroundWrites``). A synchronous save (⌘S, the
    /// flush before another file opens, the flush at ⌘Q) would otherwise see "changed on disk" and
    /// ask, and Use Disk Version or Don't Save would throw away what was typed after the snapshot,
    /// and its undo history, over the app's own change.
    ///
    /// So a synchronous save that finds the file diverged while a write is out waits for that write
    /// to finish with the disk (usually just a stat and a delete are left) and takes what it
    /// installed as saved, against the snapshot's text. The buffer is then compared with that
    /// write's stamp, and anything typed since stays dirty for the caller to write. The commit,
    /// when it arrives, finds the stamp moved and drops its result. A write that found a real
    /// change, failed, or was overtaken leaves no record, and the caller asks about the divergence
    /// as usual.
    ///
    /// - Parameter limit: how long the main actor may wait, a ceiling for a volume that has stopped
    ///   answering; after it the divergence is asked about as usual.
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
