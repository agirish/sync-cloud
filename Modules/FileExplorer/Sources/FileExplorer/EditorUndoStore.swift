import Foundation
import Events

/// One undo stack per document, so ⌘Z survives switching files.
///
/// `NSTextView` registers undo by character range against the text it was made in. Replayed into
/// another document, a ⌘Z splices characters out wherever the ranges land, or throws
/// `NSRangeException` and takes the app down with every unsaved buffer. A stack per path keeps two
/// documents' registrations apart.
///
/// A stack is only replayable if the buffer you come back to is the buffer you left. It may not
/// be: the file was reloaded, an Organize run moved it, or you answered "Don't Save" with autosave
/// off. So each stack is kept beside a fingerprint of the text it was parted from, and one that
/// doesn't match what loads is thrown away. Refusing is always safe; replaying a stale stack is not.
/// Each stack also travels with the text storage its actions edit (``EditorSourceStorage``): the
/// two are kept, refused, handed back and evicted together.
@MainActor
public final class EditorUndoStore: ObservableObject {

    /// The manager the editor is currently using. Published, because the text view has to be handed
    /// the new one the moment the document changes.
    @Published public private(set) var current = UndoManager()

    /// The text storage ``current``'s actions edit, the open document's, handed to its buffer by
    /// ``EditorBuffer/follow(_:)`` once ``activate(path:text:)`` has chosen it.
    @Published public private(set) var source = EditorSourceStorage()

    /// How many documents keep their history. A count, not an idle timer: a timer would take the
    /// history exactly when you come back to a file you edited hours ago. Eight covers every
    /// realistic round trip.
    public let limit: Int

    /// The deepest each stack goes before its oldest edits fall off. Bounds the case the count
    /// can't: one document where large blocks are deleted over and over. An insertion's undo stores
    /// only a range, so typing is nearly free; deletions cost. 200 groups is far past real use.
    public static let levelsOfUndo = 200

    public init(limit: Int = 8) {
        self.limit = limit
        current.levelsOfUndo = Self.levelsOfUndo
    }

    /// What a stack expects the buffer to be: length and hash, since a second copy of every
    /// document's text would cost more than the stacks do.
    ///
    /// The hash is over the UTF-8 bytes, not the `String`. `String.hashValue` normalises for
    /// canonical equivalence grapheme by grapheme over a bridged UTF-16 buffer with no fast path:
    /// 138 ms against 12 ms at the 4 MiB ``BoundedTextRead/maxBytes`` allows, on the main actor, on
    /// every file switch. Both fields come from one `Data`, so the text is transcoded once. The copy
    /// is cheaper than making the bridged string contiguous for `Hasher.combine(bytes:)`, and
    /// `Data.hashValue` reads every byte (it is not the `NSData` prefix hash).
    ///
    /// Byte-hashing also refuses a stack when canonically equivalent text with different bytes comes
    /// back. That is the safe direction, and honest: saving one over the other writes a different
    /// file. Pinned by `EditorUndoStoreTests.aStackIsRefusedWhenTheBytesChangedUnderAnEqualString`.
    struct Fingerprint: Equatable {
        var length: Int
        var hash: Int

        init(_ text: String) {
            let bytes = Data(text.utf8)
            length = bytes.count
            hash = bytes.hashValue
        }
    }

    private struct Entry {
        var manager: UndoManager
        /// The storage `manager`'s actions edit. Its text is what `fingerprint` was taken from.
        var source: EditorSourceStorage
        var fingerprint: Fingerprint
    }

    private var stacks: [String: Entry] = [:]
    /// Most recently used last, so eviction takes from the front. A plain array suits eight entries.
    private var order: [String] = []
    /// The document `current` belongs to, so its stack is filed under the right path on the way out.
    private var activePath: String?

    /// Files whose history is being kept, not counting the open one.
    public var keptCount: Int { stacks.count }

    /// Files the eviction rule dropped this session, for the log and for a test to prove eviction
    /// happened rather than infer it from an absence.
    public private(set) var evictedCount = 0

