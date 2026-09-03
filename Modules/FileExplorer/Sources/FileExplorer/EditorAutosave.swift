import Foundation

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
    public struct Key: Equatable, Sendable {
        public var version: Int
        public var path: String?
        public init(version: Int, path: String?) {
            self.version = version
            self.path = path
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
            return .blocked(divergence)
        }
        do {
            document.markSaved(stamp: try EditorFileStore.write(document))
            return .wrote
        } catch {
            return .failed(error.localizedDescription)
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
    @MainActor
    public static func write(_ snapshot: Snapshot, into document: EditorDocument) async -> Outcome {
        let result = await Task.detached(priority: .utility) { () -> Result in
            if let divergence = EditorFileStore.divergence(atPath: snapshot.path,
                                                           from: snapshot.stamp) {
                return .blocked(divergence)
            }
            do {
                guard let stamp = try EditorFileStore.write(snapshot.text, toPath: snapshot.path,
                                                            encoding: snapshot.encoding,
                                                            ticket: snapshot.ticket) else {
                    return .overtaken
                }
                return .wrote(stamp)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

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
        case .failed(let message):
            return .failed(message)
        }
    }

    /// What the detached half answers, including the one case ``Outcome`` has no word for: a write
    /// that was overtaken by a newer one and therefore never happened.
    private enum Result: Sendable {
        case wrote(EditorFileStore.Stamp)
        case overtaken
        case blocked(EditorFileStore.Divergence)
        case failed(String)
    }
}
