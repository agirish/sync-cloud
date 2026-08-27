import Foundation
import Testing
@testable import Sync

/// The model half of folder sources (roadmap 1a): the persisted record, the name-ruleset
/// substitution a folder needs because it has no rules of its own, and — the one with teeth — what
/// a folder source is allowed to CLAIM.
@Suite struct FolderSourceTests {

    // MARK: The record

    @Test func abbreviatedFoldsTheHomeDirectoryBackToTilde() {
        let inside = (NSHomeDirectory() as NSString).appendingPathComponent("Projects")
        #expect(FolderSource.abbreviated(inside) == "~/Projects")
    }

    /// NSOpenPanel hands back paths that are not in their simplest spelling — a trailing slash,
    /// and on some machines the `/System/Volumes/Data` firmlink prefix. Un-standardized, the same
    /// folder stores under two different strings and the duplicate check below never fires.
    @Test func abbreviatedStandardizesBeforeFolding() {
        let trailing = (NSHomeDirectory() as NSString).appendingPathComponent("Projects/")
        #expect(FolderSource.abbreviated(trailing) == "~/Projects")
        let indirect = (NSHomeDirectory() as NSString).appendingPathComponent("Projects/../Projects")
        #expect(FolderSource.abbreviated(indirect) == "~/Projects")
    }

    @Test func abbreviatedLeavesPathsOutsideHomeAlone() {
        #expect(FolderSource.abbreviated("/Volumes/Backup") == "/Volumes/Backup")
    }

    /// The default macOS volume is case-insensitive: the two spellings are ONE folder, and adding
    /// `~/projects` while `~/Projects` is a source must not make a second row for it.
    @Test func sameFolderFoldsCaseAndSpelling() {
        #expect(FolderSource.sameFolder("~/Projects", "~/projects"))
        #expect(FolderSource.sameFolder("~/Projects", (NSHomeDirectory() as NSString).appendingPathComponent("Projects")))
        #expect(FolderSource.sameFolder("~/Projects/", "~/Projects"))
        #expect(FolderSource.sameFolder("~/Projects", "~/Projects2") == false)
    }

    /// A sibling whose name merely starts with the same characters is a different folder. The
    /// comparison is whole-path equality, not a prefix test — the failure a prefix test produces
    /// here is silent (`~/Projects2` "already exists" and selects `~/Projects` instead).
    @Test func sameFolderIsNotAPrefixMatch() {
        #expect(FolderSource.sameFolder("~/Doc", "~/Documents") == false)
    }

    @Test func defaultDisplayNameIsTheFoldersOwnName() {
        #expect(FolderSource(id: "folder:x", path: "~/Projects").defaultDisplayName == "Projects")
        #expect(FolderSource(id: "folder:x", path: "/Volumes/Backup").defaultDisplayName == "Backup")
    }

    /// The home directory's last component is the account's short name, which reads as a person
    /// rather than a place — "abhishek" sitting in a list of sources next to "Dropbox".
    @Test func defaultDisplayNameNamesTheHomeFolderAsAPlace() {
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

    /// "Don't check" is `.localFolder` itself, which makes the substitution the identity — and
    /// `.localFolder` reports no violations, so nothing is checked. One encoding, no third state.
    @Test func passingLocalFolderAsTheRuleMeansDoNotCheck() {
        #expect(CloudProvider.nameRuleType(for: .localFolder, folderRule: .localFolder) == .localFolder)
        #expect(ProviderNameRules.violation(name: "CON.txt", provider: .localFolder) == nil)
    }

    /// A local volume accepts what a local volume accepts. This is the honest answer for
    /// `.localFolder` and the reason the substitution lives a layer up rather than in here.
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

    /// The one that matters. A folder source added INSIDE a cloud root would win
    /// `inferredType`'s longest-root-wins rule and type that subtree `.localFolder` — and
    /// `.localFolder` has no rules, so a path-addressed CLI copy into it would quietly stop
    /// skipping the names Dropbox cannot store. A claim exists to carry a STRICTER ruleset onto a
    /// path; letting a folder claim can only ever remove a guard.
    @Test func aFolderSourceInsideACloudRootDoesNotStealItsRules() {
        let providers = [dropbox("/Users/u/Library/CloudStorage/Dropbox/Documents"),
                         folder("/Users/u/Library/CloudStorage/Dropbox/Documents/Scans")]
        #expect(CloudProvider.inferredType(
            forPath: "/Users/u/Library/CloudStorage/Dropbox/Documents/Scans/report ",
            among: providers) == .dropBox)
    }

    /// A folder source standing on its own claims nothing either, so a path under it resolves
    /// exactly as it did before folder sources existed: unclaimed.
    @Test func aStandaloneFolderSourceClaimsNothing() {
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Projects/report.txt",
                                           among: [folder("/Users/u/Projects")]) == nil)
    }

    /// The roadmap's pinning test: `claimRoots` already refuses a root at or above a home
    /// directory, written for "user points a PROVIDER at their home folder". A folder source at
    /// `~` is the same shape and is covered by the same guard — worth a test, not new code. Both
    /// arms are asserted because the folder rule alone would pass this even if the home guard were
    /// deleted.
    @Test func aFolderSourceAtHomeClaimsNothingAndNeitherWouldAProviderThere() {
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Documents/x.txt",
                                           among: [folder("/Users/u")]) == nil)
        let providerAtHome = CloudProvider(id: "p", displayName: "P", imageName: "icloud",
                                           rootPath: "/Users/u", type: .oneDrive)
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Documents/x.txt",
                                           among: [providerAtHome]) == nil)
    }

    /// Overlapping sources are legitimate and stay legitimate: the cloud account still claims its
    /// own tree with a folder source sitting beside it, above it, and below it.
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

    /// *Nothing downstream changes.* The roadmap's case for this being low-risk is that the app
    /// talks to every source through one `CloudProvider`, so a fifth type needs no new data path —
    /// and the only type-gated behaviour in the diff path (the Google Drive date-noise filter) is
    /// simply never triggered.
    ///
    /// Asserted rather than assumed, over real directories on disk: two folder sources produce the
    /// same differences the same comparison would produce between two cloud accounts. The failure
    /// this catches is a type-gated branch someone adds later that quietly drops `.localFolder` —
    /// a source that scans EMPTY reads as "these folders match".
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

        /// Everything about a difference EXCEPT its freshly-minted UUID — comparing ids across two
        /// runs could never match, and would make the equality below vacuously true.
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

