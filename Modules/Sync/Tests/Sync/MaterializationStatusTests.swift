import Testing
import Foundation
@testable import Sync

/// Coverage for the cloud-only (dataless) detection: the `SF_DATALESS` flag math and the safe
/// false-cases of the lstat path.
@Suite struct MaterializationStatusTests {

    /// Of all 32 `st_flags` bits, only bit 30 (`SF_DATALESS`, 0x4000_0000) may read as dataless. A
    /// mask typo, a shift slip or a signed-shift artifact on bit 31 flips one cell of this table.
    @Test func onlyTheDatalessBitReadsAsDataless() {
        for bit in 0..<32 {
            let flag = UInt32(1) << UInt32(bit)
            #expect(MaterializationStatus.isDataless(flags: flag) == (bit == 30),
                    "bit \(bit) (\(String(flag, radix: 16)))")
        }
        // No flags is not dataless; all bits set is; all bits EXCEPT 30 set is not.
        #expect(MaterializationStatus.isDataless(flags: 0) == false)
        #expect(MaterializationStatus.isDataless(flags: .max) == true)
        #expect(MaterializationStatus.isDataless(flags: ~UInt32(0x4000_0000)) == false)
    }

    /// A path that can't be statted has no answer, which differs from "not a placeholder":
    /// otherwise a file deleted mid-download reads as materialized to `CloudDownloadPoll`. Every
    /// other caller is deciding whether to read a file, so `isCloudOnly` folds nil to false.
    @Test func anUnstattablePathHasNoAnswer() {
        let gone = "/never-existed-\(UUID().uuidString)/file.bin"
        #expect(MaterializationStatus.isCloudOnlyIfKnown(atPath: gone) == nil)
        #expect(MaterializationStatus.isCloudOnly(atPath: gone) == false)
    }

    /// A file that is there answers definitely: false, since nothing a test can create carries
    /// `SF_DATALESS` (`chflags` refuses it to anyone but root).
    @Test func aLocalFileAnswersDefinitely() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MaterializationStatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("local.bin")
        try Data("x".utf8).write(to: file)

        #expect(MaterializationStatus.isCloudOnlyIfKnown(atPath: file.path) == false)
        #expect(MaterializationStatus.isCloudOnly(atPath: file.path) == false)
    }

    // MARK: linkTarget — the file a door asks about (TE206)

    /// The inode `lstat` reports for `path`: the link's own for a link, so "is this the file" can't
    /// be satisfied by a link to it, however either is spelled.
    private static func inode(_ path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// A link answers the file it points to (directly, relatively, and through a chain), and that
    /// file's `lstat` is the one that sees its flags; the link's never can.
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

    /// Every other path comes back exactly as spelled: an ordinary file, one reached through a
    /// folder link higher up (which `lstat` already follows), `realpath`'s spelling, and a path with
    /// nothing there. A door's own comparisons and keys depend on that.
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
        // `realpath`'s spelling: `/private/var/…` where the temporary folder is `/var/…`.
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

    /// A dangling link answers no file, so a door goes on to fail its read rather than read
    /// anything.
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
