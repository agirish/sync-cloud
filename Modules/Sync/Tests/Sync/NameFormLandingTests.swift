import Testing
import Foundation
@testable import Sync

/// A copy or move keeps its original's name byte for byte — the Unicode form included — and a
/// long name that fits as the original spells it is never pushed past APFS's limit by the copy.
///
/// Every Foundation create, move and copy writes a name decomposed (NFD), whatever form it was
/// handed; APFS stores what it is sent and counts its 255-unit limit in that form. These run the
/// real primitives on a real folder and read the landed names back from `readdir`, as bytes:
/// Swift's `==` calls the two forms equal, so only the bytes can tell (see
/// `swift-string-keys-collide-nfc-nfd`). Fixtures are made with `open`/`mkdir`, which keep the
/// form given.
@Suite struct NameFormLandingTests {

    private static let composed = "Caf\u{00E9} r\u{00E9}sum\u{00E9}"        // NFC, as iOS and the keyboard make it
    private static let decomposed = composed.decomposedStringWithCanonicalMapping

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("NameFormLanding-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Makes a file or folder under `folder` named with `name`'s exact bytes.
    private func make(_ name: String, in folder: URL, folder isFolder: Bool = false) -> URL {
        let path = (folder.path as NSString).appendingPathComponent(name)
        if isFolder {
            #expect(mkdir(path, 0o755) == 0)
        } else {
            let fd = open(path, O_CREAT | O_WRONLY, 0o644)
            #expect(fd >= 0)
            _ = "x".withCString { write(fd, $0, 1) }
            close(fd)
        }
        return folder.appendingPathComponent(name)
    }

    /// The bytes of every name in `folder`, as `readdir` reports them, dot entries and staging
    /// leftovers left out.
    private func namesOnDisk(_ folder: URL) -> [[UInt8]] {
        guard let dir = opendir(folder.path) else { return [] }
        defer { closedir(dir) }
        var names: [[UInt8]] = []
        while let entry = readdir(dir) {
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(Int(entry.pointee.d_namlen))) }
            if bytes.first == UInt8(ascii: ".") { continue }
            names.append(bytes)
        }
        return names.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private func bytes(_ name: String) -> [UInt8] { Array(name.utf8) }

    // MARK: - Copies and moves keep the original's form

