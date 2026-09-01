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
    public enum Outcome: Equatable {
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

    /// Attempts one write.
    ///
    /// **Never resolves a divergence, and never asks.** A background write that could answer "the
    /// file changed underneath you" by picking a side would be the one place in this app that makes
    /// that choice for somebody. It reports, and the host decides what to put on screen.
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
}
