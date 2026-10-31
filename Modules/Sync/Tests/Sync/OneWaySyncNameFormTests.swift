import Darwin
import Foundation
import Testing
@testable import Sync

/// One-way sync writes every name in the bytes it was listed or typed in: a file copied from
/// iCloud reaches Dropbox under iCloud's spelling, Unicode form included, and a long name that
/// fits iCloud fits Dropbox. `URL` decomposes a name it is built from, and APFS stores the form it
/// is sent, so a name sent through it reached Dropbox as other bytes than iCloud's. Names are read
/// back from `readdir` as bytes: Swift's `==` calls the two forms equal.
@Suite struct OneWaySyncNameFormTests {

    static let composed = "Caf\u{00E9} r\u{00E9}sum\u{00E9}"
    static let decomposed = composed.decomposedStringWithCanonicalMapping

    /// A file at `relative` below `base`, its folders made as needed by `mkdir`, every name in
    /// `relative`'s exact bytes.
    @discardableResult
    func make(_ relative: String, in base: URL, contents: String = "x") -> URL {
        var path = base.path
        let parts = relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            path = (path as NSString).appendingPathComponent(part)
            if index < parts.count - 1 {
                mkdir(path, 0o755)
            } else {
                let fd = open(path, O_CREAT | O_WRONLY, 0o644)
                _ = contents.withCString { write(fd, $0, strlen($0)) }
                close(fd)
            }
        }
        return URL(fileURLWithFileSystemRepresentation: path, isDirectory: false, relativeTo: nil)
    }

    func names(_ folder: URL) -> [[UInt8]] {
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

    func bytes(_ name: String) -> [UInt8] { Array(name.utf8) }

    @Test func aCopyKeepsICloudsBytesForTheFileAndTheFoldersMadeForIt() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let path = "\u{00C5}rsbok/" + Self.composed + ".pdf"
        make(path, in: world.iCloud)
        try world.writer().copy(from: path, to: path, needsDownload: false)
        #expect(names(world.dropbox) == [bytes("\u{00C5}rsbok")])
        #expect(names(world.dropbox.appendingPathComponent("\u{00C5}rsbok")) == [bytes(Self.composed + ".pdf")])
        #expect(world.read(.dropbox, path) == "x")
    }

    /// Kept, not composed: a decomposed iCloud name stays decomposed.
    @Test func aDecomposedNameStaysDecomposed() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        make(Self.decomposed + ".pdf", in: world.iCloud)
        try world.writer().copy(from: Self.decomposed + ".pdf", to: Self.decomposed + ".pdf", needsDownload: false)
        #expect(names(world.dropbox) == [bytes(Self.decomposed + ".pdf")])
    }

    /// 250 precomposed `é` fit APFS's 255 units; decomposed they are 500 and could not be written.
    @Test func aLongNameThatFitsICloudFitsDropbox() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let long = String(repeating: "\u{00E9}", count: 250) + ".pdf"
        make(long, in: world.iCloud)
        try world.writer().copy(from: long, to: long, needsDownload: false)
        #expect(names(world.dropbox) == [bytes(long)])
    }

    @Test func aMoveInsideDropboxLandsTheNameItIsGiven() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        make("old.pdf", in: world.dropbox)
        try world.writer().move(from: "old.pdf", to: "Legal/" + Self.composed + ".pdf")
        #expect(names(world.dropbox) == [bytes("Legal")])
        #expect(names(world.dropbox.appendingPathComponent("Legal")) == [bytes(Self.composed + ".pdf")])
    }

    /// SyncCloud Removed files Dropbox's item under Dropbox's own bytes, and Restore puts it back
    /// in iCloud, folder and all, under them.
    @Test func removedAndRestoredItemsKeepTheirBytes() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let path = Self.composed + "/" + Self.composed + ".pdf"
        make(path, in: world.dropbox)
        // Asked for in the other form: the store files the item under the bytes on disk.
        let item = try world.writer().moveToRemoved(dropboxPath: path.decomposedStringWithCanonicalMapping,
                                                    cause: .deletedInICloud, iCloudPath: path, expected: nil)
        let day = world.account.appendingPathComponent("SyncCloud Removed/2026-10-30/Documents")
        #expect(names(day) == [bytes(Self.composed)])
        #expect(names(day.appendingPathComponent(Self.composed)) == [bytes(Self.composed + ".pdf")])

        let store = OneWaySyncRemovedStore(accountFolder: world.account, calendar: OneWayDiskWorld.calendar)
        _ = try store.restoreToICloud(item, iCloudParent: world.iCloud, staging: world.staging, deadline: 10)
        #expect(names(world.iCloud) == [bytes(Self.composed)])
        #expect(names(world.iCloud.appendingPathComponent(Self.composed)) == [bytes(Self.composed + ".pdf")])
    }

    /// A second restore keeps both, numbered — in the name's own bytes.
    @Test func aNumberedNameKeepsItsBytes() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let path = Self.composed + ".pdf"
        make(path, in: world.dropbox)
        let item = try world.writer().moveToRemoved(dropboxPath: path, cause: .deletedInICloud, iCloudPath: path, expected: nil)
        make(path, in: world.iCloud, contents: "a new one in iCloud")
        let store = OneWaySyncRemovedStore(accountFolder: world.account, calendar: OneWayDiskWorld.calendar)
        _ = try store.restoreToICloud(item, iCloudParent: world.iCloud, staging: world.staging, deadline: 10)
        #expect(names(world.iCloud) == [bytes(Self.composed + " 2.pdf"), bytes(Self.composed + ".pdf")])
    }

    /// *Rename iCloud's…* writes the name as it was typed.
    @Test func aTypedRenameOfICloudsFileLandsAsTyped() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        make("scan.pdf", in: world.iCloud)
        try OneWaySyncAnswers.renameICloudFile("scan.pdf", to: Self.composed + ".pdf", places: world.places, deadline: 10)
        #expect(names(world.iCloud) == [bytes(Self.composed + ".pdf")])
    }
}
