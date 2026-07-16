import Testing
import Foundation
@testable import Sync

/// Coverage for the pure ``NameNormalizer`` detector (in-memory ``FileNode`` trees, no disk) and one
/// engine-level test that the apply path never overwrites on a name collision.
@Suite struct NameNormalizerTests {

    // MARK: In-memory tree helpers

    private func file(_ id: String, _ name: String) -> FileNode {
        FileNode(id: id, name: name, isDirectory: false, fileSize: 10)
    }
    private func dir(_ id: String, _ name: String, _ children: [FileNode] = []) -> FileNode {
        FileNode(id: id, name: name, isDirectory: true, children: children)
    }

    private func scan(_ nodes: [FileNode], _ provider: CloudProvider.ProviderType) -> [RiskyName] {
        NameNormalizer.scan(nodes: nodes, provider: provider)
    }

    // MARK: OneDrive (strictest ruleset)

    @Test func oneDriveFlagsForbiddenCharacter() {
        let risky = scan([file("/r/a:b.txt", "a:b.txt")], .oneDrive)
        #expect(risky.count == 1)
        #expect(risky[0].currentName == "a:b.txt")
        #expect(risky[0].sanitizedName == "a-b.txt")
        #expect(risky[0].reason.contains("OneDrive"))
        #expect(risky[0].isDirectory == false)
    }

    @Test func oneDriveFlagsTrailingSpace() {
        let risky = scan([file("/r/report ", "report ")], .oneDrive)
        #expect(risky.count == 1)
        #expect(risky[0].sanitizedName == "report")
        #expect(risky[0].reason.contains("space"))
    }

    @Test func oneDriveReservedNameIsSuffixed() {
        // sanitized("CON") de-reserves the BASE component.
        let risky = scan([file("/r/CON", "CON")], .oneDrive)
        #expect(risky.count == 1)
        #expect(risky[0].sanitizedName == "CON-1")
        #expect(risky[0].reason.contains("reserved"))

        // With an extension, the base — not the whole string — is suffixed.
        let withExt = scan([file("/r/CON.txt", "CON.txt")], .oneDrive)
        #expect(withExt.first?.sanitizedName == "CON-1.txt")
    }

    // MARK: Dropbox

    @Test func dropboxFlagsTrailingSpaceAndPeriod() {
        let space = scan([file("/r/notes ", "notes ")], .dropBox)
        #expect(space.first?.sanitizedName == "notes")
        #expect(space.first?.reason.contains("space") == true)

        let period = scan([file("/r/notes.", "notes.")], .dropBox)
        #expect(period.first?.sanitizedName == "notes")
        #expect(period.first?.reason.contains("period") == true)
    }

    @Test func dropboxIgnoresOneDriveOnlyForbiddenCharacters() {
        // A colon is a OneDrive rule, not a Dropbox one — Dropbox leaves it alone.
        #expect(scan([file("/r/a:b.txt", "a:b.txt")], .dropBox).isEmpty)
    }

    // MARK: iCloud — provider rules flag nothing, but invisibles still do

    @Test func iCloudFlagsNothingFromProviderRules() {
        // Colon and a trailing regular space are both fine for iCloud (no provider rule).
        #expect(scan([file("/r/a:b", "a:b")], .iCloud).isEmpty)
        #expect(scan([file("/r/trailing ", "trailing ")], .iCloud).isEmpty)
    }

    @Test func iCloudFlagsZeroWidthCharacters() {
        let name = "he\u{200B}llo.txt"   // zero-width space
        let risky = scan([file("/r/\(name)", name)], .iCloud)
        #expect(risky.count == 1)
        #expect(risky[0].sanitizedName == "hello.txt")
        #expect(risky[0].reason.contains("zero-width"))
    }

    /// A *pure* NFC/NFD difference is NOT flagged, by design. macOS treats the two forms as the same
    /// name (Swift `==` is canonical) and APFS re-normalizes filenames on write, so such a "fix"
    /// can't be stored AND would fire on nearly every accented filename on disk. Only a hazard that
    /// is canonically *distinct* from its fix is worth surfacing.
    @Test func pureNFDDifferenceIsNotFlagged() {
        let nfd = "cafe\u{0301}"   // "café" decomposed (e + combining acute)
        // Sanity: the two forms differ at the scalar level but are canonically equal.
        #expect(Array(nfd.unicodeScalars) != Array("café".precomposedStringWithCanonicalMapping.unicodeScalars))
        #expect(nfd == nfd.precomposedStringWithCanonicalMapping)
        #expect(scan([file("/r/\(nfd)", nfd)], .iCloud).isEmpty)
        #expect(scan([file("/r/\(nfd)", nfd)], .oneDrive).isEmpty)
    }

