import Testing
import Foundation
@testable import Sync

/// Coverage for the cloud-only (dataless) detection: the `SF_DATALESS` flag math and the safe
/// false-cases of the lstat path.
@Suite struct MaterializationStatusTests {

    @Test func datalessFlagMath() {
        #expect(MaterializationStatus.isDataless(flags: 0) == false)
        #expect(MaterializationStatus.isDataless(flags: 0x4000_0000) == true)
        // The dataless bit set alongside other flags still reads as dataless…
        #expect(MaterializationStatus.isDataless(flags: 0x4000_0000 | 0x1) == true)
        // …and an unrelated flag alone does not.
        #expect(MaterializationStatus.isDataless(flags: 0x2000_0000) == false)
    }

    /// Exhaustive single-bit sweep: of all 32 st_flags bits, ONLY bit 30 (SF_DATALESS,
    /// 0x4000_0000) may read as dataless — a mask typo (0x2000_0000, a >>/<< slip, a signed
    /// shift artifact on bit 31) flips exactly one cell of this table.
    @Test func onlyTheDatalessBitReadsAsDataless() {
        for bit in 0..<32 {
            let flag = UInt32(1) << UInt32(bit)
            #expect(MaterializationStatus.isDataless(flags: flag) == (bit == 30),
                    "bit \(bit) (\(String(flag, radix: 16)))")
        }
        // All bits set reads dataless; all bits EXCEPT 30 set does not.
        #expect(MaterializationStatus.isDataless(flags: .max) == true)
        #expect(MaterializationStatus.isDataless(flags: ~UInt32(0x4000_0000)) == false)
    }

    @Test func ordinaryLocalFileIsNotCloudOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mat-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MaterializationStatus.isCloudOnly(atPath: url.path) == false)
    }

    @Test func missingPathIsNotCloudOnly() {
        #expect(MaterializationStatus.isCloudOnly(atPath: "/no/such/file-\(UUID().uuidString)") == false)
    }

    /// A path that cannot be statted has no answer, and that is different from "not a placeholder".
    ///
    /// The two used to be the same `false`, which made a file deleted mid-download read as
    /// materialized to `CloudDownloadPoll`. Every other caller is deciding whether to READ a file
    /// and wants the two-way form, so `isCloudOnly` keeps its contract and folds nil to false.
    @Test func anUnstattablePathHasNoAnswer() {
        let gone = "/never-existed-\(UUID().uuidString)/file.bin"
        #expect(MaterializationStatus.isCloudOnlyIfKnown(atPath: gone) == nil)
        #expect(MaterializationStatus.isCloudOnly(atPath: gone) == false)
    }

    /// And a file that IS there answers definitely — false, since nothing a test can create carries
    /// `SF_DATALESS` (an `SF_` flag `chflags` refuses to anyone but root).
    @Test func aLocalFileAnswersDefinitely() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MaterializationStatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("local.bin")
        try Data("x".utf8).write(to: file)

        #expect(MaterializationStatus.isCloudOnlyIfKnown(atPath: file.path) == false)
    }

    // MARK: linkTarget — the file a door asks about (TE206)

    /// The inode `lstat` reports for `path` — the link's own for a link, so "is this the file"
    /// cannot be satisfied by a link to it, whichever way either is spelled.
    private static func inode(_ path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// **A link answers the file it points to** — directly, relatively, and through a chain — and
    /// that file's `lstat` is the one that sees its flags, where the link's never can.
    @Test func aLinkAnswersTheFileItPointsTo() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LinkTarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("real/sub"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("real/sub/file.pdf").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        let direct = dir.appendingPathComponent("direct.pdf").path
        let relative = dir.appendingPathComponent("relative.pdf").path
        let chain = dir.appendingPathComponent("chain.pdf").path
        try FileManager.default.createSymbolicLink(atPath: direct, withDestinationPath: file)
        try FileManager.default.createSymbolicLink(atPath: relative, withDestinationPath: "real/sub/file.pdf")
        try FileManager.default.createSymbolicLink(atPath: chain, withDestinationPath: "relative.pdf")

        let fileInode = try #require(Self.inode(file))
        for link in [direct, relative, chain] {
            #expect(Self.inode(link) != fileInode, "the fixture's link is the file itself")
            #expect(Self.inode(MaterializationStatus.linkTarget(of: link)) == fileInode,
                    "\((link as NSString).lastPathComponent) answered \(MaterializationStatus.linkTarget(of: link))")
        }
    }

    /// **Every other path comes back exactly as spelled** — an ordinary file, one reached through
    /// a folder link higher up (which `lstat` already follows), `realpath`'s spelling, and a
    /// path with nothing there. A door's own comparisons and keys depend on that.
    @Test func everyOtherPathComesBackAsSpelled() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LinkTarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("real"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("real/file.md").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("folder").path,
                                                   withDestinationPath: dir.appendingPathComponent("real").path)
        let throughFolderLink = dir.appendingPathComponent("folder/file.md").path
        // `realpath`'s spelling — `/private/var/…` where the temporary folder is `/var/…`.
        let raw = try #require(realpath(file, nil))
        defer { free(raw) }
        let privateSpelling = String(cString: raw)
        let gone = dir.appendingPathComponent("gone.md").path

        #expect(FileManager.default.fileExists(atPath: throughFolderLink)
                && FileManager.default.fileExists(atPath: privateSpelling), "the fixture's paths are not there")
        for path in [file, throughFolderLink, privateSpelling, gone] {
            #expect(MaterializationStatus.linkTarget(of: path) == path)
        }
    }

    /// **A dangling link answers no file** — nothing a door can stat as present, so it goes on to
    /// fail its read rather than to read anything.
    @Test func aDanglingLinkAnswersNoFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LinkTarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("dangling.md").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "nowhere.md")
        #expect(!FileManager.default.fileExists(atPath: MaterializationStatus.linkTarget(of: link)))
    }
}
