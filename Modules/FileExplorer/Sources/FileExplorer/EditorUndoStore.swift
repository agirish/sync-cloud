import Foundation
import Events

/// One undo stack per document, so ⌘Z survives switching files.
///
/// **The stack used to be wiped on every file switch, and that wipe was correct.** `NSTextView`
/// registers undo by character RANGE in the buffer the edit was made against; assigning a new
/// string replaces the buffer and clears nothing, so a ⌘Z after switching files replayed one
/// document's edits into another — splicing its characters out where the ranges happened to land,
/// or throwing `NSRangeException` and taking the app down with every unsaved buffer in it.
///
/// Keeping a stack per path fixes the cause rather than the symptom: two documents' registrations
/// can no longer meet. But it introduces a second way to get the same crash, and this type exists
/// to close it.
///
/// **A stack is only replayable if the buffer you come back to is the buffer you left**, and there
/// are now several ways for it not to be — the file was reloaded from disk, an Organize run moved
/// it, or (since autosave became per-file) you left it with autosave off and answered "Don't Save",
/// so the disk still holds the text from before your edits while the stack holds registrations
/// against the text after them. So every stack is kept beside a fingerprint of the text it was
/// parted from, and a stack whose fingerprint does not match what was loaded is thrown away rather
/// than handed back. **Refusing is always safe; replaying a stale stack is what is not.**
@MainActor
public final class EditorUndoStore: ObservableObject {

    /// The manager the editor is currently using. Published, because the text view has to be handed
    /// the new one the moment the document changes.
    @Published public private(set) var current = UndoManager()

    /// How many documents keep their history.
    ///
    /// **A count, deliberately, and deliberately not a timer.** An idle expiry would take the
    /// history exactly when it is most wanted — you edited a file this morning, worked elsewhere,
    /// and came back having forgotten what you changed — to reclaim a few megabytes. The count is
    /// what actually bounds the growth, and eight covers every realistic round trip.
    public let limit: Int

    /// The deepest each stack goes before its oldest edits fall off.
    ///
    /// **The bound for the pathological case the count cannot reach**: one document in which large
    /// blocks are deleted over and over, where a single stack holds every removed block. An
    /// undo registration for an INSERTION stores a range and nothing else, so typing is nearly
    /// free; it is deletion that costs, and this is what stops one file's deletions growing without
    /// limit. 200 groups is far past any session's real use — the stack was wiped at every file
    /// switch until now, so effective depth has always been much shallower than this.
    public static let levelsOfUndo = 200

    public init(limit: Int = 8) {
        self.limit = limit
        current.levelsOfUndo = Self.levelsOfUndo
    }

    /// What a stack expects the buffer to be.
    ///
    /// Length and hash rather than the text: keeping a second copy of every document's contents to
    /// protect their undo stacks would cost more memory than the stacks do. The length is in there
    /// because it is free and rules out the overwhelming majority of mismatches on its own.
    struct Fingerprint: Equatable {
        var length: Int
        var hash: Int

        init(_ text: String) {
            length = text.utf8.count
            hash = text.hashValue
        }
    }

    private struct Entry {
        var manager: UndoManager
        var fingerprint: Fingerprint
    }

    private var stacks: [String: Entry] = [:]
    /// Least-recently-used last. A plain array, because eight entries never justify anything else.
    private var order: [String] = []
    /// The document `current` belongs to, so its stack is filed under the right path on the way out.
    private var activePath: String?

    /// Files whose history is being kept, not counting the open one.
    public var keptCount: Int { stacks.count }

    /// Files the eviction rule dropped this session — for the log, and for a test to prove eviction
    /// happened rather than inferring it from an absence.
    public private(set) var evictedCount = 0

    /// Puts the open document's stack away, against the text it is being parted from.
    ///
    /// Called on the way OUT, which is the one moment the buffer and the stack are known to agree.
    public func remember(text: String) {
        guard let path = activePath else { return }
        stacks[path] = Entry(manager: current, fingerprint: Fingerprint(text))
        promote(path)
        evictIfNeeded()
    }

    /// Hands back the stack for `path` if it still fits `text`, or a fresh one if it does not.
    public func activate(path: String?, text: String) {
        activePath = path
        guard let path else {
            current = fresh()
            return
        }
        if let entry = stacks[path], entry.fingerprint == Fingerprint(text) {
            current = entry.manager
            promote(path)
        } else {
            // Either nothing was kept, or what was kept describes a buffer this is not.
            if stacks[path] != nil {
                Logger.shared.info("Editor dropped the undo history for \(path) — the file changed "
                                   + "since it was last open")
            }
            stacks[path] = nil
            order.removeAll { $0 == path }
            current = fresh()
        }
    }

    /// Throws away one document's history — the file was reloaded, abandoned, or is gone.
    public func forget(_ path: String) {
        stacks[path]?.manager.removeAllActions()
        stacks[path] = nil
        order.removeAll { $0 == path }
        if activePath == path {
            current.removeAllActions()
        }
    }

    /// Drops the history of files that are no longer where they were.
    ///
    /// **Correctness before thrift.** A stack for a path that no longer exists can never be handed
    /// back — reopening from that path will not happen — so keeping it is holding memory for an
    /// outcome that cannot occur. Cheap enough to run when a stack is put away.
    public func forgetMissingFiles(fileManager: FileManager = .default) {
        for path in stacks.keys where !fileManager.fileExists(atPath: path) {
            stacks[path] = nil
            order.removeAll { $0 == path }
        }
    }

    private func fresh() -> UndoManager {
        let manager = UndoManager()
        manager.levelsOfUndo = Self.levelsOfUndo
        return manager
    }

    private func promote(_ path: String) {
        order.removeAll { $0 == path }
        order.append(path)
    }

    private func evictIfNeeded() {
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            // **Emptied, not just dropped.** An `UndoManager` the text view still references would
            // otherwise keep every registration alive for as long as that reference lasts, which is
            // the memory this eviction exists to release.
            stacks[oldest]?.manager.removeAllActions()
            stacks[oldest] = nil
            evictedCount += 1
        }
    }
}