    /// `sanitize` still normalizes to NFC, so when a name IS flagged for a real hazard its safe
    /// replacement comes out precomposed (NFD café + trailing space → NFC "café").
    @Test func sanitizedReplacementIsNFC() {
        let name = "cafe\u{0301} "   // NFD "café" + trailing space (OneDrive rejects the space)
        let fixed = scan([file("/r/\(name)", name)], .oneDrive).first
        #expect(fixed != nil)
        #expect(Array((fixed?.sanitizedName ?? "").unicodeScalars)
            == Array("café".precomposedStringWithCanonicalMapping.unicodeScalars))
    }

    @Test func iCloudFlagsNonBreakSpace() {
        let name = "a\u{00A0}b"   // interior no-break space — canonically distinct from a plain space
        let risky = scan([file("/r/\(name)", name)], .iCloud)
        #expect(risky.count == 1)
        #expect(risky.first?.sanitizedName == "a b")   // folded to a plain ASCII space
    }

    // MARK: Clean names / gating

    @Test func cleanNameIsNotFlagged() {
        #expect(scan([file("/r/Report 2024.pdf", "Report 2024.pdf")], .oneDrive).isEmpty)
        #expect(scan([file("/r/Report 2024.pdf", "Report 2024.pdf")], .iCloud).isEmpty)
    }

    // MARK: Dir-inclusive walk (folders are flagged too)

    @Test func riskyFolderNameIsFlagged() {
        // A risky folder that also contains a risky file — both surface, folder included.
        let tree = [
            dir("/r/Photos:", "Photos:", [
                file("/r/Photos:/clean.jpg", "clean.jpg"),
                file("/r/Photos:/bad?.jpg", "bad?.jpg"),
            ])
        ]
        let risky = scan(tree, .oneDrive)
        let folder = risky.first { $0.currentName == "Photos:" }
        #expect(folder != nil)
        #expect(folder?.isDirectory == true)
        #expect(folder?.sanitizedName == "Photos-")
        #expect(folder?.relativePath == "Photos:")
        // The clean child is not flagged; the "bad?.jpg" child is.
        #expect(risky.contains { $0.currentName == "bad?.jpg" })
        #expect(!risky.contains { $0.currentName == "clean.jpg" })
        #expect(risky.count == 2)
        // The flagged child carries its relative path under the (still-risky) parent.
        let child = risky.first { $0.currentName == "bad?.jpg" }
        #expect(child?.relativePath == "Photos:/bad?.jpg")
    }

    // MARK: hasInvisibleHazard helper

    @Test func hasInvisibleHazardDetectsFixableHidden() {
        #expect(NameNormalizer.hasInvisibleHazard("plain.txt") == false)
        #expect(NameNormalizer.hasInvisibleHazard("zero\u{200D}width") == true)
        #expect(NameNormalizer.hasInvisibleHazard("no\u{00A0}break") == true)
        // A pure NFC/NFD difference is NOT a fixable hazard on macOS (APFS re-normalizes on write).
        #expect(NameNormalizer.hasInvisibleHazard("cafe\u{0301}") == false)
    }

    // MARK: Engine — never overwrite on collision (keep both)

    private func write(_ url: URL, bytes: Int = 100) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @MainActor
    @Test func normalizeKeepsBothOnCollisionNeverOverwrites() async throws {
        let root = try makeCanonicalTempRoot(prefix: "NameNormTest")
        defer { try? FileManager.default.removeItem(at: root) }

        // A clean file already occupies the safe name; the risky one (a zero-width space) would
        // sanitize onto it. Zero-width names are filesystem-robust (distinct on APFS, not trimmed
        // by URL handling), unlike trailing-space/dot names.
        let cleanURL = root.appendingPathComponent("photo.jpg")
        let riskyURL = root.appendingPathComponent("photo\u{200B}.jpg")
        try write(cleanURL, bytes: 111)
        try write(riskyURL, bytes: 222)

        let manager = FileSyncManager()
        await manager.scanNames(root: root, provider: .iCloud)

        // Only the zero-width name is risky.
        #expect(manager.riskyNames.count == 1)
        let risky = try #require(manager.riskyNames.first)
        #expect(risky.sanitizedName == "photo.jpg")

        await manager.normalizeNames([risky])

        // The original clean file is untouched (never overwritten); the fixed one kept-both.
        #expect(FileManager.default.fileExists(atPath: cleanURL.path))
        let cleanData = try Data(contentsOf: cleanURL)
        #expect(cleanData.count == 111)   // still the ORIGINAL clean file, not clobbered
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("photo 2.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: riskyURL.path))   // renamed away
        #expect(manager.riskyNames.isEmpty)                                // fixed row dropped
        #expect(manager.banner?.severity == .success)
    }
}
