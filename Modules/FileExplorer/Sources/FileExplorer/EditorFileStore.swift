import Foundation
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
        /// Text the editor will show and refuse to save, with the reason to put on screen.
        case readOnly(text: String, reason: String)
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
        "Some of this file isn't valid text, so it's open for reading only — saving would replace "
        + "the parts that couldn't be read."

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
                guard !lossy else { return .readOnly(text: text, reason: lossyReason) }
                // No stamp means no way to notice the file changing under the buffer, and a save
                // path that cannot check is worse than one that will not open.
                guard let stamp = stamp(ofPath: path, fileManager: fileManager),
                      let before, before == stamp else {
                    if attempt == 0 { continue }
                    return .refused(reason: "Kept changing while it was being read.")
                }
                return .editable(text: text, stamp: stamp, encoding: encoding)
            case .tooLarge, .cloudOnly, .binary, .unreadable:
                // `Outcome.caption` is already written for a reader; the fallback is unreachable
                // and is here so this cannot silently show an empty reason if a case ever stops
                // carrying one.
                return .refused(reason: outcome.caption ?? "Couldn't be read.")
            }
        }
        return .refused(reason: "Kept changing while it was being read.")
    }

    /// How the file on disk differs from the buffer's idea of it.
    public enum Divergence: Equatable {
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
        guard let current = self.stamp(ofPath: path, fileManager: fileManager) else { return .missing }
        return current == stamp ? nil : .changed
    }

    /// Something the save path could not do, in prose the banner can show as written.
    public struct Failure: LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
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

    @discardableResult
    static func write(_ text: String, toPath path: String,
                      encoding: BoundedTextRead.TextEncoding = .utf8) throws -> Stamp {
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
            throw Failure(message: "There's a folder called “\(destination.lastPathComponent)” "
                + "here now, so this can't be saved over it.")
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
        defer {
            if !installed { try? fileManager.removeItem(at: staged) }
            try? fileManager.removeItem(at: backupPath)
        }

        // **Written back in the encoding it was read in.** The reader decodes six of them, and a
        // writer that only spoke UTF-8 would silently transcode a UTF-16 or BOM-carrying file the
        // first time somebody saved it: still openable, still correct here, and a different file to
        // everything else that produced or consumes it.
        guard let bytes = encode(text, as: encoding) else {
            throw Failure(message: "This file's text can't be written back as \(encoding.rawValue).")
        }
        try bytes.write(to: staged)
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
        if let backup { try? fileManager.removeItem(at: backup) }

        guard let stamp = stamp(ofPath: destination.path) else {
            // The bytes are on disk — this is only the read-back of the new stamp failing, so it is
            // reported rather than treated as a lost save.
            throw Failure(message: "Saved, but the file couldn't be re-checked afterwards.")
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
            throw Failure(message: "Saved, but the file changed again immediately afterwards — "
                + "check it before writing over it.")
        }
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
        case .readOnly(_, let reason): return .readOnly(reason)
        case .refused(let reason): return .refused(reason)
        }
    }

    /// Writes the open document back, in the encoding it was read in.
    ///
    /// Refuses a document with no encoding recorded — a read-only or unopened one — rather than
    /// defaulting to UTF-8, which is exactly the silent transcode this pairing exists to prevent.
    @MainActor
    @discardableResult
    public static func write(_ document: EditorDocument) throws -> Stamp {
        guard let path = document.path, let encoding = document.encoding else {
            throw Failure(message: "There is nothing open to save.")
        }
        return try write(document.text, toPath: path, encoding: encoding)
    }

    // MARK: - New files

    /// The extension a name with none gets.
    public static let defaultExtension = "md"

    /// The stem the naming row prefills.
    public static let untitledStem = "Untitled"

    /// Completes a typed name: trims it, and appends ``defaultExtension`` when it has none.
    ///
    /// A dotfile (`.gitignore`) is left alone — `NSString.pathExtension` calls its whole name the
    /// stem and no extension, and appending `.md` to it would be the one case where "helpfully"
    /// finishing a name changes what the user asked for.
    public static func completedName(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix(".") { return trimmed }
        guard (trimmed as NSString).pathExtension.isEmpty else { return trimmed }
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
        guard !name.contains("/") else { return "A file name can't contain a slash." }
        guard name != ".", name != ".." else { return "That isn't a file name." }
        let path = (folder as NSString).appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: path) else { return "“\(name)” already exists here." }
        return nil
    }

    /// Creates an empty file and returns its path.
    ///
    /// Refuses rather than overwrites — the caller has already asked ``refusal(forName:in:)``, and
    /// this is the check that closes the window between asking and creating.
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
        // leading dot through untouched, which is true of `..` as well, and `write` then resolves
        // the path with `resolvingSymlinksInPath`, which collapses `..` LEXICALLY: a name of
        // `../escape` creates the file in the parent folder and hands back a path the document then
        // holds as its identity. Re-asking here is what closes that, and it closes the create race
        // in the same call.
        if let refusal = refusal(forName: typed, in: folder) {
            throw Failure(message: refusal)
        }
        let path = (folder as NSString).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw Failure(message: "“\(name)” already exists here.")
        }
        try write("", toPath: path)
        return path
    }
}