    @Test func aCopyOfAnNFCFileLandsNFC() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let source = make(Self.composed + ".txt", in: src)
        // Named the way every caller names it: through URL, which decomposes.
        try FileSyncManager.safeCopyItem(at: source, to: dst.appendingPathComponent(Self.composed + ".txt"))
        #expect(namesOnDisk(dst) == [bytes(Self.composed + ".txt")])
        #expect(namesOnDisk(src) == [bytes(Self.composed + ".txt")])
    }

    /// Kept, not composed: an NFD original stays NFD, so the rule is "the original's bytes", not
    /// "always NFC".
    @Test func aCopyOfAnNFDFileLandsNFD() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let source = make(Self.decomposed + ".txt", in: src)
        try FileSyncManager.safeCopyItem(at: source, to: dst.appendingPathComponent(Self.composed + ".txt"))
        #expect(namesOnDisk(dst) == [bytes(Self.decomposed + ".txt")])
    }

    @Test func aCopiedFolderKeepsItsNameAndItsChildrens() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let folder = make(Self.composed, in: src, folder: true)
        _ = make("\u{00E9}t\u{00E9}.txt", in: folder)
        try FileSyncManager.safeCopyItem(at: folder, to: dst.appendingPathComponent(Self.composed))
        #expect(namesOnDisk(dst) == [bytes(Self.composed)])
        #expect(namesOnDisk(dst.appendingPathComponent(Self.composed)) == [bytes("\u{00E9}t\u{00E9}.txt")])
    }

    @Test func aMoveOfAnNFCFileLandsNFC() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let source = make(Self.composed + ".txt", in: src)
        try FileSyncManager.safeMoveItem(at: source, to: dst.appendingPathComponent(Self.composed + ".txt"))
        #expect(namesOnDisk(dst) == [bytes(Self.composed + ".txt")])
        #expect(namesOnDisk(src).isEmpty)
    }

    /// The staged path a move to another volume takes — a copy into `.tmp_`, a rename into place,
    /// the original to the Trash — forced on one volume.
    @Test func aStagedMoveOfAnNFCFileLandsNFC() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let source = make(Self.composed + ".txt", in: src)
        // A real disk whose Trash is the test's own: the staged move trashes the original.
        try FileSyncManager.safeMoveItem(at: source, to: dst.appendingPathComponent(Self.composed + ".txt"),
                                         fileManager: ScratchTrash(in: base), caseSensitiveVolume: false,
                                         crossVolume: true)
        #expect(namesOnDisk(dst) == [bytes(Self.composed + ".txt")])
    }

    /// The source addressed through a decomposed URL — how a path read back from a stored string
    /// reaches the primitives — still lends its on-disk bytes.
    @Test func theOriginalsBytesAreReadOffTheDiskNotOffItsURL() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        _ = make(Self.composed + ".txt", in: src)
        let viaString = URL(fileURLWithPath: src.path + "/" + Self.composed + ".txt")
        #expect(Array(viaString.lastPathComponent.utf8) != bytes(Self.composed + ".txt"))
        try FileSyncManager.safeCopyItem(at: viaString, to: dst.appendingPathComponent(Self.composed + ".txt"))
        #expect(namesOnDisk(dst) == [bytes(Self.composed + ".txt")])
    }

    // MARK: - A new name lands as Foundation writes it, as Finder's typed names do

    @Test func aRenameToANewNameLandsAsBefore() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = make(Self.composed + ".txt", in: base)
        try FileSyncManager.safeMoveItem(at: source, to: base.appendingPathComponent("Na\u{00EF}ve.txt"))
        #expect(namesOnDisk(base) == [bytes("Nai\u{0308}ve.txt")])
    }

    // MARK: - APFS's limit counts the form written

    /// 250 precomposed `é` fit APFS's 255 UTF-16 units; decomposed they are 500 and do not.
    /// Finder copies such a name; `moveItem` could not land it.
    @Test func aLongNFCNameStillCopiesAndMoves() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let long = String(repeating: "\u{00E9}", count: 250) + ".txt"
        #expect(long.utf16.count == 254 && long.decomposedStringWithCanonicalMapping.utf16.count == 504)
        let source = make(long, in: src)
        try FileSyncManager.safeCopyItem(at: source, to: dst.appendingPathComponent(long))
        #expect(namesOnDisk(dst) == [bytes(long)])
        let moved = make("moved", in: base, folder: true)
        try FileSyncManager.safeMoveItem(at: source, to: moved.appendingPathComponent(long))
        #expect(namesOnDisk(moved) == [bytes(long)])
    }

    // MARK: - Folders a sync rebuilds take the source's names

    @Test func foldersMadeForASyncTakeTheSourceFoldersNames() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let outer = make(Self.composed, in: src, folder: true)
        let inner = make("\u{00C5}rsbok", in: outer, folder: true)          // Å, NFC
        let file = make("plain.txt", in: inner)
        let target = dst.appendingPathComponent(Self.composed).appendingPathComponent("\u{00C5}rsbok")
            .appendingPathComponent("plain.txt")
        _ = try FileSyncManager.performFileSyncIO(from: file, to: target, isMove: false)
        #expect(namesOnDisk(dst) == [bytes(Self.composed)])
        #expect(namesOnDisk(dst.appendingPathComponent(Self.composed)) == [bytes("\u{00C5}rsbok")])
        #expect(namesOnDisk(target.deletingLastPathComponent()) == [bytes("plain.txt")])
    }

    /// A cross-pane copy re-roots the item's folders under the other pane's root, and builds them
    /// as a sync does.
    @MainActor
    @Test func aCrossPaneCopyMakesItsFoldersWithTheSourceFoldersNames() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let file = make("plain.txt", in: make("\u{00C5}rsbok", in: make(Self.composed, in: src, folder: true), folder: true))
        let manager = FileSyncManager()
        manager.transferConfirmer = { _ in true }
        await manager.copyItems(nodes: [FileNode(id: file.path, name: "plain.txt", isDirectory: false)],
                                fromLeft: true, leftRoot: src.path, rightRoot: dst.path, fileManager: ScratchTrash(in: base))
        #expect(namesOnDisk(dst) == [bytes(Self.composed)])
        #expect(namesOnDisk(dst.appendingPathComponent(Self.composed)) == [bytes("\u{00C5}rsbok")])
    }

    /// One row's Sync builds the missing folders on the far side the same way.
    @MainActor
    @Test func aSingleRowSyncMakesItsFoldersWithTheSourceFoldersNames() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let file = make("plain.txt", in: make("\u{00C5}rsbok", in: make(Self.composed, in: src, folder: true), folder: true))
        let relative = Self.composed + "/\u{00C5}rsbok/plain.txt"
        let difference = FileDifference(relativePath: relative, leftItemPath: file.path,
                                        rightItemPath: dst.path + "/" + relative, type: .missingOnRight,
                                        action: .copyToRight, description: "test")
        let manager = FileSyncManager()
        let ran = await manager.syncFile(difference, fileManager: ScratchTrash(in: base), confirmed: true)
        try #require(ran)
        #expect(namesOnDisk(dst) == [bytes(Self.composed)])
        #expect(namesOnDisk(dst.appendingPathComponent(Self.composed)) == [bytes("\u{00C5}rsbok")])
    }

    /// Only a folder whose name matches its counterpart's borrows it: a sync into a differently
    /// named folder makes that folder as `createDirectory` does.
    @Test func aFolderWithNoMatchingCounterpartIsMadeAsBefore() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = make("src", in: base, folder: true), dst = make("dst", in: base, folder: true)
        let outer = make(Self.composed, in: src, folder: true)
        let file = make("plain.txt", in: outer)
        let target = dst.appendingPathComponent("\u{00C5}rsbok").appendingPathComponent(Self.composed)
            .appendingPathComponent("plain.txt")
        _ = try FileSyncManager.performFileSyncIO(from: file, to: target, isMove: false)
        #expect(namesOnDisk(dst) == [bytes("A\u{030A}rsbok")])
        #expect(namesOnDisk(dst.appendingPathComponent("\u{00C5}rsbok")) == [bytes(Self.composed)])
    }
}
