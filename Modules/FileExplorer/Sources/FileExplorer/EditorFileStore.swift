import Foundation
import Events
import Sync

/// The editor's file layer — open, save, create — with no view attached.
///
/// **Separate from the document and from the views because it is the half that touches his data.**
/// Every other surface in the app moves whole files; this is the first one that rewrites the bytes
/// inside one, so the rules it enforces (never save a decode that lost information, never write
/// over a file that changed underneath you, never leave a half-written file where the old one was)
/// are stated once, here, and can be tested against a real temp directory without laying out a
/// single view.
public enum EditorFileStore {

    /// What a file looked like when it was read: the triple the save path re-checks.
    ///
    /// Modification date and size together rather than either alone. Size alone misses an edit that
    /// happens to preserve the length; mtime alone misses a filesystem whose timestamp resolution is
    /// coarser than the gap between two writes.
    ///
    /// **And the inode, which is the one of the three that is not a heuristic.** Every atomic-save
    /// writer on this platform — TextEdit, this app's own `FileOperations`, and ``write(_:toPath:encoding:)``
    /// below — installs a *new* file rather than rewriting the old one, so a replacement always
    /// changes this number whatever the size and the timestamp happen to say. Without it a restore
    /// that puts back both the content and the mtime (`cp -p`, `rsync -t`, Time Machine, "Revert to
    /// previous version") over a same-length edit — `2026-08-30` for `2026-08-31`, `[ ]` for `[x]` —
    /// is a divergence nothing can see, and ⌘S overwrites it with no prompt. It costs nothing: it
    /// arrives in the same attributes dictionary the other two are read from.
    public struct Stamp: Equatable, Sendable {
        public var modifiedAt: Date?
        public var size: Int
        /// `.systemFileNumber` — the inode. Zero when the filesystem did not report one.
        public var fileID: Int = 0
    }

