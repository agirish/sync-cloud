import Foundation
import Testing
@testable import Sync

/// The model half of folder sources: the persisted record, the name ruleset a folder borrows
/// because it has no rules of its own, and, the one with teeth, what a folder source may claim.
@Suite struct FolderSourceTests {

    // MARK: The record

    /// `abbreviated` folds the home directory back to `~` and leaves paths outside home alone.
    /// NSOpenPanel hands back paths not in their simplest spelling (a trailing slash, sometimes the
    /// `/System/Volumes/Data` firmlink prefix). Unstandardized, one folder stores under two strings
    /// and the duplicate check below never fires.
    @Test(arguments: [
        ((NSHomeDirectory() as NSString).appendingPathComponent("Projects"), "~/Projects"),
        ((NSHomeDirectory() as NSString).appendingPathComponent("Projects/"), "~/Projects"),
        ((NSHomeDirectory() as NSString).appendingPathComponent("Projects/../Projects"), "~/Projects"),
        ("/Volumes/Backup", "/Volumes/Backup"),
    ])
    func abbreviatedFoldsTheHomeDirectoryBackToTilde(path: String, expected: String) {
        #expect(FolderSource.abbreviated(path) == expected)
    }

    /// The default macOS volume is case-insensitive: the two spellings are one folder, and adding
    /// `~/projects` while `~/Projects` is a source must not make a second row for it.
    @Test func sameFolderFoldsCaseAndSpelling() {
        #expect(FolderSource.sameFolder("~/Projects", "~/projects"))
        #expect(FolderSource.sameFolder("~/Projects", (NSHomeDirectory() as NSString).appendingPathComponent("Projects")))
        #expect(FolderSource.sameFolder("~/Projects/", "~/Projects"))
        // Not a prefix match: a prefix test would say `~/Projects2` "already exists" and select
        // `~/Projects`.
        #expect(FolderSource.sameFolder("~/Projects", "~/Projects2") == false)
    }

    /// The home directory's last component is the account's short name, which reads as a person
    /// rather than a place ("father" in a list of sources next to "Dropbox"), so it is "Home folder".
    @Test func defaultDisplayNameIsTheFoldersOwnName() {
        #expect(FolderSource(id: "folder:x", path: "~/Projects").defaultDisplayName == "Projects")
        #expect(FolderSource(id: "folder:x", path: "/Volumes/Backup").defaultDisplayName == "Backup")
        #expect(FolderSource(id: "folder:x", path: "~").defaultDisplayName == "Home folder")
        #expect(FolderSource(id: "folder:x", path: NSHomeDirectory()).defaultDisplayName == "Home folder")
    }

    @Test func newSourcesTakeDistinctPrefixedIds() {
        let a = FolderSource.new(path: "~/Projects")
        let b = FolderSource.new(path: "~/Projects")
        #expect(a.id != b.id)
        #expect(FolderSource.isFolderSourceId(a.id))
        // Discovered accounts are keyed by their CloudStorage folder name, or the literal "iCloud".
        #expect(FolderSource.isFolderSourceId("iCloud") == false)
        #expect(FolderSource.isFolderSourceId("OneDrive-Personal") == false)
        #expect(FolderSource.isFolderSourceId("Dropbox") == false)
    }

    @Test func theRecordRoundTripsThroughJSON() throws {
        let sources = [FolderSource(id: "folder:a", path: "~/Projects"),
                       FolderSource(id: "folder:b", path: "/Volumes/Backup")]
        let data = try JSONEncoder().encode(sources)
        #expect(try JSONDecoder().decode([FolderSource].self, from: data) == sources)
    }

    // MARK: The name ruleset a folder borrows

