import Testing
import Foundation
@testable import FileExplorer

/// The editor's file layer, against a real temp directory rather than a fake `FileManaging`: the
/// claims are about what ends up on disk (bytes preserved, a temp file swept, a stamp that notices
/// a change), which a fake would pass whatever the real `replaceItem` did.
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

    // MARK: - A version that arrives in the save's window is kept (FR48)

    /// The caller checks the file, then the store encodes, stages and flushes before the swap. A
    /// newer version installed in that window (here, before the call, against the stamp the
    /// document still holds) must not become the swap's backup and be deleted: it is kept beside
    /// the file, and the save says so.
    @Test func aVersionThatArrivedBeforeTheSwapIsKept() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("opened".utf8), named: "note.md", in: folder)
        let opened = try #require(EditorFileStore.stamp(ofPath: path))
        // Another Mac's version lands: a new file, so a new inode and a new size.
        let other = folder.appendingPathComponent(".incoming")
        try Data("written on the other Mac".utf8).write(to: other)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: other)

        #expect {
            try EditorFileStore.write("typed here", toPath: path, encoding: .utf8, expected: opened)
        } throws: { error in
            (error as? EditorFileStore.Failure)?.savedBut?.contains("note (other version).md") == true
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "typed here")
        let kept = folder.appendingPathComponent("note (other version).md").path
        #expect((try? String(contentsOfFile: kept, encoding: .utf8)) == "written on the other Mac")
    }

    /// A save that kept another version aside is still a checked save: the document reads saved,
    /// not left owing a check (which would stop autosave). Staged as Keep Mine against the version
    /// the question showed (B) with a newer one (C) landed since, which must be kept, not deleted.
    @MainActor
    @Test func keepingAVersionAsideIsASaveNotAnUncheckedOne() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("opened".utf8), named: "note.md", in: folder)
        let document = EditorDocument()
        EditorFileStore.load(path: path, into: document)
        document.text = "mine"
        // B arrives and is the version the question is put about…
        let b = folder.appendingPathComponent(".b")
        try Data("version B".utf8).write(to: b)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: b)
        let seen = try #require(EditorFileStore.stamp(ofPath: path))
        // …and C lands while it is on screen.
        let c = folder.appendingPathComponent(".c")
        try Data("version C, newer".utf8).write(to: c)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: c)

        var thrown: Error?
        do { _ = try EditorFileStore.write(document, consentedTo: seen) } catch { thrown = error }

        let failure = try #require(thrown as? EditorFileStore.Failure, "C was replaced without a word")
        #expect(failure.savedBut?.contains("kept beside it as “note (other version).md”") == true,
                "\(failure.message)")
        #expect(failure.landed == EditorFileStore.stamp(ofPath: path), "the checked stamp was not carried")
        #expect(EditorAutosave.Outcome.of(failure) == .wroteKeepingAside(failure.savedBut ?? ""),
                "a checked save is reported as an unchecked one")
        #expect(!document.isDirty, "the document is not marked saved")
        #expect(document.stamp == EditorFileStore.stamp(ofPath: path))
        #expect(document.uncheckedWrite == nil, "a checked save is left owing a check")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "mine")
        let kept = folder.appendingPathComponent("note (other version).md").path
        #expect((try? String(contentsOfFile: kept, encoding: .utf8)) == "version C, newer",
                "the version that arrived during the question was not kept")
    }

    /// Keep Mine: the user agreed to replace the version on disk and the write names it, so it is
    /// replaced as asked, not kept aside as one that arrived unasked.
    @Test func keepMineReplacesTheVersionItWasAskedAbout() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("opened".utf8), named: "note.md", in: folder)
        let other = folder.appendingPathComponent(".incoming")
        try Data("written on the other Mac".utf8).write(to: other)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: other)
        let consented = try #require(EditorFileStore.stamp(ofPath: path))

        _ = try EditorFileStore.write("mine", toPath: path, encoding: .utf8, expected: consented)

        let visible = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        #expect(visible == ["note.md"])
    }

    /// The ordinary save: the backup is the version the buffer was written against, and goes.
    @Test func anOrdinarySaveKeepsNothingBeside() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("opened".utf8), named: "note.md", in: folder)
        let opened = try #require(EditorFileStore.stamp(ofPath: path))

        let first = try EditorFileStore.write("one", toPath: path, encoding: .utf8, expected: opened)
        // A second write still carrying the old stamp, as a ⌘S behind an uncommitted autosave. What
        // it displaces is this store's own write, not somebody else's.
        _ = try EditorFileStore.write("two", toPath: path, encoding: .utf8, expected: opened)
        _ = try EditorFileStore.write("three", toPath: path, encoding: .utf8, expected: first)

        let visible = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        #expect(visible == ["note.md"])
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "three")
    }

    // MARK: A failed save says why, not where (TE175)

    /// A full disk, as Foundation reports it (a Cocoa error over the POSIX one), reads as the POSIX
    /// reason alone.
    @Test func aFullDiskReadsAsItsPlainReason() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                            userInfo: [NSUnderlyingErrorKey: posix,
                                       NSFilePathErrorKey: "/tmp/.tmp_0D1E5C2A-0000-0000-0000-000000000000"])
        #expect(EditorFileStore.stagingFailure(cocoa).message == "No space left on device")
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

    /// The claim behind the `lines()` warning in `open`: `BoundedTextRead.lines` normalises CRLF to
    /// LF, right for a diff and wrong here. A CRLF file opened and saved untouched must come back
    /// byte for byte, or the first ⌘S rewrites every line ending.
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

    /// A lossy decode opens read-only and carries the reason: saving it back would write U+FFFD
    /// over every byte the decoder couldn't read.
    @Test func aLossyDecodeOpensReadOnly() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Valid text, then one byte that is neither valid UTF-8 nor a NUL (a NUL would make the
        // sniff call it binary, a different refusal).
        var bytes = Data("caf".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Array("\n".utf8))
        let path = try write(bytes, named: "lossy.txt", in: folder)

        guard case .readOnly(let text, let reason, _) = EditorFileStore.open(path: path) else {
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
        // Edit's own words, not Compare's "the preview shows it properly".
        #expect(reason == "This isn’t a text file, so Edit can’t open it.")
        #expect(reason != BoundedTextRead.Outcome.binary.caption, "Edit says Compare's sentence again")
    }

    /// A file past the read cap is refused in Edit's words (what it is, and what Edit opens), not
    /// "Too large to diff". Compare's caption is unchanged.
    @Test func aFileTooLargeToOpenIsRefusedInEditsWords() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data(count: BoundedTextRead.maxBytes + 1), named: "huge.md", in: folder)
        guard case .refused(let reason) = EditorFileStore.open(path: path) else {
            Issue.record("a file past the cap was opened")
            return
        }
        #expect(reason == "Too large to open in Edit — 4.2 MB, and Edit opens text files up to 4.2 MB.")
        #expect(BoundedTextRead.Outcome.tooLarge(bytes: BoundedTextRead.maxBytes + 1).caption?
                    .hasPrefix("Too large to diff") == true, "Compare lost its own wording")
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
        // A different length, so the check doesn't depend on timestamp resolution: mtime alone can
        // miss two writes inside one tick.
        try Data("something longer\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(EditorFileStore.divergence(atPath: path, from: stamp) == .changed)
    }

    /// Missing is a divergence, not the absence of one. An Organize run can file the open document
    /// elsewhere; treating "not there" as "nothing to compare against" would silently recreate it
    /// at the old path and leave two copies.
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

    /// Nothing is left beside the file: the staged `.tmp_` sibling is swept, and the `.rollback_`
    /// backup the atomic replace leaves is deleted, not kept, so ⌘S doesn't add a Trash entry each
    /// time as `FileOperations` would.
    @Test func writingLeavesNoTemporaryOrBackupSiblings() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("old\n".utf8), named: "a.md", in: folder)

        try EditorFileStore.write("new\n", toPath: path)
        try EditorFileStore.write("newer\n", toPath: path)

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["a.md"], "the folder holds \(left) after two saves")
    }

    /// A save keeps the file's own permissions and creation date. The staged file is new (0644,
    /// born now), and the swap takes the original's metadata, so an executable script stays
    /// executable through ⌘S. A sync's Replace takes the incoming item's instead
    /// (`FileManaging.installReplacement`); this pins that the editor doesn't use it.
    @Test func aSaveKeepsTheFilesOwnPermissionsAndCreationDate() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("#!/bin/sh\necho old\n".utf8), named: "run.sh", in: folder)
        let born = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .creationDate: born], ofItemAtPath: path)

        try EditorFileStore.write("#!/bin/sh\necho new\n", toPath: path)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "#!/bin/sh\necho new\n")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755,
                "the save dropped the script's executable bit")
        let creation = try #require(attributes[.creationDate] as? Date)
        #expect(abs(creation.timeIntervalSince(born)) < 1, "the save gave the file a new creation date")
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

    /// A save that can't be staged leaves the old file exactly as it was, and the `defer` sweep
    /// leaves no debris. A read-only directory makes the staging write throw while the destination
    /// stays readable.
    @Test func aStagingFailureLeavesTheOriginalFileAndNoDebris() throws {
        let folder = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let path = try write(Data("original\n".utf8), named: "a.md", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        do {
            _ = try EditorFileStore.write("replacement\n", toPath: path)
            Issue.record("wrote into a folder that cannot be written to")
        } catch let failure as EditorFileStore.Failure {
            // It says why, never the hidden staging file (TE175): Foundation's sentence names
            // `.tmp_<UUID>`, which the reader can't find.
            #expect(!failure.message.contains(".tmp_"), "\(failure.message)")
            #expect(failure.message == "Permission denied", "\(failure.message)")
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "original\n",
                "a failed save rewrote the file it could not stage a replacement for")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["a.md"], "a failed save left \(left) behind")
    }

    /// A save never writes over a directory, which would destroy data, not just lose an edit.
    /// `replaceItemAt` succeeds on a directory: it moves the tree aside as the backup, and the
    /// backup delete then unlinks it and everything inside, permanently, with no Trash entry.
    /// `open` refuses a directory, but a path can become one before the save, and `divergence`
    /// reports that as an ordinary `.changed`.
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

    /// The stamp notices a replacement that kept both size and timestamp. `cp -p`, `rsync -t`, Time
    /// Machine and "Revert to previous version" restore content and mtime together, so a
    /// same-length edit moves neither. The inode does, because every atomic writer here installs a
    /// new file.
    @Test func aReplacementThatKeepsBothSizeAndTimeIsStillADivergence() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try write(Data("2026-08-30\n".utf8), named: "note.md", in: folder)
        // A whole-second timestamp on both sides: a `Date` round-trip doesn't reproduce the
        // filesystem's sub-second precision, so the mtimes would differ by nanoseconds and the
        // check would catch that instead of the inode.
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

    /// A file reached through a symlink opens and saves the file, not the link. The read follows a
    /// link, the stat doesn't and `replaceItemAt` refuses one, so all three go through
    /// `resolved(_:)` first.
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
        // The link is still a link: the save went through it rather than replacing it.
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink, "the save replaced the symlink with a regular file")
    }

    // MARK: Encodings

    /// A file is written back in the encoding it was read in, byte-order mark and all; otherwise a
    /// UTF-16 note saved here would be a different file to every other tool. Driven off
    /// `TextEncoding.allCases`, so every arm of `encode` runs (UTF-32 is reachable: `bom(of:)`
    /// matches its marks before the NUL sniff) and a new encoding can't escape the test.
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
        // Saved untouched, the bytes come back exactly, BOM included. `write` re-stats what it
        // installed against the length it handed over, so a check that forgot the BOM would refuse
        // every UTF-16 save.
        let stamp = try EditorFileStore.write(text, toPath: path, encoding: encoding)
        #expect(stamp.size == encoded.count,
                "\(encodingCase.rawValue): the stamp reports \(stamp.size)B for \(encoded.count)B written")
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

    /// The mark each encoding is written with, spelled out rather than taken from `encode`, which
    /// would agree with itself however wrong.
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
        // A dotfile is a name, not a stem with no extension: appending `.md` to `.gitignore` would
        // change what was asked for.
        #expect(EditorFileStore.completedName(".gitignore") == ".gitignore")
        #expect(EditorFileStore.completedName("   ") == "")
    }

    /// A dot in a name is not an extension unless Edit opens files that end in it, so "Notes v1.2"
    /// gets its `.md` and a Preview. A known text extension, in any case, is kept. Testing
    /// `pathExtension.isEmpty` instead fails the first three.
    @Test func aDotInANameIsNotAnExtensionUnlessEditOpensIt() {
        #expect(EditorFileStore.completedName("Notes v1.2") == "Notes v1.2.md")
        #expect(EditorFileStore.completedName("2026.10.20 standup") == "2026.10.20 standup.md")
        #expect(EditorFileStore.completedName("Q3.final") == "Q3.final.md")
        #expect(EditorFileStore.completedName("config.yaml") == "config.yaml")
        #expect(EditorFileStore.completedName("README.MD") == "README.MD", "a capital extension was not recognised")
        #expect(EditorFileStore.completedName("notes.markdown") == "notes.markdown")
        // And every name it completes is one Edit opens, which is the point of the rule.
        for typed in ["Notes v1.2", "Q3.final", "photo.png", "notes.txt", "plan"] {
            #expect(EditableText.isText(path: "/f/" + EditorFileStore.completedName(typed)),
                    "“\(typed)” would make a file Edit does not open")
        }
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
        // Both halves of the clamp, since dropping either `name != "."` or `name != ".."` would
        // leave the other passing.
        #expect(EditorFileStore.refusal(forName: "..", in: folder.path) != nil)
        #expect(EditorFileStore.refusal(forName: ".", in: folder.path) != nil)
        // A trailing newline survives `.whitespaces` and would land in the file's own name.
        #expect(EditorFileStore.refusal(forName: "pasted\n", in: folder.path) == nil)
        #expect(EditorFileStore.completedName("pasted\n") == "pasted.md")
    }

    /// A name can't walk out of the folder it is created in. `createEmptyFile` is `public`, so it
    /// checks itself rather than trusting the caller to ask `refusal`: `completedName` passes `..`
    /// through, and `resolvingSymlinksInPath` collapses `..` lexically even for a path that doesn't
    /// exist, so `../escape` would land in the parent folder.
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
