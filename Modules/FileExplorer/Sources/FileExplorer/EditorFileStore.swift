import Foundation
import Events
import Sync

/// The editor's file layer (open, save, create) with no view attached.
///
/// Separate because it is the half that rewrites the bytes inside a file. Its rules are stated once
/// and tested against a real temp directory: never save a decode that lost information, never
/// write over a file that changed underneath, never leave a half-written file where the old was.
public enum EditorFileStore {

    /// What a file looked like when it was read: the triple the save path re-checks.
    ///
    /// Size alone misses a same-length edit; mtime alone misses a filesystem with coarse timestamps.
    /// The inode is the one that isn't a heuristic: every atomic-save writer (TextEdit,
    /// `FileOperations`, ``write(_:toPath:encoding:expected:)``) installs a new file, so a
    /// replacement always changes it. Without it, a restore that puts back content and mtime over a
    /// same-length edit (`cp -p`, Time Machine) goes unseen and ⌘S overwrites it without a prompt.
    public struct Stamp: Equatable, Sendable {
        public var modifiedAt: Date?
        public var size: Int
        /// `.systemFileNumber`, the inode. Zero when the filesystem did not report one.
        public var fileID: Int = 0

        /// Public so a stamp kept elsewhere, such as an Ask Claude card's saved copy, can be
        /// compared with a fresh one.
        public init(modifiedAt: Date?, size: Int, fileID: Int = 0) {
            self.modifiedAt = modifiedAt
            self.size = size
            self.fileID = fileID
        }
    }

    /// The path the editor actually reads and writes, with any symlinks along it resolved.
    ///
    /// The file APIs disagree about symlinks: `contents(atPath:)` follows one, `attributesOfItem`
    /// stamps the link itself, and `replaceItemAt` refuses a link ("The file doesn't exist."), so a
    /// symlinked note would open but never save. Resolving the whole path also puts the staged temp
    /// on the real file's volume, which keeps the swap a rename rather than a copy.
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Reads a file's stamp, or `nil` when it can't be stat'd, including when it isn't there.
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
    /// Internal, because it names the encoding the bytes were read in. The app target uses
    /// ``load(path:into:)`` instead, which keeps the encoding on this side so no caller can save a
    /// file back in the wrong one.
    enum Opened: Equatable {
        /// Text the editor may write back, the stamp to check it against at save time, and the
        /// encoding it must be written back in.
        case editable(text: String, stamp: Stamp, encoding: BoundedTextRead.TextEncoding)
        /// Text the editor shows and won't save, with the reason to put on screen, and the stamp
        /// taken before the read so a later change is noticed. Before, not after: a write landing
        /// mid-read then reads as a change and the read-only document reloads, the safe direction.
        case readOnly(text: String, reason: String, stamp: Stamp? = nil)
        /// Nothing to show; `reason` is already reader-facing prose.
        case refused(reason: String)
    }

    /// Why a lossy decode opens read-only. `BoundedTextRead` decodes invalid UTF-8 with
    /// replacement characters, which is fine for reading, but saving it back would turn every
    /// unreadable byte into U+FFFD for good.
    public static let lossyReason =
        "Some of this file isn’t valid text, so it’s open for reading only — saving would replace "
        + "the parts that couldn’t be read."