/// **What a source over a whole volume is called.**
///
/// Reported from the running build on 2026-08-24: clicking `Macintosh HD` in the sidebar added `/`
/// as a folder source, and the tab strip then read `/`. The tab was only where it showed — a tab at
/// a provider root wears the *source's* name — so the pane header capsule, ⌘K and Settings ▸ Sources
/// all had it too.
@Suite struct FolderSourceVolumeNameTests {

    /// The startup disk takes the volume's name, not its path.
    @Test func theStartupDiskIsNamedForItsVolume() {
        let name = FolderSource.defaultDisplayName(forPath: "/") { path in
            path == "/" ? "Macintosh HD" : nil
        }
        #expect(name == "Macintosh HD")
    }

    /// **A volume that will not name itself keeps the old answer.** Unhelpful beats missing, and
    /// this is exactly the behaviour the app had before the lookup existed — so a filesystem that
    /// declines the resource value costs nothing.
    @Test func aVolumeThatWillNotNameItselfFallsBackToThePath() {
        #expect(FolderSource.defaultDisplayName(forPath: "/") { _ in nil } == "/")
        #expect(FolderSource.defaultDisplayName(forPath: "/") { _ in "" } == "/",
                "an empty volume name is used verbatim, so the source is called nothing at all")
    }

    /// **Every other path is unaffected**, and that matters: the lookup must not fire for the
    /// ordinary case. `/Volumes/Backup` already has a real last component and answers from it.
    @Test func aNamedVolumeAndAnOrdinaryFolderDoNotConsultTheVolume() {
        var consulted = 0
        let resolver: (String) -> String? = { _ in consulted += 1; return "WRONG" }
        #expect(FolderSource.defaultDisplayName(forPath: "/Volumes/Backup", volumeName: resolver) == "Backup")
        #expect(FolderSource.defaultDisplayName(forPath: "/Users/u/Projects", volumeName: resolver) == "Projects")
        #expect(consulted == 0, "the volume was consulted \(consulted) times for a path that names itself")
    }

    /// The home folder keeps its own special case, which predates this and is a different problem:
    /// its last component is the account's short name, which reads as a person rather than a place.
    @Test func theHomeFolderKeepsItsOwnName() {
        #expect(FolderSource.defaultDisplayName(forPath: NSHomeDirectory()) { _ in "WRONG" } == "Home folder")
        #expect(FolderSource.defaultDisplayName(forPath: "~") { _ in "WRONG" } == "Home folder")
    }

    /// And the name reaches the tab, which is where it was seen. A tab at a provider root wears the
    /// source's name — the reason one bad name showed up in four places.
    @Test func aTabAtTheRootWearsTheSourcesName() {
        let tab = PaneTab(providerId: "folder-src", relativePath: "")
        #expect(tab.displayName(providerName: "Macintosh HD") == "Macintosh HD")
    }
}