    @Test func everyCloudTypeAnswersForItself() {
        for type: CloudProvider.ProviderType in [.iCloud, .oneDrive, .dropBox, .googleDrive] {
            #expect(CloudProvider.nameRuleType(for: type, folderRule: .dropBox) == type,
                    "\(type) must keep its own rules regardless of the folder setting")
        }
    }

    @Test func aFolderBorrowsTheUsersChosenRuleset() {
        #expect(CloudProvider.nameRuleType(for: .localFolder, folderRule: .oneDrive) == .oneDrive)
        #expect(CloudProvider.nameRuleType(for: .localFolder, folderRule: .dropBox) == .dropBox)
    }

    /// "Don't check" is `.localFolder` itself, so the substitution is the identity and
    /// `.localFolder` reports no violations. One encoding, no third state.
    @Test func passingLocalFolderAsTheRuleMeansDoNotCheck() {
        #expect(CloudProvider.nameRuleType(for: .localFolder, folderRule: .localFolder) == .localFolder)
        #expect(ProviderNameRules.violation(name: "CON.txt", provider: .localFolder) == nil)
    }

    /// A local volume accepts what a local volume accepts: the honest answer for `.localFolder`,
    /// and why the substitution lives a layer up rather than in here.
    @Test func aFolderItselfRejectsNothing() {
        for name in ["CON.txt", "a:b", "trailing ", "trailing.", "*star*"] {
            #expect(ProviderNameRules.violation(name: name, provider: .localFolder) == nil,
                    "a plain folder stores \(name) perfectly well")
        }
        // And the borrowed ruleset does the rejecting, which is the point of the substitution.
        let borrowed = CloudProvider.nameRuleType(for: .localFolder, folderRule: .oneDrive)
        #expect(ProviderNameRules.violation(name: "CON.txt", provider: borrowed) != nil)
    }

    // MARK: What a folder source may claim

    private func folder(_ path: String) -> CloudProvider {
        CloudProvider(id: FolderSource.idPrefix + path, displayName: "F",
                      imageName: "folder.fill", rootPath: path, type: .localFolder)
    }

    private func dropbox(_ path: String) -> CloudProvider {
        CloudProvider(id: "Dropbox", displayName: "Dropbox", imageName: "dropbox",
                      rootPath: path, type: .dropBox)
    }

    /// A folder source inside a cloud root must not win `inferredType`'s longest-root rule and type
    /// that subtree `.localFolder`, which has no rules: a path-addressed CLI copy into it would stop
    /// skipping the names Dropbox can't store. A claim carries a stricter ruleset onto a path, so
    /// letting a folder claim could only remove a guard.
    @Test func aFolderSourceInsideACloudRootDoesNotStealItsRules() {
        let providers = [dropbox("/Users/u/Library/CloudStorage/Dropbox/Documents"),
                         folder("/Users/u/Library/CloudStorage/Dropbox/Documents/Scans")]
        #expect(CloudProvider.inferredType(
            forPath: "/Users/u/Library/CloudStorage/Dropbox/Documents/Scans/report ",
            among: providers) == .dropBox)
    }

    /// A folder source on its own claims nothing either, so a path under it stays unclaimed.
    @Test func aStandaloneFolderSourceClaimsNothing() {
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Projects/report.txt",
                                           among: [folder("/Users/u/Projects")]) == nil)
    }

    /// `claimRoots` refuses a root at or above a home directory, which covers a folder source at
    /// `~` as well as a provider there. Both arms are asserted, because the folder rule alone would
    /// pass the first even with the home guard deleted.
    @Test func aFolderSourceAtHomeClaimsNothingAndNeitherWouldAProviderThere() {
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Documents/x.txt",
                                           among: [folder("/Users/u")]) == nil)
        let providerAtHome = CloudProvider(id: "p", displayName: "P", imageName: "icloud",
                                           rootPath: "/Users/u", type: .oneDrive)
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Documents/x.txt",
                                           among: [providerAtHome]) == nil)
    }

    /// Overlapping sources stay legitimate: the cloud account still claims its own tree with a
    /// folder source beside it, above it and below it.
    @Test func foldersBesideACloudRootLeaveItsOwnClaimIntact() {
        let providers = [dropbox("/Users/u/Library/CloudStorage/Dropbox/Documents"),
                         folder("/Users/u/Projects"),
                         folder("/Users/u/Library/CloudStorage/Dropbox/Documents/Scans")]
        #expect(CloudProvider.inferredType(
            forPath: "/Users/u/Library/CloudStorage/Dropbox/Documents/a.txt",
            among: providers) == .dropBox)
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Projects/a.txt",
                                           among: providers) == nil)
    }

    @Test func isLocalFolderReportsTheType() {
        #expect(folder("/Users/u/Projects").isLocalFolder)
        #expect(dropbox("/Users/u/Dropbox").isLocalFolder == false)
    }

    // MARK: The claim the whole feature rests on

    /// Nothing downstream changes: the app talks to every source through one `CloudProvider`, and
    /// the only type-gated behaviour in the diff path (the Google Drive date-noise filter) never
    /// triggers. Asserted over real directories: two folder sources produce the same differences as
    /// two cloud accounts. Catches a type-gated branch that drops `.localFolder`, where a source
    /// that scans empty would read as "these folders match".
    @Test func twoFolderSourcesDiffLikeAnyOtherPairOfSources() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FolderSourceDiff-\(UUID().uuidString)")
        let left = root.appendingPathComponent("left")
        let right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "same".write(to: left.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "same".write(to: right.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "only".write(to: left.appendingPathComponent("left-only.txt"), atomically: true, encoding: .utf8)

        /// The same comparison, run with both sides typed however the caller says.
        func differences(as type: CloudProvider.ProviderType) throws -> [FileDifference] {
            func provider(_ url: URL) -> CloudProvider {
                CloudProvider(id: url.lastPathComponent, displayName: url.lastPathComponent,
                              imageName: "folder.fill", rootPath: url.path, type: type)
            }
            return FileDiffEngine.computeDifferences(
                left: provider(left), leftURL: left,
                right: provider(right), rightURL: right,
                leftFilesInfo: try FileDiffEngine.getFilesInDirectory(left),
                rightFilesInfo: try FileDiffEngine.getFilesInDirectory(right)
            )
        }

        /// Everything about a difference except its freshly minted UUID, which could never match
        /// across two runs.
        func shape(_ diffs: [FileDifference]) -> [String] {
            diffs.map { "\($0.relativePath)|\($0.type)|\($0.action)|\($0.description)" }
        }

        let asFolders = try differences(as: .localFolder)
        #expect(asFolders.count == 1,
                "expected the one unmatched file, got \(asFolders.map(\.relativePath))")
        #expect(asFolders.first?.relativePath == "left-only.txt")
        #expect(asFolders.first?.type == .missingOnRight)
        // And identical, field for field, to what a cloud pair produces over the same fixture.
        #expect(shape(asFolders) == shape(try differences(as: .dropBox)))
    }
}