    /// Opens a file for the editor, applying the read cap, the cloud-only check and the NUL sniff
    /// that `BoundedTextRead` already owns.
    ///
    /// The raw string, never `BoundedTextRead.lines`, which normalises line endings to LF: a file
    /// opened and saved without an edit must come back byte for byte.
    static func open(path: String,
                     fileManager: FileManaging = FileManager.default,
                     isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) })
        -> Opened {
        // Stat, read, stat. A stamp taken only after the read could describe a newer file than
        // the bytes in hand, and `divergence` would then say "nothing changed" while the next ⌘S
        // writes the stale buffer over the newer file. Writes mid-read are ordinary in iCloud, so
        // a disagreement is retried once before it is refused.
        for attempt in 0...1 {
            let before = stamp(ofPath: path, fileManager: fileManager)
            let outcome = BoundedTextRead.read(path: path, isCloudOnly: isCloudOnly)
            switch outcome {
            case .text(let text, let lossy, let encoding):
                guard !lossy else { return .readOnly(text: text, reason: lossyReason, stamp: before) }
                // No stamp means no way to notice the file changing under the buffer, and a save
                // that can't check is worse than a file that won't open.
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

    /// Edit's own words for a file it won't open. `BoundedTextRead`'s captions are written for
    /// Compare's diff ("Too large to diff"), so the two about size and binaries are Edit's here; the
    /// rest read the same in both. The fallback is unreachable, so a reason is never empty.
    static func refusal(for outcome: BoundedTextRead.Outcome) -> String {
        switch outcome {
        case .tooLarge(let bytes): return tooLargeReason(bytes: bytes)
        case .binary: return notTextReason
        case .text, .cloudOnly, .unreadable: return outcome.caption ?? "Couldn’t be read."
        }
    }

    /// A file past the read cap, in Edit's words. The rail's dimmed row says the same
    /// (``EditorRailEntry/tooLargeReason(size:)``), so the row and the refusal agree.
    static func tooLargeReason(bytes: Int) -> String {
        "Too large to open in Edit — \(FileSyncManager.formatBytes(bytes)), and Edit opens text "
            + "files up to \(FileSyncManager.formatBytes(BoundedTextRead.maxBytes))."
    }

    /// A file with a NUL in it, in Edit's words.
    static let notTextReason = "This isn’t a text file, so Edit can’t open it."

    /// Why a file that wouldn't hold still while being read was refused: the one refusal the disk
    /// watch answers by looking again rather than showing it.
    static let keptChangingReason = "Kept changing while it was being read."

    /// How the file on disk differs from the buffer's idea of it.
    public enum Divergence: Equatable, Sendable {
        /// It changed since it was opened.
        case changed
        /// It is not there any more. A divergence, not `nil`: Organize can file or rename the open
        /// document, and just writing it would recreate it at the old path, leaving two copies and
        /// undoing the move. So this asks as loudly as a modification does.
        case missing
    }

    /// Whether the file has moved out from under a buffer opened with `stamp`.
    public static func divergence(atPath path: String, from stamp: Stamp,
                           fileManager: FileManaging = FileManager.default) -> Divergence? {
        divergence(of: self.stamp(ofPath: path, fileManager: fileManager), from: stamp)
    }

    /// The same answer for a stamp the caller has already read, so it can keep that stamp rather
    /// than stat again and hold a different one.
    public static func divergence(of current: Stamp?, from stamp: Stamp) -> Divergence? {
        guard let current else { return .missing }
        return current == stamp ? nil : .changed
    }

    /// Something the save path could not do, in prose the banner can show as written.
    public struct Failure: LocalizedError, Equatable {
        public var message: String
        /// Set when the bytes are on disk and only the look afterwards failed: the clause after
        /// "Saved “name”, but …". A save that landed is never reported as one that couldn't be made.
        public var savedBut: String?
        /// Set when the write landed and was checked: the stamp it read back, with `savedBut` saying
        /// where a displaced version was kept. The document is marked saved against this stamp.
        public var landed: Stamp?
        public var errorDescription: String? { message }

        public init(message: String, savedBut: String? = nil, landed: Stamp? = nil) {
            self.message = message
            self.savedBut = savedBut
            self.landed = landed
        }

        /// The write landed and `clause` is what went wrong after it, said as "Saved, but …".
        static func saved(but clause: String) -> Failure {
            Failure(message: "Saved, but \(clause)", savedBut: clause)
        }

        /// The stat that stamps a write found nothing it could read.
        static let unchecked = saved(but: "couldn’t read it back to check it.")
        /// The stat found a different file: something replaced it in the moment after the swap.
        static let changedAgain = saved(
            but: "it changed again straight afterwards — check it before writing over it.")
    }

    /// The bytes `text` becomes in `encoding`, byte-order mark included where the encoding has one.
    ///
    /// Marks are re-emitted, not dropped, since they decide what the next reader thinks the file
    /// is. `String.data(using:)` adds none for UTF-16/32, so each is written with an explicit byte
    /// order and its own mark.
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
    /// Autosave writes off the main actor from a snapshot; ⌘S and the flushes on leaving a document
    /// and at quit write synchronously. Unordered, an older background write landing after a newer
    /// synchronous one would leave old text on disk, silently. So each write takes a ticket:
    ///
    /// - A synchronous write takes its ticket inside the lock, so it is always the newest and
    ///   always commits; a background write in progress makes it wait, so it lands last.
    /// - A background write takes its ticket on the main actor at dispatch. If anything has
    ///   committed since, it writes nothing: what it carries is older than what is there.
    ///
    /// The lock is held across the whole write, `F_FULLFSYNC` included, which only a rare collision
    /// pays for. Ordered per destination: writes to different files can't overwrite each other, and
    /// a global order would refuse saves for no reason. The counter is global so tickets compare;
    /// the map, never pruned, holds the newest committed ticket per path.
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

    /// A ticket for a write about to be dispatched off the main actor. Taken at dispatch, so a
    /// synchronous write issued after it (⌘S, a flush, quit) outranks it. See ``WriteOrder``.
    static func issueWriteTicket() -> UInt64 { writeOrder.issue() }

    /// Writes `text` to `path` atomically, and returns the stamp the buffer should now hold.
    ///
    /// Staged and swapped, never written in place, so a crash can't leave a half-written file: a
    /// `.tmp_<UUID>` sibling on the same volume, then `FileManaging.replaceItem`, as
    /// `FileOperations.safeCopyItem` does. Creation rides the same path: with no destination,
    /// `replaceItem` falls back to a plain move.
    ///
    /// The backup is deleted, unlike `FileOperations`: it is the previous state of the document
    /// being typed into, which undo covers, and keeping it would fill the Trash with one per ⌘S.
    /// A save over a divergence takes the same branch, and there undo covers nothing; it is reached
    /// only through an alert saying "the other changes are lost", so the loss is consented to.
    ///
    /// No `FileManaging` parameter: that protocol has no byte-write member, so the staging write
    /// goes to Foundation, and a seam over only the rename would answer for two filesystems.
    ///
    /// The returned stamp is read back, not derived, so a sync client landing its own version in
    /// the instant after the swap is described instead, and the next ⌘S sees no divergence. The
    /// size check in the read-back narrows that.
    @discardableResult
    static func write(_ text: String, toPath path: String,
                      encoding: BoundedTextRead.TextEncoding = .utf8,
                      expected: Stamp? = nil) throws -> Stamp {
        // A write happening now takes the newest ticket and can't be refused, so the force-unwrap
        // is total.
        try writeOrder.perform(ticket: nil, to: resolved(path)) {
            try writeUnordered(text, toPath: path, encoding: encoding, expected: expected)
        }!
    }

    /// Writes bytes to `path`, through the same staging, flush, swap and read-back as the text
    /// save. File ▸ Export as PDF… goes through here, so there is one way this app puts a file on
    /// disk; a bare `Data.write(to:)` could leave a truncated file, let the swap outrun the bytes,
    /// or miss a replacement after the swap.
    ///
    /// It takes the write order too, which matters when an export lands on a file the editor also
    /// has open. No encoding parameter, because bytes have none.
    @discardableResult
    public static func write(_ data: Data, toPath path: String) throws -> Stamp {
        try writeOrder.perform(ticket: nil, to: resolved(path)) {
            try writeUnordered(bytes: data, toPath: path)
        }!
    }

    /// Thrown by ``createNew(_:atPath:)`` and ``createNew(copying:toPath:)`` when something is
    /// already at the destination: the one failure a caller choosing names recovers from by trying
    /// the next.
    struct AlreadyExists: Error, Equatable {
        let path: String
    }

    /// Puts new bytes on disk at `path`, and never replaces anything there.
    ///
    /// ``write(_:toPath:)`` is a save and swaps the destination out, which a new file must never
    /// do: a same-named file synced in after the name was chosen would be overwritten. So this
    /// stages and flushes the same way, then moves in with `renamex_np(…, RENAME_EXCL)`, which the
    /// kernel refuses if anything is at `path`, in the same step. No check-then-write window.
    @discardableResult
    static func createNew(_ data: Data, atPath path: String) throws -> Stamp {
        try createNew(atPath: path, expectedSize: data.count) { staged in
            try data.write(to: staged)
        }
    }

    /// The same, with the bytes copied from `source`, a dropped file. A copy, never a move: the
    /// dragged file stays where it was.
    ///
    /// The bytes alone (`COPYFILE_DATA`), not the Finder lock, ACLs or extended attributes:
    /// `copyItem` would carry a lock or deny-delete ACL onto the staged copy, then fail to move it
    /// in and fail to clean up, leaving a locked hidden file in a synced folder. The cost is losing
    /// APFS's clone, about 70 ms for a 200 MB file, rare for an image.
    @discardableResult
    static func createNew(copying source: String, toPath path: String) throws -> Stamp {
        let size = (try? FileManager.default.attributesOfItem(atPath: source))?[.size] as? NSNumber
        return try createNew(atPath: path, expectedSize: size?.intValue) { staged in
            guard copyfile(source, staged.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                throw Failure(message: String(cString: strerror(errno)))
            }
        }
    }

    /// The reason, not the staged file's name: Foundation's sentence for a failed staging write
    /// names the hidden `.tmp_…` file, which the reader won't find, so a full disk reads "No space
    /// left on device" instead.
    static func stagingFailure(_ error: Error) -> Failure {
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Failure(message: String(cString: strerror(Int32(underlying.code))))
        }
        // What is known is that macOS refused without a reason this app can name.
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
            // A volume that can't rename exclusively (some network shares) gets the check and a
            // plain rename: the window this door closes, open only where it must be.
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
        // A new file SyncCloud put in place, such as a PDF tool's output or an imported image.
        ChangedFileLedger.shared.note(destination.path)
        guard let stamp = stamp(ofPath: destination.path) else {
            throw Failure.unchecked
        }
        if let expectedSize, stamp.size != expectedSize {
            throw Failure.changedAgain
        }
        return stamp
    }

    /// The same write, carrying a ticket taken earlier (``WriteOrder``).
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
        // Written back in the encoding it was read in, so a UTF-16 or BOM-carrying file is never
        // silently transcoded on its first save.
        guard let bytes = encode(text, as: encoding) else {
            throw Failure(message: "This file’s text can’t be written back as \(encoding.rawValue).")
        }
        return try writeUnordered(bytes: bytes, toPath: path, expected: expected)
    }

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

    /// The staging, the flush, the swap and the read-back that both doors share, with the bytes
    /// already decided.
    ///
    /// - Parameter expected: the stamp the bytes were written against, the document's for a save.
    ///   When the file the swap displaced is neither that nor this store's own last write, someone
    ///   else installed it after the caller's check, and it is kept.
    private static func writeUnordered(bytes: Data, toPath path: String,
                                       expected: Stamp? = nil) throws -> Stamp {
        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: resolved(path))

        // **The destination must be a regular file or nothing at all**, and only this guard says
        // so. Given a directory, `replaceItemAt` succeeds and moves the tree aside as the backup,
        // which the delete below then unlinks permanently, with no Trash entry. A path opened as a
        // file can be a directory by save time (a `.textbundle` written over the note), and
        // `divergence` would report that as an ordinary `.changed`.
        if let existing = try? fileManager.attributesOfItem(atPath: destination.path),
           (existing[.type] as? FileAttributeType) != .typeRegular {
            throw Failure(message: "There’s a folder called “\(destination.lastPathComponent)” "
                + "here now, so this can’t be saved over it.")
        }

        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp_\(UUID().uuidString)")
        // Named up front so the sweep can find it even when `replaceItem` throws: a throw returns
        // no URL, and a backup made just before the failure would be unreachable.
        let backupName = ".rollback_\(UUID().uuidString)"
        let backupPath = destination.deletingLastPathComponent().appendingPathComponent(backupName)
        var installed = false
        // The staged file is swept unless it became the destination, and the backup is swept
        // always (on success it is already gone, and `try?` makes that a no-op). Both are hidden,
        // so an orphan would sync to iCloud unseen. `try?` so cleanup never masks the real error.
        // Set when a version the swap displaced couldn't be moved aside: it is then the only copy,
        // and stays as the hidden backup rather than being swept.
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
        // Flushed before the swap: APFS may commit the rename before the staged data reaches
        // stable storage, and a power loss then would leave the file pointing at unwritten blocks.
        // `F_FULLFSYNC`, not `fsync`, because only it asks the drive to flush its own cache.
        if let handle = try? FileHandle(forWritingTo: staged) {
            // A network share may refuse F_FULLFSYNC, so a refusal falls back to the ordinary flush.
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { _ = fsync(handle.fileDescriptor) }
            try? handle.close()
        }
        let backup = try fileManager.replaceItem(at: destination, withItemAt: staged,
                                                 backupItemName: backupName)
        installed = true
        // A file SyncCloud changed in a cloud folder, whose upload it may watch.
        ChangedFileLedger.shared.note(destination.path)
        // **The backup is looked at before it is deleted.** The encode, staged write and flush run
        // after the caller's check, and a version installed meanwhile (another Mac's sync) becomes
        // this backup. One that is neither the version written against nor this store's last
        // write is that version, and is kept beside the file rather than deleted unseen.
        var keptAside: String?
        if let backup {
            let displaced = stamp(ofPath: backup.path)
            if let expected, let displaced, displaced != expected,
               displaced != lastWritten[destination.path] {
                let kept = keptAsideURL(for: destination)
                if (try? fileManager.moveItem(at: backup, to: kept)) != nil {
                    keptAside = "That version was kept beside it as “\(kept.lastPathComponent)”."
                } else {
                    // Not deleted for failing to move: it stays as the hidden backup, named in the
                    // message so it can be found (⇧⌘. shows hidden files).
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
                // The read-back passed, so this is a checked save, not an unchecked write that
                // would stop autosave.
                if stamp.size == bytes.count { throw Failure(message: "Saved, but \(clause)", savedBut: clause, landed: stamp) }
            }
            throw Failure.saved(but: clause)
        }
        guard let stamp = stamp(ofPath: destination.path) else {
            // The bytes are on disk; only the read-back failed, so it is reported, not treated as
            // a lost save.
            throw Failure.unchecked
        }
        // The read-back is checked, not just taken: a file of the wrong size was replaced after
        // the swap, and marking the buffer clean against it would let the next save overwrite it
        // without asking. Refusing turns that lost update into a question. Size, not a hash: a
        // re-read per autosave would cost more than the write, and a different version is
        // essentially never the same length.
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
        /// Shown, but not saveable; the reason is already reader-facing prose.
        case readOnly(String)
        /// Nothing to show, same.
        case refused(String)
    }

    /// Reads `path` and puts it in `document`.
    ///
    /// One call, not open-then-hand-over, so the encoding can't be separated from the text it
    /// produced. That pairing is why a save never silently transcodes.
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
    /// Refuses a document with no encoding recorded (read-only or unopened) rather than defaulting
    /// to UTF-8, the silent transcode this pairing prevents.
    ///
    /// - Parameter consentedTo: the disk's stamp when the user chose Keep Mine. Without it the write
    ///   is checked against the document's stamp, and the version the user chose to discard would
    ///   be kept as an "(other version)".
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
            // Landed and checked, with another version kept beside it: saved, and still thrown,
            // so the caller can say where the other version went.
            document.markSaved(text: text, stamp: failure.landed!)
            throw failure
        } catch let failure as Failure where failure.savedBut != nil {
            // Landed, unchecked: remembered, so the disk can be compared with it later (TE147).
            document.noteUncheckedWrite(text)
            throw failure
        }
    }

    /// A write that couldn't be checked, checked now: when the file holds exactly the text that
    /// write put there, in its encoding, the document counts it as saved with the stamp just read.
    /// Anything else leaves it as it was, to be asked about.
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
    /// Only an extension in ``EditableText/extensions`` counts, since `NSString.pathExtension`
    /// takes whatever follows the last dot: "notes.txt" keeps its own, and "Notes v1.2" becomes
    /// "Notes v1.2.md" rather than a file Edit opens as plain text. A dotfile (`.gitignore`) is left
    /// alone, since appending `.md` would change what the user asked for.
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
    /// Bounded, not `while true`: a folder that answers to every name gives back a name the caller
    /// can refuse, rather than spinning.
    public static func availableUntitledName(in folder: String,
                                      fileManager: FileManaging = FileManager.default) -> String {
        for index in 1...999 {
            let stem = index == 1 ? untitledStem : "\(untitledStem) \(index)"
            let name = stem + "." + defaultExtension
            let candidate = (folder as NSString).appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate) { return name }
        }
        // Every candidate is taken. The first would be refused at once by the naming row; the
        // thousandth is at least a name the user can act on.
        return "\(untitledStem) 1000." + defaultExtension
    }

    /// Why a typed name cannot become a file, or `nil` when it can.
    ///
    /// Prose for an inline hint under the naming row, not an alert: the fix is to keep typing,
    /// which a modal would interrupt.
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
    /// Refuses rather than overwrites: the caller has asked ``refusal(forName:in:fileManager:)``,
    /// and the exclusive create closes the window between asking and creating.
    ///
    /// No `FileManaging` parameter, as for ``write(_:toPath:encoding:expected:)``: the bytes go to
    /// `FileManager.default` regardless, so an injected manager would answer for a different disk.
    public static func createEmptyFile(named typed: String, in folder: String) throws -> String {
        let name = completedName(typed)
        // ``refusal(forName:in:fileManager:)`` again, since this is public and the naming row's
        // hint is only a convention. `completedName` passes a leading dot through, `..` included,
        // and `createNew` installs at the joined path, so `../escape` would create the file in the
        // parent folder.
        if let refusal = refusal(forName: typed, in: folder) {
            throw Failure(message: refusal)
        }
        let path = (folder as NSString).appendingPathComponent(name)
        // Created exclusively: `createNew` installs with `RENAME_EXCL`, so a same-named file
        // arriving from a sync is refused, not replaced by an empty one.
        do {
            try createNew(Data(), atPath: path)
        } catch is AlreadyExists {
            throw Failure(message: "“\(name)” already exists here.")
        }
        return path
    }
}