    /// **The path the editor actually reads and writes**, with any symlinks along it resolved.
    ///
    /// Everything else here disagreed about symlinks, and the disagreement was a file that could be
    /// opened and never saved. `BoundedTextRead` reads through `contents(atPath:)`, which follows a
    /// link, so a symlinked `.md` opened normally; `attributesOfItem` does *not* follow one, so the
    /// stamp described the link (its size is the length of the path it holds); and `replaceItemAt`
    /// refuses a link outright, throwing `NSCocoaErrorDomain 4 — "The file doesn't exist."` for a
    /// file plainly sitting in the rail. Resolving once, here, is what makes the three agree.
    ///
    /// It resolves the *whole* path, so the staged temp lands beside the real file on the real
    /// file's volume — which is what keeps the swap a rename rather than a copy.
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Reads a file's stamp, or `nil` when it cannot be stat'd — which includes not being there.
    public static func stamp(ofPath path: String,
                      fileManager: FileManaging = FileManager.default) -> Stamp? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved(path)) else {
            return nil
        }
        return Stamp(modifiedAt: attributes[.modificationDate] as? Date,
                     size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                     fileID: (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0)
    }

    /// The result of opening a file in the editor.
    ///
    /// **Internal**, because it names the encoding the bytes were read in, and `BoundedTextRead` is
    /// this module's own. The app target does not need it: it orchestrates prompts and logging, and
    /// ``load(path:into:)`` is the seam it uses instead. Keeping the encoding on this side is also
    /// what makes it impossible for a caller to save a file back in the wrong one.
    enum Opened: Equatable {
        /// Text the editor may write back, the stamp to check it against at save time, and the
        /// encoding it must be written back IN.
        case editable(text: String, stamp: Stamp, encoding: BoundedTextRead.TextEncoding)
        /// Text the editor will show and refuse to save, with the reason to put on screen — and the
        /// stamp taken before the read, so a change arriving later is still noticed (TE59). Taken
        /// BEFORE rather than after: a write landing mid-read then reads as a change, and a read-only
        /// document reloads, which is the safe direction for a file that cannot be written anyway.
        case readOnly(text: String, reason: String, stamp: Stamp? = nil)
        /// Nothing to show; `reason` is already reader-facing prose.
        case refused(reason: String)
    }

    /// **Why a lossy decode opens read-only.**
    ///
    /// `BoundedTextRead` falls back to a replacement-character decode when a file is not valid
    /// UTF-8, which is the right call for *reading* — a mostly-text file with one bad byte is still
    /// worth showing. Saving that same string back is not the same act: every byte the decoder
    /// could not read has become U+FFFD, and writing it out would destroy the original bytes for
    /// good. So the file opens, and the editor says why it will not take a change.
    public static let lossyReason =
        "Some of this file isn’t valid text, so it’s open for reading only — saving would replace "
        + "the parts that couldn’t be read."

    /// Opens a file for the editor, applying the read cap, the cloud-only check and the NUL sniff
    /// that `BoundedTextRead` already owns.
    ///
    /// **The raw string, never `BoundedTextRead.lines`.** That helper normalises CRLF and CR to LF
    /// on the way through, which is exactly right for a line-by-line diff and exactly wrong here: a
    /// file opened and saved without being edited must come back byte for byte, and a normalising
    /// read would silently rewrite every line ending in the file the first time someone pressed ⌘S.
    static func open(path: String,
                     fileManager: FileManaging = FileManager.default,
                     isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) })
        -> Opened {
        // **Stat, read, stat — and the second stat is the one that matters.** Taking the stamp
        // only after the read certifies a state LATER than the bytes in hand: a write landing
        // between the two leaves the buffer holding the old text paired with the new file's stamp,
        // and `divergence` then answers "nothing changed" forever. That is not the loud kind of
        // failure — the next ⌘S writes the stale buffer over the newer file and never asks.
        // Reading an iCloud folder is exactly where that interleaving is ordinary rather than
        // exotic, so the read is bracketed and a disagreement is retried once before it is refused.
        for attempt in 0...1 {
            let before = stamp(ofPath: path, fileManager: fileManager)
            let outcome = BoundedTextRead.read(path: path, isCloudOnly: isCloudOnly)
            switch outcome {
            case .text(let text, let lossy, let encoding):
                guard !lossy else { return .readOnly(text: text, reason: lossyReason, stamp: before) }
                // No stamp means no way to notice the file changing under the buffer, and a save
                // path that cannot check is worse than one that will not open.
                guard let stamp = stamp(ofPath: path, fileManager: fileManager),
                      let before, before == stamp else {
                    if attempt == 0 { continue }
                    return .refused(reason: keptChangingReason)
                }
                return .editable(text: text, stamp: stamp, encoding: encoding)
            case .tooLarge, .cloudOnly, .binary, .unreadable:
                return .refused(reason: refusal(for: outcome))
            }
        }
        return .refused(reason: keptChangingReason)
    }

    /// **Edit's own words for a file it will not open** (TE103). `BoundedTextRead`'s captions are
    /// written for Compare's diff — "Too large to diff", and "the preview shows it properly", which
    /// in Edit reads as its own Preview mode — so the two that are about Edit say so here, and
    /// Compare keeps its own. The other two already read the same in both places; the fallback is
    /// unreachable, and is here so this cannot show an empty reason if a case stops carrying one.
    static func refusal(for outcome: BoundedTextRead.Outcome) -> String {
        switch outcome {
        case .tooLarge(let bytes): return tooLargeReason(bytes: bytes)
        case .binary: return notTextReason
        case .text, .cloudOnly, .unreadable: return outcome.caption ?? "Couldn’t be read."
        }
    }

    /// A file past the read cap, in Edit's words — the rail's dimmed row says the same
    /// (``EditorRailEntry/tooLargeReason(size:)``), so the row and the refusal agree.
    static func tooLargeReason(bytes: Int) -> String {
        "Too large to open in Edit — \(FileSyncManager.formatBytes(bytes)), and Edit opens text "
            + "files up to \(FileSyncManager.formatBytes(BoundedTextRead.maxBytes))."
    }

    /// A file with a NUL in it, in Edit's words.
    static let notTextReason = "This isn’t a text file, so Edit can’t open it."

    /// Why a file that would not hold still while it was read was refused — and the one refusal
    /// the disk watch answers by looking again rather than by showing it (TE59).
    static let keptChangingReason = "Kept changing while it was being read."

    /// How the file on disk differs from the buffer's idea of it.
    public enum Divergence: Equatable, Sendable {
        /// It changed since it was opened.
        case changed
        /// It is not there any more.
        ///
        /// **A missing file counts as a divergence, and that is the whole reason this case is
        /// separate from `nil`.** An Organize run can file or rename the open document while the
        /// editor holds it; the tempting behaviour — the destination is gone, so just write it —
        /// would recreate the file at the old path, leaving two copies and undoing a move the user
        /// asked for. So this asks as loudly as a modification does.
        case missing
    }

    /// Whether the file has moved out from under a buffer opened with `stamp`.
    public static func divergence(atPath path: String, from stamp: Stamp,
                           fileManager: FileManaging = FileManager.default) -> Divergence? {
        divergence(of: self.stamp(ofPath: path, fileManager: fileManager), from: stamp)
    }

    /// The same answer for a stamp the caller has already read — so a caller that asks about the
    /// version it found can keep THAT stamp, rather than stat again and hold a different one.
    public static func divergence(of current: Stamp?, from stamp: Stamp) -> Divergence? {
        guard let current else { return .missing }
        return current == stamp ? nil : .changed
    }

    /// Something the save path could not do, in prose the banner can show as written.
    public struct Failure: LocalizedError, Equatable {
        public var message: String
        /// **Set when the bytes ARE on disk** and only the look afterwards failed (TE114) — the
        /// clause that follows "Saved “name”, but …". A save that landed is not reported as one
        /// that could not be made: "Couldn't save “x” — Saved, but…" said both.
        public var savedBut: String?
        /// **Set when the write landed AND was checked** — the stamp it read back — and `savedBut`
        /// says where a different version it displaced was kept (FR48). A save with something to
        /// say, not one owed a check: the document is marked saved against this stamp.
        public var landed: Stamp?
        public var errorDescription: String? { message }

        public init(message: String, savedBut: String? = nil, landed: Stamp? = nil) {
            self.message = message
            self.savedBut = savedBut
            self.landed = landed
        }

        /// The write landed and `clause` is what went wrong after it — said whole as "Saved, but …".
        static func saved(but clause: String) -> Failure {
            Failure(message: "Saved, but \(clause)", savedBut: clause)
        }

        /// The stat that stamps a write found nothing it could read.
        static let unchecked = saved(but: "couldn’t read it back to check it.")
        /// The stat found a different file — something replaced it in the moment after the swap.
        static let changedAgain = saved(
            but: "it changed again straight afterwards — check it before writing over it.")
    }

    /// Writes `text` to `path` atomically, and returns the stamp the buffer should now hold.
    ///
    /// **Staged and swapped, never written in place.** A direct write leaves a window in which the
    /// file on disk is neither the old version nor the new one, and a crash inside that window
    /// costs the file. This follows the engine's own precedent (`FileOperations.safeCopyItem`): a
    /// `.tmp_<UUID>` sibling in the destination's own directory — same volume, so the swap is a
    /// rename — then `FileManaging.replaceItem`.
    ///
    /// **The backup is deleted, which is where this deliberately parts from the engine.**
    /// `FileOperations` keeps the replaced file (in the Trash, or as a hidden sibling) because
    /// there it is somebody's *other* file being overwritten by a copy. Here it is the previous
    /// state of the document the user is deliberately typing into, undo already covers it, and
    /// keeping it would put one Trash entry in the Trash for every ⌘S.
    ///
    /// **That rationale covers the ordinary save and NOT the save over a divergence**, and the
    /// difference is worth stating because the code takes the same branch for both. When
    /// `saveEditorDocument` has just seen `.changed`, the bytes being replaced are not a previous
    /// state of this buffer at all — they are a version that arrived from another device — and undo
    /// covers nothing. What makes the delete right there is not undo but *consent*: that path is
    /// reached only through a warning alert whose own words are "the other changes are lost", with
    /// the confirming button stripped of its Return key. Keeping the file instead would trade a
    /// disclosed loss for an undisclosed `.rollback_` orphan syncing to iCloud, which is a worse
    /// answer to the same question.
    ///
    /// Creation rides the same path: `replaceItem`'s conformance falls back to a plain `moveItem`
    /// when the destination does not exist, so an empty new file is this function with `""`.
    ///
    /// **No `FileManaging` parameter, on `BoundedTextRead`'s reasoning.** That protocol is
    /// path-level by documented decision and has no byte-write member, so the staging write has to
    /// go to Foundation directly — and a seam that governed the rename while the bytes went
    /// somewhere else would be a seam that answers about two filesystems. One filesystem, named
    /// once.
    ///
    /// **The returned stamp is read back afterwards, not derived from what was written.** In the
    /// microseconds between the swap and the read a sync client can land its own version at the
    /// path, in which case this describes that file rather than these bytes. The window is not
    /// worth an advisory lock — but it is worth saying, because the next ⌘S compares against this
    /// stamp and will therefore see no divergence.
    /// The bytes `text` becomes in `encoding`, byte-order mark included where the encoding has one.
    ///
    /// **Byte-order marks are re-emitted, not dropped.** A file that opened as "UTF-8 with a BOM"
    /// said so in its first three bytes; writing it back without them changes what the next reader
    /// — this app included — decides the file is. `String.data(using:)` adds no BOM for the
    /// UTF-16/32 cases either, so each is written explicitly little- or big-endian with its own
    /// mark rather than left to the platform's default byte order.
    static func encode(_ text: String, as encoding: BoundedTextRead.TextEncoding) -> Data? {
        switch encoding {
        case .utf8:
            return Data(text.utf8)
        case .utf8WithBOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LittleEndian:
            return text.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        case .utf16BigEndian:
            return text.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        case .utf32LittleEndian:
            return text.data(using: .utf32LittleEndian).map { Data([0xFF, 0xFE, 0x00, 0x00]) + $0 }
        case .utf32BigEndian:
            return text.data(using: .utf32BigEndian).map { Data([0x00, 0x00, 0xFE, 0xFF]) + $0 }
        }
    }

    /// Serialises every write this store makes, and orders them.
    ///
    /// **Two writers now exist where there was one.** Autosave writes off the main actor from a
    /// snapshot; ⌘S, the flush at every route out of a document, and the flush at quit all still
    /// write synchronously on the main actor. Without a shared order the two can interleave, and
    /// the failure is silent and one-directional: a background write carrying an older snapshot
    /// landing *after* a synchronous write of a newer one leaves the older text on disk with
    /// nothing on screen saying so. At quit there is no later write to put it right.
    ///
    /// So a write takes a **ticket**, and the store refuses one that has been overtaken:
    ///
    /// - A synchronous write takes its ticket inside the lock, so it is always the newest and
    ///   always commits. A background write in progress makes it wait, which is correct — it is
    ///   the newer text and it must land last.
    /// - A background write takes its ticket on the main actor when it is dispatched. If anything
    ///   has committed since, its ticket is stale and it writes nothing at all, which is right:
    ///   what it was carrying is older than what is already there.
    ///
    /// The lock is held across the whole write, `F_FULLFSYNC` included. That is tens of
    /// milliseconds on an internal SSD and more on an external volume — paid by a synchronous
    /// flush that collides with a background one, which is rare and is the only way to be correct.
    /// **Ordered per destination, because that is the question.** Two writes to two different files
    /// cannot overwrite each other, and a global order would make one refuse the other for no
    /// reason — which in a test process running suites in parallel is a flake, and in the app is a
    /// save silently declining because something else was written first. The ticket counter is
    /// global and monotonic so tickets remain comparable; what is remembered per path is only the
    /// newest one that actually committed there.
    ///
    /// The map is never pruned. It holds one small entry per file this store has written for the
    /// life of the process, and the editor writes one open document at a time.
    private final class WriteOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var issued: UInt64 = 0
        private var committed: [String: UInt64] = [:]

        /// The ticket a write dispatched now should carry.
        func issue() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            issued &+= 1
            return issued
        }

        /// Runs `body` under this destination's write order.
        ///
        /// - Parameter ticket: `nil` for a write happening now, which takes a fresh ticket and
        ///   therefore always wins. A ticket issued earlier commits only if nothing newer has
        ///   committed to the same destination since.
        /// - Returns: `nil` when the write was overtaken and nothing was written.
        func perform<T>(ticket: UInt64?, to path: String, _ body: () throws -> T) rethrows -> T? {
            lock.lock()
            defer { lock.unlock() }
            let mine: UInt64
            if let ticket {
                guard ticket > (committed[path] ?? 0) else { return nil }
                mine = ticket
            } else {
                issued &+= 1
                mine = issued
            }
            let result = try body()
            committed[path] = max(committed[path] ?? 0, mine)
            return result
        }
    }

    private static let writeOrder = WriteOrder()

    /// A ticket for a write that is about to be dispatched off the main actor.
    ///
    /// Taken at dispatch rather than inside the write, so that a synchronous write issued *after*
    /// this one — a ⌘S, a flush, a quit — outranks it. See ``WriteOrder``.
    static func issueWriteTicket() -> UInt64 { writeOrder.issue() }

    @discardableResult
    static func write(_ text: String, toPath path: String,
                      encoding: BoundedTextRead.TextEncoding = .utf8,
                      expected: Stamp? = nil) throws -> Stamp {
        // A write happening now, so it takes the newest ticket and cannot be refused — which is
        // what makes the force-unwrap total rather than optimistic.
        try writeOrder.perform(ticket: nil, to: resolved(path)) {
            try writeUnordered(text, toPath: path, encoding: encoding, expected: expected)
        }!
    }

    /// Writes **bytes** to `path`, through the same staging, flush, swap and read-back the text
    /// save uses.
    ///
    /// **The door File ▸ Export as PDF… goes through, and it exists so that there is one answer to
    /// "how does this app put a file on disk".** Everything the editor writes is text, so this
    /// store spoke only text; a bare `Data.write(to:)` beside it would be a second writer with none
    /// of what the first one learned — no staging, so a crash mid-write leaves a truncated PDF
    /// where the old one was; no `F_FULLFSYNC`, so the swap can outrun the bytes; no read-back, so
    /// a file replaced in the window after the swap is never noticed.
    ///
    /// It takes the write order for the same reason too. An export writes a *different* path from
    /// the document being edited, and the order is per destination, so in practice it waits for
    /// nothing — but "in practice" is doing the work there, and an export over a file the editor
    /// also has open is exactly the case where it stops being true.
    ///
    /// No encoding parameter, because bytes have none. That is the whole difference between this
    /// door and the text one above, and it is why the encoding now lives on the text path rather
    /// than in the staging code the two share.
    @discardableResult
    public static func write(_ data: Data, toPath path: String) throws -> Stamp {
        try writeOrder.perform(ticket: nil, to: resolved(path)) {
            try writeUnordered(bytes: data, toPath: path)
        }!
    }

    /// Thrown by ``createNew(_:atPath:)`` and ``createNew(copying:toPath:)`` when something is
    /// already at the destination — the one failure a caller choosing names can recover from by
    /// choosing the next one.
    struct AlreadyExists: Error, Equatable {
        let path: String
    }

    /// **Puts NEW bytes on disk at `path`, and never replaces anything there** (TE56).
    ///
    /// ``write(_:toPath:)`` is a save: it swaps the destination out with `replaceItemAt`, which is
    /// what a save means and exactly what a new image must never do — two notes pasting into one
    /// Images folder, or a file synced in between the name being chosen and the write, would be
    /// overwritten without a word. So this stages and flushes as that door does, then moves the
    /// staged file in with `renamex_np(…, RENAME_EXCL)`: the kernel refuses if anything is at
    /// `path` by then, in the same step that would otherwise have replaced it. No check-then-write
    /// window.
    @discardableResult
    static func createNew(_ data: Data, atPath path: String) throws -> Stamp {
        try createNew(atPath: path, expectedSize: data.count) { staged in
            try data.write(to: staged)
        }
    }

    /// The same, with the bytes copied from `source` — a dropped file. **A copy, never a move**: the
    /// file the reader dragged stays where it was.
    ///
    /// **The bytes alone — `COPYFILE_DATA` — not the Finder lock, ACLs or extended attributes.**
    /// `copyItem` carries the lock, a deny-delete ACL and a read-only mode over to the staged copy
    /// (measured by the 2026-10-04 review), and then the move into place fails and so does the
    /// clean-up, leaving a locked hidden file in a synced folder; a read-only copy also cannot be
    /// opened to flush. The copy keeps the source's mode with the owner's write bit added.
    ///
    /// **The price is APFS's clone**: the blocks are copied rather than shared — measured by the
    /// same review at about 70ms for a 200 MB file, on the main thread. Images are rarely that size;
    /// a locked hidden file left in somebody's cloud folder is not a price worth that saving.
    @discardableResult
    static func createNew(copying source: String, toPath path: String) throws -> Stamp {
        let size = (try? FileManager.default.attributesOfItem(atPath: source))?[.size] as? NSNumber
        return try createNew(atPath: path, expectedSize: size?.intValue) { staged in
            guard copyfile(source, staged.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                throw Failure(message: String(cString: strerror(errno)))
            }
        }
    }

    /// **The reason, not the staged file's name**: Foundation's sentence for a failed staging write
    /// names the hidden `.tmp_…` file, which the reader never asked for and will not find — so a
    /// full disk reads "No space left on device" (TE175).
    static func stagingFailure(_ error: Error) -> Failure {
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Failure(message: String(cString: strerror(Int32(underlying.code))))
        }
        // Not "it couldn't be written there" (TE114), which said nothing a reader could act on:
        // what is known is that macOS refused without a reason this app can name.
        return Failure(message: "macOS wouldn’t write it there and gave no reason.")
    }

    private static func createNew(atPath path: String, expectedSize: Int?,
                                  stage: (URL) throws -> Void) throws -> Stamp {
        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: path)
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp_\(UUID().uuidString)")
        var installed = false
        defer { if !installed { try? fileManager.removeItem(at: staged) } }

        do {
            try stage(staged)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw stagingFailure(error)
        }
        // Flushed before it is moved in, for the reason the save path gives: the rename can reach
        // the disk before the data does.
        if let handle = try? FileHandle(forWritingTo: staged) {
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { _ = fsync(handle.fileDescriptor) }
            try? handle.close()
        }
        if renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            if code == EEXIST { throw AlreadyExists(path: path) }
            // A volume that cannot rename exclusively (some network shares) gets the check and the
            // plain rename — the window this door exists to close, open only where it must be.
            guard code == ENOTSUP || code == EINVAL else {
                throw Failure(message: String(cString: strerror(code)))
            }
            // `attributesOfItem` does not follow a symlink, so a dangling link here is "taken" too.
            guard (try? fileManager.attributesOfItem(atPath: destination.path)) == nil else {
                throw AlreadyExists(path: path)
            }
            guard rename(staged.path, destination.path) == 0 else {
                throw Failure(message: String(cString: strerror(errno)))
            }
        }
        installed = true
        guard let stamp = stamp(ofPath: destination.path) else {
            throw Failure.unchecked
        }
        if let expectedSize, stamp.size != expectedSize {
            throw Failure.changedAgain
        }
        return stamp
    }

    /// The same write, carrying a ticket taken earlier — see ``WriteOrder``.
    ///
    /// - Returns: `nil` when a newer write has already committed, in which case nothing was
    ///   written and nothing should be marked saved against it.
    static func write(_ text: String, toPath path: String,
                      encoding: BoundedTextRead.TextEncoding,
                      ticket: UInt64, expected: Stamp? = nil) throws -> Stamp? {
        try writeOrder.perform(ticket: ticket, to: resolved(path)) {
            try writeUnordered(text, toPath: path, encoding: encoding, expected: expected)
        }
    }

    private static func writeUnordered(_ text: String, toPath path: String,
                                       encoding: BoundedTextRead.TextEncoding,
                                       expected: Stamp? = nil) throws -> Stamp {
        // **Written back in the encoding it was read in.** The reader decodes six of them, and a
        // writer that only spoke UTF-8 would silently transcode a UTF-16 or BOM-carrying file the
        // first time somebody saved it: still openable, still correct here, and a different file to
        // everything else that produced or consumes it.
        guard let bytes = encode(text, as: encoding) else {
            throw Failure(message: "This file’s text can’t be written back as \(encoding.rawValue).")
        }
        return try writeUnordered(bytes: bytes, toPath: path, expected: expected)
    }

    /// The staging, the flush, the swap and the read-back — everything both doors share, with the
    /// bytes already decided.
    /// The stamp each destination was left with by this store's own last write, read and written
    /// only inside `writeOrder.perform`, whose lock serialises every write.
    nonisolated(unsafe) private static var lastWritten: [String: Stamp] = [:]

    /// Where a version found in the swap's backup is kept: beside the file, visibly named, never
    /// over anything already there.
    static func keptAsideURL(for destination: URL, fileManager: FileManager = .default) -> URL {
        let folder = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = stem + (n == 1 ? " (other version)" : " (other version \(n))") + (ext.isEmpty ? "" : ".\(ext)")
            let url = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// - Parameter expected: the stamp the bytes were written against — the document's, for a
    ///   save. When the file the swap displaced is neither that nor this store's own last write,
    ///   somebody else installed it in the window after the caller's check (FR48), and it is kept.
    private static func writeUnordered(bytes: Data, toPath path: String,
                                       expected: Stamp? = nil) throws -> Stamp {
        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: resolved(path))

        // **The destination must be a regular file or nothing at all**, and this guard is the only
        // thing that says so. `replaceItemAt` does not care what it replaces: given a DIRECTORY it
        // succeeds, moves the whole tree aside as the backup, and installs the text file in its
        // place — after which the backup delete below unlinks the directory and everything in it,
        // permanently and without a Trash entry. Nothing upstream closes this: `open` refuses a
        // directory, but a path that was a file when it was opened can be a directory by the time
        // it is saved (a `.textbundle` written over the note, a folder given the note's name), and
        // `divergence` reports that as an ordinary `.changed` whose alert says "the other changes
        // are lost" — prose describing an edited file while a folder is about to be destroyed.
        if let existing = try? fileManager.attributesOfItem(atPath: destination.path),
           (existing[.type] as? FileAttributeType) != .typeRegular {
            throw Failure(message: "There’s a folder called “\(destination.lastPathComponent)” "
                + "here now, so this can’t be saved over it.")
        }

        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp_\(UUID().uuidString)")
        // Named up front so the sweep can find it even when `replaceItem` throws — a throw returns
        // no URL, and a backup created just before the failure would otherwise be unreachable.
        let backupName = ".rollback_\(UUID().uuidString)"
        let backupPath = destination.deletingLastPathComponent().appendingPathComponent(backupName)
        var installed = false
        // The staged file is swept unless it became the destination, and the backup is swept
        // ALWAYS — on the success path it has already gone, and `try?` makes the second attempt a
        // no-op. Both are dot-prefixed and extensionless, so an orphan is invisible in the rail and
        // in Finder and syncs to iCloud looking like nothing at all. `try?` throughout because a
        // failure to clean up must not mask the error that caused it.
        // Set when a version the swap displaced could not be moved aside (FR48): it is then the
        // only copy, and stays as the hidden backup rather than being swept.
        var keepBackupInPlace = false
        defer {
            if !installed { try? fileManager.removeItem(at: staged) }
            if !keepBackupInPlace { try? fileManager.removeItem(at: backupPath) }
        }

        do {
            try bytes.write(to: staged)
        } catch {
            throw stagingFailure(error)
        }
        // **Flushed before the swap, or the swap is a promise the disk has not made.** The rename
        // is what makes this atomic, but APFS is free to commit the rename before the staged file's
        // data blocks reach stable storage — and the old bytes are unlinked immediately after. A
        // power loss in that window would leave the destination pointing at an inode whose contents
        // were never written, which is the exact outcome staging exists to prevent. `F_FULLFSYNC`
        // rather than `fsync`, because only the former asks the drive to flush its own cache.
        if let handle = try? FileHandle(forWritingTo: staged) {
            // Not every filesystem answers F_FULLFSYNC — a network share will refuse it — so a
            // refusal falls back to the ordinary flush rather than being ignored.
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { _ = fsync(handle.fileDescriptor) }
            try? handle.close()
        }
        let backup = try fileManager.replaceItem(at: destination, withItemAt: staged,
                                                 backupItemName: backupName)
        installed = true
        // **The backup is looked at before it is deleted** (FR48). The caller checked the file
        // a stat ago, but the encode, the staged write and the flush all run before the swap — tens
        // of milliseconds, more on iCloud — and a newer version installed in that window (a sync
        // from another Mac, another app's save) became this backup and was deleted outright: no
        // prompt, nothing in the Trash, and the buffer marked saved. A backup that is neither the
        // version the caller wrote against nor this store's own last write is that version, and it
        // is kept beside the file under a name of its own.
        var keptAside: String?
        if let backup {
            let displaced = stamp(ofPath: backup.path)
            if let expected, let displaced, displaced != expected,
               displaced != lastWritten[destination.path] {
                let kept = keptAsideURL(for: destination)
                if (try? fileManager.moveItem(at: backup, to: kept)) != nil {
                    keptAside = "That version was kept beside it as “\(kept.lastPathComponent)”."
                } else {
                    // Not deleted for failing to move: it stays as the hidden backup it already is
                    // — said as a hidden file, since Finder will not show it, and with its name so
                    // it can be found (⇧⌘. shows hidden files).
                    keptAside = "That version was kept beside it as a hidden file, “\(backup.lastPathComponent)”."
                    keepBackupInPlace = true
                }
                Logger.shared.warning("[edit] \(destination.path) changed on disk while it was being saved; the other version was kept as \(keptAside ?? "")")
            }
            if keptAside == nil { try? fileManager.removeItem(at: backup) }
        }

        // The other version's whereabouts outrank the read-back's verdict: both are "saved, but",
        // and only this one names a file the user has to go and look at.
        if let keptAside {
            let clause = "a different version arrived while it was saving. \(keptAside)"
            if let stamp = stamp(ofPath: destination.path) {
                lastWritten[destination.path] = stamp
                // **Checked, so a save** (FR48): the read-back is the one below, and passed. It
                // went out as an unchecked write, and the header then said "couldn't check the save"
                // of a save that had been checked, with autosave stopped for it.
                if stamp.size == bytes.count { throw Failure(message: "Saved, but \(clause)", savedBut: clause, landed: stamp) }
            }
            throw Failure.saved(but: clause)
        }
        guard let stamp = stamp(ofPath: destination.path) else {
            // The bytes are on disk — this is only the read-back of the new stamp failing, so it is
            // reported rather than treated as a lost save.
            throw Failure.unchecked
        }
        // **The read-back is CHECKED, not just taken.** This stat was already here to give the
        // buffer its next stamp, and its size is free evidence about the write that just happened:
        // the file at this path should be exactly as long as the bytes handed to it. When it is
        // not, the file is not the one written a microsecond ago — something replaced it in the
        // window between the swap and this line, which the comment above already names as a real
        // (if narrow) race and which was, until now, silently accepted. Accepting it is the part
        // that mattered: the caller would mark the buffer clean against a stamp describing somebody
        // else's file, and the NEXT save would then see no divergence and overwrite it without
        // asking. Refusing here turns an invisible lost update into a question.
        //
        // Size rather than a hash of the contents: re-reading the whole file on every autosave
        // would cost more than the write, and length is enough to catch a replacement by anything
        // that is not byte-identical — which a different version of a document being edited on two
        // machines essentially never is.
        guard stamp.size == bytes.count else {
            throw Failure.changedAgain
        }
        lastWritten[destination.path] = stamp
        return stamp
    }

    // MARK: - What the app target calls

    /// What opening a file did, in terms the host can log and show.
    public enum OpenResult: Equatable {
        case opened
        /// Shown, but not saveable — the reason is already reader-facing prose.
        case readOnly(String)
        /// Nothing to show, same.
        case refused(String)
    }

    /// Reads `path` and puts it in `document`.
    ///
    /// **One call rather than open-then-hand-over**, so the encoding a file was read in cannot be
    /// separated from the text it produced. That pairing is the whole reason a save does not
    /// silently transcode, and a two-step API is one where a caller can drop the second half.
    @MainActor
    @discardableResult
    public static func load(path: String, into document: EditorDocument) -> OpenResult {
        let outcome = open(path: path)
        document.open(outcome, at: path)
        switch outcome {
        case .editable: return .opened
        case .readOnly(_, let reason, _): return .readOnly(reason)
        case .refused(let reason): return .refused(reason)
        }
    }

    /// Writes the open document back, in the encoding it was read in.
    ///
    /// Refuses a document with no encoding recorded — a read-only or unopened one — rather than
    /// defaulting to UTF-8, which is exactly the silent transcode this pairing exists to prevent.
    ///
    /// - Parameter consentedTo: the disk's stamp when the user agreed to replace what is there —
    ///   Keep Mine. Without it the write is checked against the document's own stamp, and the
    ///   version the user just chose to discard would be kept as an "(other version)" instead.
    @MainActor
    @discardableResult
    public static func write(_ document: EditorDocument, consentedTo: Stamp? = nil) throws -> Stamp {
        guard let path = document.path, let encoding = document.encoding else {
            throw Failure(message: "There is nothing open to save.")
        }
        let text = document.text
        do {
            return try write(text, toPath: path, encoding: encoding, expected: consentedTo ?? document.stamp)
        } catch let failure as Failure where failure.landed != nil {
            // Landed and checked, with another version kept beside it (FR48): saved, and still
            // thrown, so the caller can say where the other version went.
            document.markSaved(text: text, stamp: failure.landed!)
            throw failure
        } catch let failure as Failure where failure.savedBut != nil {
            // Landed, unchecked: remembered, so the disk can be compared with it later (TE147).
            document.noteUncheckedWrite(text)
            throw failure
        }
    }

    /// **A write that couldn't be checked, checked now** (TE147): when the file at the document's
    /// path holds exactly the text that write put there, in its encoding, the document counts it as
    /// saved, with the stamp just read. Anything else — a file that really changed again, or one
    /// that still can't be read — leaves it as it was, to be asked about.
    ///
    /// - Returns: whether it counted the write as saved.
    @MainActor
    @discardableResult
    public static func settleUncheckedWrite(of document: EditorDocument) -> Bool {
        guard let written = document.uncheckedWrite, let path = document.path,
              case .editable(let text, let stamp, let encoding) = open(path: path),
              encoding == document.encoding, EditorSourceStorage.sameBytes(text, written) else { return false }
        document.markSaved(text: written, stamp: stamp)
        return true
    }

    // MARK: - New files

    /// The extension a name with none gets.
    public static let defaultExtension = "md"

    /// The stem the naming row prefills.
    public static let untitledStem = "Untitled"

    /// Completes a typed name: trims it, and appends ``defaultExtension`` unless it already ends in
    /// the extension of a text file Edit opens.
    ///
    /// **Only a known text extension counts as one** (TE102). `NSString.pathExtension` takes
    /// whatever follows the last dot, so "Notes v1.2" and "2026.10.20 standup" came out with no
    /// `.md` — files Edit then opened as plain text, with no Preview and no format bar, or not at
    /// all. Asking the set Edit opens (``EditableText/extensions``) answers both: a name gets `.md`
    /// unless the file it names is one Edit would open as it is — "notes.txt" and "config.yaml"
    /// keep theirs, and "Notes v1.2" becomes "Notes v1.2.md".
    ///
    /// A dotfile (`.gitignore`) is left alone — `NSString.pathExtension` calls its whole name the
    /// stem and no extension, and appending `.md` to it would be the one case where "helpfully"
    /// finishing a name changes what the user asked for.
    public static func completedName(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix(".") { return trimmed }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        guard !EditableText.extensions.contains(ext) else { return trimmed }
        return trimmed + "." + defaultExtension
    }

    /// The first `Untitled.md`, `Untitled 2.md`, … that no file in `folder` already answers to.
    ///
    /// Bounded rather than a `while true`: a folder that somehow answers to every name should give
    /// the caller back a name it can refuse on, not spin.
    public static func availableUntitledName(in folder: String,
                                      fileManager: FileManaging = FileManager.default) -> String {
        for index in 1...999 {
            let stem = index == 1 ? untitledStem : "\(untitledStem) \(index)"
            let name = stem + "." + defaultExtension
            let candidate = (folder as NSString).appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate) { return name }
        }
        // Every candidate is taken. Returning the FIRST one would prefill the naming row with a
        // name its own `refusal` immediately rejects; the thousandth is at least a name that can
        // still be wrong for a reason the user can act on.
        return "\(untitledStem) 1000." + defaultExtension
    }

    /// Why a typed name cannot become a file, or `nil` when it can.
    ///
    /// Returned as prose for an inline hint under the naming row rather than raised as an alert:
    /// the field is still open and the fix is to keep typing, which a modal would interrupt.
    public static func refusal(forName typed: String, in folder: String,
                        fileManager: FileManaging = FileManager.default) -> String? {
        let name = completedName(typed)
        guard !name.isEmpty else { return "Type a name for the file." }
        guard !name.contains("/") else { return "A file name can’t contain a slash." }
        guard name != ".", name != ".." else { return "That isn’t a file name." }
        let path = (folder as NSString).appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: path) else { return "“\(name)” already exists here." }
        return nil
    }

    /// Creates an empty file and returns its path.
    ///
    /// Refuses rather than overwrites — the caller has already asked ``refusal(forName:in:)``, and
    /// the exclusive create is what closes the window between asking and creating.
    ///
    /// **No `FileManaging` parameter**, for the reason ``write(_:toPath:)`` has none: it took one,
    /// and the seam governed the existence check while the bytes went to `FileManager.default`
    /// regardless — so an injected manager would have had its answer honoured and a real file
    /// created on the real disk beside it. One filesystem, named once.
    public static func createEmptyFile(named typed: String, in folder: String) throws -> String {
        let name = completedName(typed)
        // **``refusal(forName:in:)`` again, not just the existence half of it.** The naming row
        // asks it for the inline hint, but this is `public` and that is a convention rather than a
        // check — and the two rules the hint carries are not cosmetic. `completedName` passes a
        // leading dot through untouched, which is true of `..` as well, and `createNew` installs at
        // the path exactly as it is joined, `..` and all, which the kernel follows: a name of
        // `../escape` creates the file in the parent folder and hands back a path the document then
        // holds as its identity. Re-asking here is what closes that; the exclusive create below
        // closes the race between asking and creating.
        if let refusal = refusal(forName: typed, in: folder) {
            throw Failure(message: refusal)
        }
        let path = (folder as NSString).appendingPathComponent(name)
        // **Created exclusively** (FR49). An existence check and then a write left a window in
        // which a same-named file arriving from a sync was replaced by an empty one and its backup
        // deleted; `createNew` installs with `RENAME_EXCL`, so the kernel refuses instead.
        do {
            try createNew(Data(), atPath: path)
        } catch is AlreadyExists {
            throw Failure(message: "“\(name)” already exists here.")
        }
        return path
    }
}