    /// Puts the open document's stack away, against the text it is being parted from. Called on the
    /// way out, the one moment the buffer and the stack are known to agree.
    ///
    /// The storage stops listening to the buffer first, document or not: a load or close writes
    /// the buffer next, and a storage still attached would take the incoming file's text into the
    /// storage kept for the outgoing one.
    ///
    /// Not kept: a document with nothing to undo or redo (it would hold up to 4 MiB of storage and
    /// an LRU slot for an empty history), and a storage parted from mid-composition, whose text
    /// holds a word the buffer never had. The composition is ended here as a backstop
    /// (`settleEditorDocument` ends it first) and that history dropped, the safe direction.
    ///
    /// - Parameter opening: the file about to be opened, **which eviction never takes**. Eviction
    ///   runs here, before ``activate(path:text:)``, so the oldest entry is often the one being
    ///   reached for; the next oldest goes instead.
    public func remember(text: String, opening: String? = nil) {
        let wasComposing = source.endComposition()
        source.buffer = nil
        guard let path = activePath else { return }
        guard !wasComposing, current.canUndo || current.canRedo else {
            stacks[path] = nil
            order.removeAll { $0 == path }
            return
        }
        stacks[path] = Entry(manager: current, source: source, fingerprint: Fingerprint(text))
        promote(path)
        evictIfNeeded(sparing: opening)
    }

    /// Takes the buffer's own storage as the open one before the first load, so the two start as
    /// one, as every load and close leaves them. Otherwise the first load writes into a storage that
    /// is then thrown away, and a view mounted on it resyncs.
    ///
    /// Only while nothing is open and nothing can be undone, so ``current``'s actions are never
    /// paired with a storage they weren't made against; a no-op once the two are one.
    public func adopt(_ initial: EditorSourceStorage) {
        guard activePath == nil, !current.canUndo, !current.canRedo else { return }
        source = initial
    }

    /// Hands back the stack for `path` if it still fits `text`, or a fresh one if it does not.
    public func activate(path: String?, text: String) {
        activePath = path
        defer { source.fileName = path.map { ($0 as NSString).lastPathComponent } }
        guard let path else {
            current = fresh()
            source = EditorSourceStorage(text: text)
            return
        }
        if let entry = stacks[path], entry.fingerprint == Fingerprint(text) {
            current = entry.manager
            source = entry.source
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
            source = EditorSourceStorage(text: text)
        }
    }

    /// Throws away one document's history: the file was reloaded, abandoned, or is gone.
    public func forget(_ path: String) {
        stacks[path]?.manager.removeAllActions()
        stacks[path] = nil
        order.removeAll { $0 == path }
        if activePath == path {
            current.removeAllActions()
        }
    }

    /// The open document's file moved (Finder, Organize or another device), and its history goes
    /// with it. The stack and storage still fit the text; only the path they're filed under changes,
    /// so the next ``remember(text:opening:)`` files them where the document now is. A history kept
    /// under the destination path belonged to a different file and is dropped.
    public func move(from old: String, to new: String) {
        guard old != new else { return }
        if activePath == old { activePath = new }
        stacks[new]?.manager.removeAllActions()
        stacks[new] = stacks.removeValue(forKey: old)
        order.removeAll { $0 == new }
        if let index = order.firstIndex(of: old) {
            if stacks[new] != nil { order[index] = new } else { order.remove(at: index) }
        }
    }

    /// Drops the history of files that are no longer where they were: a stack for a path that no
    /// longer exists can never be handed back. Cheap enough to run on every document load.
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

    private func evictIfNeeded(sparing spared: String? = nil) {
        while order.count > limit, let oldest = order.first(where: { $0 != spared }) {
            order.removeAll { $0 == oldest }
            // Emptied, not just dropped: an `UndoManager` the text view still references would
            // otherwise keep every registration alive, the memory eviction exists to release.
            stacks[oldest]?.manager.removeAllActions()
            stacks[oldest] = nil
            evictedCount += 1
        }
    }
}