/// What a source over a whole volume is called. A source at `/` (clicking `Macintosh HD` in the
/// sidebar adds one) should read as the volume's name, not `/`, and that name shows in the tab
/// strip, the pane header capsule, ⌘K and Settings ▸ Sources.
@Suite struct FolderSourceVolumeNameTests {

    /// The startup disk takes the volume's name, not its path.
    @Test func theStartupDiskIsNamedForItsVolume() {
        let name = FolderSource.defaultDisplayName(forPath: "/") { path in
            path == "/" ? "Macintosh HD" : nil
        }
        #expect(name == "Macintosh HD")
    }

    /// A volume that won't name itself falls back to the path: unhelpful beats missing, so a
    /// filesystem that declines the resource value costs nothing.
    @Test func aVolumeThatWillNotNameItselfFallsBackToThePath() {
        #expect(FolderSource.defaultDisplayName(forPath: "/") { _ in nil } == "/")
        #expect(FolderSource.defaultDisplayName(forPath: "/") { _ in "" } == "/",
                "an empty volume name is used verbatim, so the source is called nothing at all")
    }

    /// Every other path is unaffected: the lookup must not fire for the ordinary case.
    /// `/Volumes/Backup` already has a real last component and answers from it.
    @Test func aNamedVolumeAndAnOrdinaryFolderDoNotConsultTheVolume() {
        var consulted = 0
        let resolver: (String) -> String? = { _ in consulted += 1; return "WRONG" }
        #expect(FolderSource.defaultDisplayName(forPath: "/Volumes/Backup", volumeName: resolver) == "Backup")
        #expect(FolderSource.defaultDisplayName(forPath: "/Users/u/Projects", volumeName: resolver) == "Projects")
        #expect(consulted == 0, "the volume was consulted \(consulted) times for a path that names itself")
    }

    /// The home folder keeps its own special case: its last component is the account's short name,
    /// which reads as a person rather than a place.
    @Test func theHomeFolderKeepsItsOwnName() {
        #expect(FolderSource.defaultDisplayName(forPath: NSHomeDirectory()) { _ in "WRONG" } == "Home folder")
        #expect(FolderSource.defaultDisplayName(forPath: "~") { _ in "WRONG" } == "Home folder")
    }
}
