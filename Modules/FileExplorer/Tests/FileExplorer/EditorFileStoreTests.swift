import Testing
import Foundation
@testable import FileExplorer

/// The editor's file layer, against a real temp directory.
///
/// **Real files, not a fake `FileManaging`.** The claims here are about what ends up on disk —
/// bytes preserved, a temp file swept, a stamp that notices a change — and a fake filesystem would
/// let every one of them pass while the real `replaceItem` did something else.
@Suite struct EditorFileStoreTests {

    /// A scratch directory, removed when the test's `defer` runs.
    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, named name: String, in folder: URL) throws -> String {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    // MARK: Opening

    @Test func openingReadsTheTextAndAStampToCheckItAgainst() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("hello\n".utf8), named: "note.md", in: folder)

        guard case .editable(let text, let stamp, _) = EditorFileStore.open(path: path) else {
            Issue.record("a plain UTF-8 file did not open as editable")
            return
        }
        #expect(text == "hello\n")
        #expect(stamp.size == 6)
        #expect(stamp.modifiedAt != nil)
    }

    /// **The claim the whole `lines()` warning in `open` exists for.**
    ///
    /// `BoundedTextRead.lines` normalises CRLF to LF, which is right for a diff and wrong here: a
    /// file opened and saved untouched must come back byte for byte. This opens a CRLF file, saves
    /// it without editing, and compares the bytes — the version that read through `lines()` would
    /// silently rewrite every line ending in the file on the first ⌘S.
    @Test func aFileOpenedAndSavedUntouchedKeepsItsLineEndings() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = Data("one\r\ntwo\r\n\r\nfour\r\n".utf8)
        let path = try write(original, named: "crlf.txt", in: folder)

        guard case .editable(let text, _, _) = EditorFileStore.open(path: path) else {
            Issue.record("the CRLF file did not open as editable")
            return
        }
        #expect(text.contains("\r\n"), "the read normalised the line endings before anything was saved")
        try EditorFileStore.write(text, toPath: path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original,
                "an untouched open-then-save rewrote the file's bytes")
    }

    /// A decode that lost information opens for reading and carries the reason with it. Saving it
    /// back would write U+FFFD over every byte the decoder could not read.
    @Test func aLossyDecodeOpensReadOnly() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Valid text, then one byte that is not valid UTF-8 and is not a NUL (a NUL would make the
        // sniff call it binary, which is a different refusal).
        var bytes = Data("caf".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Array("\n".utf8))
        let path = try write(bytes, named: "lossy.txt", in: folder)

        guard case .readOnly(let text, let reason) = EditorFileStore.open(path: path) else {
            Issue.record("a lossy decode did not open read-only")
            return
        }
        #expect(text.contains("\u{FFFD}"), "nothing was actually replaced — this file decoded cleanly")
        #expect(reason == EditorFileStore.lossyReason)
    }

    @Test func aFileTheReaderRefusesCarriesItsOwnPromptText() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data([0x00, 0x01, 0x02]), named: "blob.txt", in: folder)

        guard case .refused(let reason) = EditorFileStore.open(path: path) else {
            Issue.record("a NUL-bearing file was offered for editing")
            return
        }
        #expect(reason == BoundedTextRead.Outcome.binary.caption)
    }

    @Test func aFileThatIsNotThereIsRefusedRatherThanOpenedEmpty() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("gone.md").path
        guard case .refused = EditorFileStore.open(path: path) else {
            Issue.record("a missing file opened as something")
            return
        }
    }

    // MARK: The stat guard

    @Test func anUntouchedFileHasNotDiverged() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("stable\n".utf8), named: "a.md", in: folder)
        let stamp = try #require(EditorFileStore.stamp(ofPath: path))
        #expect(EditorFileStore.divergence(atPath: path, from: stamp) == nil)
    }

    @Test func aFileRewrittenUnderTheBufferHasDiverged() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("before\n".utf8), named: "a.md", in: folder)
        let stamp = try #require(EditorFileStore.stamp(ofPath: path))
        // A different length, so the check does not depend on the filesystem's timestamp
        // resolution — mtime alone can miss two writes inside one tick.
        try Data("something longer\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(EditorFileStore.divergence(atPath: path, from: stamp) == .changed)
    }

    /// **Missing is a divergence, not an absence of one.** An Organize run can file the open
    /// document somewhere else; treating "not there" as "nothing to compare against" is what would
    /// silently recreate it at the old path and leave two copies.
    @Test func aFileMovedOutFromUnderTheBufferReportsMissingRatherThanNothing() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("filed\n".utf8), named: "a.md", in: folder)
        let stamp = try #require(EditorFileStore.stamp(ofPath: path))
        try FileManager.default.moveItem(at: URL(fileURLWithPath: path),
                                         to: folder.appendingPathComponent("elsewhere.md"))
        #expect(EditorFileStore.divergence(atPath: path, from: stamp) == .missing)
    }

    // MARK: Writing

    @Test func writingReplacesTheContentAndReturnsTheNewStamp() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("old\n".utf8), named: "a.md", in: folder)

        let stamp = try EditorFileStore.write("new content\n", toPath: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new content\n")
        #expect(stamp.size == 12)
        #expect(EditorFileStore.divergence(atPath: path, from: stamp) == nil,
                "the returned stamp does not describe the file that was just written")
    }

    /// **Nothing is left beside the file.** The staged `.tmp_` sibling is swept, and the
    /// `.rollback_` backup the atomic replace leaves is deleted rather than kept — a Trash entry
    /// per ⌘S is the behaviour this deliberately does not inherit from `FileOperations`.
    @Test func writingLeavesNoTemporaryOrBackupSiblings() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("old\n".utf8), named: "a.md", in: folder)

        try EditorFileStore.write("new\n", toPath: path)
        try EditorFileStore.write("newer\n", toPath: path)

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["a.md"], "the folder holds \(left) after two saves")
    }

    @Test func writingToAPathThatDoesNotExistCreatesIt() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("fresh.md").path

        try EditorFileStore.write("", toPath: path)
        #expect(FileManager.default.fileExists(atPath: path))
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["fresh.md"], "the create path left \(left) behind")
    }

    /// **A save that cannot be staged leaves the old file exactly as it was.**
    ///
    /// Every other write test here is a success path, which left the whole failure branch — the
    /// `defer` sweep, and the guarantee that the destination is untouched — unpinned. A read-only
    /// directory is the cheapest way to make the staging write throw while the destination itself
    /// is perfectly readable.
    @Test func aStagingFailureLeavesTheOriginalFileAndNoDebris() throws {
        let folder = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let path = try write(Data("original\n".utf8), named: "a.md", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        #expect(throws: (any Error).self) {
            try EditorFileStore.write("replacement\n", toPath: path)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "original\n",
                "a failed save rewrote the file it could not stage a replacement for")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["a.md"], "a failed save left \(left) behind")
    }

    /// **A save never writes over a directory** — the one finding here that destroys data rather
    /// than losing an edit.
    ///
    /// `replaceItemAt` does not care what it replaces. Given a directory it SUCCEEDS: it moves the
    /// whole tree aside as the backup and installs the text file in its place, after which the
    /// backup delete unlinks the directory and everything inside it — permanently, with no Trash
    /// entry. Nothing upstream closes this, because `open` refuses a directory but a path that was
    /// a file when it was opened can be a directory by the time it is saved, and `divergence`
    /// reports that as an ordinary `.changed` whose alert says "the other changes are lost" while a
    /// folder is what is about to go.
    @Test func aSaveRefusesADestinationThatHasBecomeADirectory() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("note.md")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("precious\n".utf8).write(to: destination.appendingPathComponent("inside.txt"))

        #expect(throws: EditorFileStore.Failure.self) {
            try EditorFileStore.write("replacement\n", toPath: destination.path)
        }
        #expect(try String(contentsOfFile: destination.appendingPathComponent("inside.txt").path,
                           encoding: .utf8) == "precious\n",
                "the save replaced a folder with a text file and unlinked what was in it")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["note.md"], "the refused save left \(left) behind")
    }

    /// **The stamp notices a replacement that kept the size AND the timestamp.**
    ///
    /// `cp -p`, `rsync -t`, Time Machine and "Revert to previous version" all restore content and
    /// mtime together; over a same-length edit — a date, a `[ ]` for `[x]`, a typo — neither of the
    /// two fields the stamp used to carry moves. The inode does, because every atomic writer on
    /// this platform installs a new file rather than rewriting the old one, so this is the field
    /// that makes the check something other than a heuristic.
    @Test func aReplacementThatKeepsBothSizeAndTimeIsStillADivergence() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("2026-08-30\n".utf8), named: "note.md", in: folder)
        // A whole-second timestamp on BOTH sides. A filesystem keeps sub-second precision that a
        // `Date` round-trip does not reproduce exactly, so restoring "the same" mtime from a stamp
        // taken moments earlier leaves the two a few nanoseconds apart — which the comparison would
        // then catch for the wrong reason, and the inode would never be what was under test.
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: path)
        let stamp = try #require(EditorFileStore.stamp(ofPath: path))

        // Replaced the way a restore does it: new inode, same length, timestamp put back.
        let staged = folder.appendingPathComponent(".restore")
        try Data("2026-08-31\n".utf8).write(to: staged)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: staged)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: path)

        let after = try #require(EditorFileStore.stamp(ofPath: path))
        #expect(after.size == stamp.size, "the fixture changed the length — it is not testing the hard case")
        #expect(after.modifiedAt == stamp.modifiedAt, "the fixture did not restore the timestamp")
        #expect(after.fileID != stamp.fileID, "the fixture reused the inode — nothing here is under test")
        #expect(EditorFileStore.divergence(atPath: path, from: stamp) == .changed,
                "a whole-file replacement that kept size and mtime read as no change at all")
    }

    /// A file reached through a symlink saves the file, not the link.
    ///
    /// All three halves disagreed about symlinks before `resolved(_:)`: the read follows one, the
    /// stat does not, and `replaceItemAt` refuses one outright — so a symlinked file opened
    /// normally, showed the length of its own path as its size, and could never be saved, failing
    /// with "The file doesn't exist." about a file plainly sitting in the rail.
    @Test func aFileReachedThroughASymlinkOpensAndSavesTheFileItPointsAt() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = try write(Data("through the link\n".utf8), named: "target.md", in: folder)
        let link = folder.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)

        guard case .editable(let text, let stamp, _) = EditorFileStore.open(path: link.path) else {
            Issue.record("a symlinked text file did not open as editable")
            return
        }
        #expect(text == "through the link\n")
        #expect(stamp.size == 17, "the stamp measured the link (\(stamp.size)B), not the file")
        #expect(EditorFileStore.divergence(atPath: link.path, from: stamp) == nil)

        try EditorFileStore.write("written through it\n", toPath: link.path)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "written through it\n")
        // The link is still a link — the save went through it rather than replacing it.
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink, "the save replaced the symlink with a regular file")
    }

    // MARK: Encodings

    /// **A file is written back in the encoding it was read in.**
    ///
    /// The reader decodes six, and the writer spoke only UTF-8 — so a UTF-16 note opened and saved
    /// came back as a different file to everything that produced it: same characters, different
    /// bytes, and a byte-order mark either gained or lost. It still opened here, which is what made
    /// it the kind of defect nobody notices until another tool reads the file.
    /// **Driven off `TextEncoding.allCases`, not a hand-typed list.** It was three literals —
    /// UTF-16 both ways and UTF-8-with-a-BOM — while the reader decodes six, so `encode`'s two
    /// UTF-32 arms, the two with a four-byte mark written by hand, were never executed by anything.
    /// They are reachable: `bom(of:)` matches the UTF-32 marks BEFORE the NUL sniff, so a UTF-32
    /// file really does open editable and really does route through those arms on save. Deriving
    /// the arguments makes a seventh encoding a compile error rather than a silent escape.
    @Test(arguments: BoundedTextRead.TextEncoding.allCases)
    func aFileIsSavedInTheEncodingItWasOpenedIn(named encodingCase: BoundedTextRead.TextEncoding) throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let body = "hello\n"
        let bom = Self.byteOrderMark(for: encodingCase)
        let encoded = try #require(EditorFileStore.encode(body, as: encodingCase),
                                   "\(encodingCase.rawValue) could not be encoded at all")
        #expect(Array(encoded.prefix(bom.count)) == bom,
                "\(encodingCase.rawValue) was written without the mark that names it")
        let name = encodingCase.rawValue.replacingOccurrences(of: " ", with: "-") + ".md"
        let path = try write(encoded, named: name, in: folder)

        guard case .editable(let text, _, let encoding) = EditorFileStore.open(path: path) else {
            Issue.record("\(name) did not open as editable")
            return
        }
        #expect(text == body, "the text itself did not survive the read")
        #expect(encoding == encodingCase,
                "written as \(encodingCase.rawValue) and read back as \(encoding.rawValue)")
        // Saved untouched, the bytes come back exactly — BOM included.
        try EditorFileStore.write(text, toPath: path, encoding: encoding)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == encoded,
                "\(name) was rewritten in a different encoding")

        // And an edit keeps the encoding rather than falling back to UTF-8.
        try EditorFileStore.write("hello there\n", toPath: path, encoding: encoding)
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(Array(after.prefix(bom.count)) == bom, "the byte-order mark was dropped on save")
        guard case .editable(let reread, _, let sameEncoding) = EditorFileStore.open(path: path) else {
            Issue.record("\(name) could not be reopened after an edit")
            return
        }
        #expect(reread == "hello there\n")
        #expect(sameEncoding == encoding, "the file changed encoding across a save")
    }

    /// The mark each encoding is written with, spelled out here rather than taken from `encode`:
    /// a helper that asked the code under test what the bytes should be would agree with it however
    /// wrong both were.
    static func byteOrderMark(for encoding: BoundedTextRead.TextEncoding) -> [UInt8] {
        switch encoding {
        case .utf8: return []
        case .utf8WithBOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: return [0xFF, 0xFE]
        case .utf16BigEndian: return [0xFE, 0xFF]
        case .utf32LittleEndian: return [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BigEndian: return [0x00, 0x00, 0xFE, 0xFF]
        }
    }

    /// The control for the case above: a plain UTF-8 file gains no byte-order mark from any of it.
    @Test func aPlainUTF8FileStaysPlain() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("hello\n".utf8), named: "plain.md", in: folder)

        guard case .editable(_, _, let encoding) = EditorFileStore.open(path: path) else {
            Issue.record("a plain file did not open as editable")
            return
        }
        try EditorFileStore.write("edited\n", toPath: path, encoding: encoding)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("edited\n".utf8),
                "a plain UTF-8 file acquired a byte-order mark")
    }

    // MARK: Names

    @Test func aNameWithNoExtensionBecomesMarkdown() {
        #expect(EditorFileStore.completedName("notes") == "notes.md")
        #expect(EditorFileStore.completedName("  notes  ") == "notes.md")
        #expect(EditorFileStore.completedName("notes.txt") == "notes.txt")
        // A dotfile is a name, not a stem with no extension — appending `.md` to `.gitignore` is
        // the one case where finishing a name would change what was asked for.
        #expect(EditorFileStore.completedName(".gitignore") == ".gitignore")
        #expect(EditorFileStore.completedName("   ") == "")
    }

    @Test func thePrefilledNameSkipsTheNamesAlreadyInTheFolder() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(EditorFileStore.availableUntitledName(in: folder.path) == "Untitled.md")
        _ = try write(Data(), named: "Untitled.md", in: folder)
        #expect(EditorFileStore.availableUntitledName(in: folder.path) == "Untitled 2.md")
        _ = try write(Data(), named: "Untitled 2.md", in: folder)
        #expect(EditorFileStore.availableUntitledName(in: folder.path) == "Untitled 3.md")
    }

    @Test func aNameThatCannotBecomeAFileSaysWhy() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try write(Data("x".utf8), named: "taken.md", in: folder)

        #expect(EditorFileStore.refusal(forName: "fresh", in: folder.path) == nil)
        #expect(EditorFileStore.refusal(forName: "", in: folder.path) != nil)
        #expect(EditorFileStore.refusal(forName: "taken", in: folder.path) != nil,
                "the collision check runs on the COMPLETED name — `taken` becomes `taken.md`")
        #expect(EditorFileStore.refusal(forName: "taken.md", in: folder.path) != nil)
        #expect(EditorFileStore.refusal(forName: "a/b", in: folder.path) != nil)
        // Both halves of the clamp, because a guard with two names is two rules: dropping either
        // `name != "."` or `name != ".."` leaves the other passing and the suite green.
        #expect(EditorFileStore.refusal(forName: "..", in: folder.path) != nil)
        #expect(EditorFileStore.refusal(forName: ".", in: folder.path) != nil)
        // A trailing newline survives `.whitespaces` and would land in the file's own name.
        #expect(EditorFileStore.refusal(forName: "pasted\n", in: folder.path) == nil)
        #expect(EditorFileStore.completedName("pasted\n") == "pasted.md")
    }

    /// **A name cannot walk out of the folder it is being created in.**
    ///
    /// `createEmptyFile` checked only for a collision, on the stated convention that the caller had
    /// already asked `refusal` — a convention, not a check, on a `public` function. `completedName`
    /// passes anything starting with a dot through untouched, `..` included, and `write` then
    /// resolves the path with `resolvingSymlinksInPath`, which collapses `..` LEXICALLY even for a
    /// path that does not exist. So `../escape` created a file in the parent folder and handed back
    /// a path the document held as its identity.
    @Test func creatingRefusesANameThatWouldLeaveTheFolder() throws {
        let parent = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for name in ["../escape", "a/b", "..", "."] {
            #expect(throws: EditorFileStore.Failure.self,
                    "“\(name)” was accepted as a file name") {
                _ = try EditorFileStore.createEmptyFile(named: name, in: folder.path)
            }
        }
        let outside = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(outside == ["inner"], "a name escaped the folder and left \(outside) beside it")
    }

    @Test func creatingLeavesAZeroByteFileAtTheCompletedName() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let path = try EditorFileStore.createEmptyFile(named: "meeting", in: folder.path)
        #expect((path as NSString).lastPathComponent == "meeting.md")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).isEmpty)
    }

    /// The window between asking `refusal` and creating: the guard is in `createEmptyFile` too, so
    /// a file that appeared in between is refused rather than truncated.
    @Test func creatingRefusesToOverwriteAFileThatIsAlreadyThere() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try write(Data("mine\n".utf8), named: "taken.md", in: folder)

        #expect(throws: EditorFileStore.Failure.self) {
            _ = try EditorFileStore.createEmptyFile(named: "taken", in: folder.path)
        }
        #expect(try String(contentsOfFile: folder.appendingPathComponent("taken.md").path,
                           encoding: .utf8) == "mine\n")
    }
}
