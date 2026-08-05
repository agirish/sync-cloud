import Testing
import Foundation
@testable import Sync

/// Pins `FileLocation` — the pure containment × materialization classifier behind the Info
/// inspector's *Where it lives* row and the `⌂ on this Mac only` row badge.
///
/// **Every path in here is fabricated and none of them exist.** That is the point, not an
/// economy: the containment half must reach the filesystem nowhere at all (it is asked eagerly,
/// per visible row, where the ☁ badge it mirrors buys each answer with a detached `lstat`), and a
/// fixture built on real files could not tell a pure answer from a statted one. See
/// `containmentNamesNoFilesystemTouchingApi` for the second half of that proof.
struct FileLocationTests {

    // MARK: Fixtures

    /// A discovered provider at its real shape: the configured root is a SUBFOLDER of the
    /// CloudStorage account folder, exactly as `SettingsManager.mapProviders` builds one.
    private static func oneDrive(
        id: String = "OneDrive-Acme",
        name: String = "OneDrive (Acme)"
    ) -> CloudProvider {
        CloudProvider(id: id, displayName: name, imageName: "onedrive",
                      path: "/Users/u/Library/CloudStorage/\(id)/Documents", type: .oneDrive)
    }

    private static func iCloud(name: String = "iCloud") -> CloudProvider {
        CloudProvider(id: "iCloud", displayName: name, imageName: "icloud",
                      path: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs", type: .iCloud)
    }

    private static func folderSource(
        id: String = "folder-1",
        path: String = "/Users/u/Projects"
    ) -> CloudProvider {
        CloudProvider(id: id, displayName: "Projects", imageName: "folder.fill",
                      path: path, type: .localFolder)
    }

    private static func coverage(
        _ providers: [CloudProvider],
        disabled: Set<String> = []
    ) -> FileLocation.Coverage {
        FileLocation.coverage(of: providers, disabledProviderIds: disabled)
    }

    // MARK: Containment — the four ways a path relates to a cloud root

    @Test func aPathInsideAProvidersRootIsCovered() {
        let c = Self.coverage([Self.iCloud()])
        let file = "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/Notes/a.md"
        #expect(FileLocation.covering(path: file, in: c)?.providerId == "iCloud")
        #expect(FileLocation.outsideEveryCloudFolder(path: file, in: c) == false)
    }

    @Test func aPathOutsideEveryProvidersRootIsNotCovered() {
        let c = Self.coverage([Self.iCloud(), Self.oneDrive()])
        let file = "/Users/u/Projects/notes.md"
        #expect(FileLocation.covering(path: file, in: c) == nil)
        #expect(FileLocation.outsideEveryCloudFolder(path: file, in: c))
    }

    /// The boundary rule `PathBoundary` exists for: a sibling sharing only a string prefix is
    /// OUTSIDE. Without it, `~/Projects-old` would be covered by a source rooted at `~/Projects`.
    @Test func aSiblingSharingAStringPrefixIsOutside() {
        let c = Self.coverage([CloudProvider(id: "p", displayName: "P", imageName: "icloud",
                                             path: "/Users/u/Cloud", type: .iCloud)])
        #expect(FileLocation.outsideEveryCloudFolder(path: "/Users/u/Cloudy/a.txt", in: c))
        #expect(FileLocation.outsideEveryCloudFolder(path: "/Users/u/Cloud/a.txt", in: c) == false)
    }

    /// The root itself, not only what is under it.
    @Test func theRootPathIsItselfCovered() {
        let c = Self.coverage([Self.oneDrive()])
        #expect(FileLocation.covering(path: "/Users/u/Library/CloudStorage/OneDrive-Acme/Documents",
                                      in: c) != nil)
    }

    // MARK: The account-folder widening

    /// A file inside the provider's ACCOUNT folder but outside its configured root is still in
    /// that provider. Discovery configures OneDrive at `…/OneDrive-<acct>/Documents`, so a plain
    /// test against the configured root alone stamps "This Mac only" on a file that plainly is in
    /// OneDrive — manufacturing risk that is not there, and putting ⌂ and ☁ on one row at once.
    @Test func aSiblingOfTheConfiguredRootInsideTheAccountFolderIsCovered() {
        let c = Self.coverage([Self.oneDrive()])
        let photo = "/Users/u/Library/CloudStorage/OneDrive-Acme/Photos/a.jpg"
        #expect(FileLocation.covering(path: photo, in: c)?.providerId == "OneDrive-Acme")
        #expect(FileLocation.outsideEveryCloudFolder(path: photo, in: c) == false)
    }

    /// The widening stops at the account folder — a DIFFERENT account under the same
    /// CloudStorage parent is not this provider's ground.
    @Test func aDifferentAccountFolderIsNotCovered() {
        let c = Self.coverage([Self.oneDrive()])
        #expect(FileLocation.outsideEveryCloudFolder(
            path: "/Users/u/Library/CloudStorage/OneDrive-Other/Documents/a.txt", in: c))
        // …and CloudStorage itself is not inside any one account.
        #expect(FileLocation.outsideEveryCloudFolder(
            path: "/Users/u/Library/CloudStorage/readme.txt", in: c))
    }

    /// A provider whose Location was overridden away from CloudStorage contributes only its own
    /// root — there is no account folder to widen to.
    @Test func aRootOutsideCloudStorageWidensToNothing() {
        #expect(FileLocation.coveredPaths(ofRootPath: "/Volumes/Big/Sync") == ["/volumes/big/sync"])
    }

    /// A folder someone happens to have named "CloudStorage" must not anchor the widening.
    @Test func aBareCloudStorageComponentDoesNotAnchorTheWidening() {
        #expect(FileLocation.coveredPaths(ofRootPath: "/Users/u/CloudStorage/Acme/Docs")
                == ["/users/u/cloudstorage/acme/docs"])
    }

    // MARK: The two ROADMAP rules

    /// **Disabled providers still count as coverage.** Their folder is on disk whether or not the
    /// source is switched on, so a file inside one still has a second copy. Mutation seam: make
    /// `FileLocation.coverage` filter on `disabledProviderIds` and this fails.
    @Test func aDisabledProvidersFolderStillCounts() {
        let drive = Self.oneDrive()
        let c = Self.coverage([drive], disabled: [drive.id])
        let file = "/Users/u/Library/CloudStorage/OneDrive-Acme/Documents/a.txt"
        #expect(FileLocation.covering(path: file, in: c)?.providerId == drive.id)
        #expect(FileLocation.verdict(forPath: file, in: c, isCloudOnly: false)
                == .thisMacAndCloud(providerName: "OneDrive (Acme)"))
    }

    /// The same list, enabled, must give the same answer — otherwise the test above could pass
    /// because the fixture never covered anything.
    @Test func theDisabledSetChangesNothingAtAll() {
        let drive = Self.oneDrive()
        #expect(Self.coverage([drive], disabled: [drive.id]) == Self.coverage([drive]))
    }

    /// **A folder source is never coverage** — it is the thing being asked about, not a cloud.
    /// Mutation seam: drop the `isLocalFolder` guard and this fails.
    @Test func aFolderSourceIsNeverCoverage() {
        let c = Self.coverage([Self.folderSource(path: "/Users/u/Projects")])
        #expect(c.roots.isEmpty)
        let file = "/Users/u/Projects/notes.md"
        #expect(FileLocation.outsideEveryCloudFolder(path: file, in: c))
        #expect(FileLocation.verdict(forPath: file, in: c, isCloudOnly: false) == .thisMacOnly)
    }

    /// A folder source added INSIDE a cloud root leaves the cloud truth underneath intact — it
    /// neither adds coverage nor takes any away.
    @Test func aFolderSourceInsideACloudRootDoesNotShadowIt() {
        let inside = "/Users/u/Library/CloudStorage/OneDrive-Acme/Documents/Work"
        let c = Self.coverage([Self.oneDrive(), Self.folderSource(id: "f", path: inside)])
        #expect(FileLocation.covering(path: inside + "/a.txt", in: c)?.providerId == "OneDrive-Acme")
    }

    /// A provider with no resolvable path claims nothing — the empty-root hazard
    /// `PathBoundary.relativize` guards, arriving from a provider dropped from settings while its
    /// stale row is still on screen.
    @Test func aProviderWithNoPathCoversNothing() {
        let ghost = CloudProvider(id: "gone", displayName: "Gone", imageName: "icloud",
                                  path: "", type: .dropBox)
        let c = Self.coverage([ghost])
        #expect(c.roots.isEmpty)
        #expect(FileLocation.outsideEveryCloudFolder(path: "/Users/u/anything.txt", in: c))
    }

    // MARK: Case folding

    /// The two sides have different lineage — a row's path descends from the pane's own root, a
    /// provider's from discovery or a hand-typed override — so they carry no promise of agreeing
    /// on spelling. Folding can only find coverage, never invent absence.
    @Test func containmentFoldsCase() {
        let c = Self.coverage([Self.oneDrive()])
        #expect(FileLocation.covering(
            path: "/users/u/library/cloudstorage/onedrive-acme/DOCUMENTS/A.TXT", in: c) != nil)
    }

    // MARK: Containment × materialization — the full cross

    @Test func insideACloudFolderAndDownloadedIsBoth() {
        let c = Self.coverage([Self.iCloud()])
        #expect(FileLocation.verdict(
            forPath: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a.md",
            in: c, isCloudOnly: false) == .thisMacAndCloud(providerName: "iCloud"))
    }

    @Test func insideACloudFolderAndDatalessIsTheProviderAlone() {
        let c = Self.coverage([Self.oneDrive()])
        #expect(FileLocation.verdict(
            forPath: "/Users/u/Library/CloudStorage/OneDrive-Acme/Documents/big.zip",
            in: c, isCloudOnly: true) == .cloudOnly(providerName: "OneDrive (Acme)"))
    }

    @Test func outsideEveryCloudFolderAndDownloadedIsThisMacOnly() {
        let c = Self.coverage([Self.iCloud(), Self.oneDrive()])
        #expect(FileLocation.verdict(forPath: "/Users/u/Projects/notes.md",
                                     in: c, isCloudOnly: false) == .thisMacOnly)
    }

    /// Dataless outside every cloud folder: some File Provider this app never discovered holds the
    /// content. `thisMacOnly` would be a plain lie and there is no provider to name, so it says
    /// nothing — the same answer it gives to every question it cannot prove.
    @Test func outsideEveryCloudFolderAndDatalessIsNoVerdict() {
        let c = Self.coverage([Self.iCloud()])
        #expect(FileLocation.verdict(forPath: "/Users/u/Box/report.pdf",
                                     in: c, isCloudOnly: true) == nil)
    }

    // MARK: nil materialization is its own outcome

    /// A path that cannot be statted at all — deleted mid-download, or never there. Folding nil
    /// into `false` would print "This Mac only" over a file that is on this Mac in no sense.
    @Test func unknownMaterializationIsNeverAVerdict() {
        let outside = Self.coverage([Self.iCloud()])
        #expect(FileLocation.verdict(forPath: "/Users/u/Projects/gone.md",
                                     in: outside, isCloudOnly: nil) == nil)
        // …and inside a cloud folder too, where a provider name WAS available to print.
        #expect(FileLocation.verdict(
            forPath: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/gone.md",
            in: outside, isCloudOnly: nil) == nil)
    }

    /// The badge's half of the same rule: containment alone never draws ⌂ for an unknown file,
    /// because the row composes it with the materialization answer. Pinned here so the two halves
    /// cannot drift: containment says "outside", the verdict still says nothing.
    @Test func containmentAloneStillAnswersWhenMaterializationDoesNot() {
        let c = Self.coverage([Self.iCloud()])
        let path = "/Users/u/Projects/gone.md"
        #expect(FileLocation.outsideEveryCloudFolder(path: path, in: c))
        #expect(FileLocation.verdict(forPath: path, in: c, isCloudOnly: nil) == nil)
    }

    // MARK: ⌂ and ☁ are mutually exclusive

    /// ☁ is drawn from `isCloudOnly`; ⌂ is drawn from the `.thisMacOnly` verdict. The two can
    /// never apply at once because **a dataless file never verdicts `.thisMacOnly`** — asserted
    /// here over the whole cross, including the account-folder path that is the one shape which
    /// would produce both at once without the widening.
    ///
    /// Stated this way rather than as `!(showsCloud && showsHome)` over locally derived flags:
    /// that form recomputes ⌂ as `!isCloudOnly && …` and so reduces to `!(x && !x && …)`, a
    /// tautology that passes with every rule in `verdict` mutated away. This form fails the moment
    /// the `isCloudOnly ? nil : .thisMacOnly` branch stops consulting materialization.
    ///
    /// The other half of the guarantee — that the ROW never paints both glyphs — is pinned where
    /// the two answers actually meet, in `FileRowAccessories`.
    @Test func aDatalessFileNeverVerdictsThisMacOnly() {
        let c = Self.coverage([Self.iCloud(), Self.oneDrive()])
        let paths = [
            "/Users/u/Projects/notes.md",
            "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a.md",
            "/Users/u/Library/CloudStorage/OneDrive-Acme/Documents/b.txt",
            "/Users/u/Library/CloudStorage/OneDrive-Acme/Photos/c.jpg",
            "/Users/u/Box/report.pdf",
        ]
        for path in paths {
            #expect(FileLocation.verdict(forPath: path, in: c, isCloudOnly: true) != .thisMacOnly,
                    "dataless \(path) verdicted this-Mac-only")
        }
        // The premise: at least one of those paths DOES verdict `.thisMacOnly` when downloaded,
        // so the loop above is ruling something out rather than describing an empty case.
        #expect(paths.contains { FileLocation.verdict(forPath: $0, in: c, isCloudOnly: false)
                                 == .thisMacOnly })
    }

    // MARK: What the row says

    /// The three verdicts' wording, pinned literally. This is the whole of what the inspector row
    /// claims, and the copy rules are strict: "This Mac only" is where the file is NOT, never a
    /// statement about copies existing anywhere, and never "unprotected" or "unsafe".
    @Test func theVerdictsSayExactlyTheseWords() {
        #expect(FileLocation.Verdict.thisMacOnly.label == "This Mac only")
        #expect(FileLocation.Verdict.thisMacAndCloud(providerName: "iCloud").label == "This Mac · iCloud")
        #expect(FileLocation.Verdict.cloudOnly(providerName: "OneDrive").label == "OneDrive only")
    }

    /// The provider's REAL display name, user renames included — the row must name the source the
    /// way the rest of the app does, not by type.
    @Test func theVerdictUsesTheProvidersDisplayName() {
        let renamed = Self.oneDrive(name: "Work OneDrive")
        let c = Self.coverage([renamed])
        let file = "/Users/u/Library/CloudStorage/OneDrive-Acme/Documents/a.txt"
        #expect(FileLocation.verdict(forPath: file, in: c, isCloudOnly: false)?.label
                == "This Mac · Work OneDrive")
        #expect(FileLocation.verdict(forPath: file, in: c, isCloudOnly: true)?.label
                == "Work OneDrive only")
    }

    /// The supporting fact the inspector shows above the verdict has to agree with it — the row
    /// reads as a conclusion drawn from what is on screen, so a verdict saying the content is here
    /// above a fact saying it is not would be self-contradicting.
    @Test func theVerdictAgreesWithTheFactAboveIt() {
        #expect(FileLocation.Verdict.thisMacOnly.isOnThisMac)
        #expect(FileLocation.Verdict.thisMacAndCloud(providerName: "iCloud").isOnThisMac)
        #expect(FileLocation.Verdict.cloudOnly(providerName: "iCloud").isOnThisMac == false)
    }

    // MARK: The containment half is syscall-free

    /// Every containment fixture above runs on paths that do not exist, which proves the ANSWER
    /// does not depend on the disk. This closes the other half: that no filesystem-touching API is
    /// named at all, so a future edit cannot quietly put a stat back in front of every visible row.
    ///
    /// `URL(fileURLWithPath:)` without an `isDirectory:` hint stats the path to decide whether to
    /// append a trailing slash; `NSString.standardizingPath` resolves symlinks under `/tmp` and
    /// `/var`. Both are the obvious way to normalize a path and both are wrong here.
    ///
    /// Scoped to ONE named file, and it asserts the file was actually read and that a string it is
    /// known to contain is present — a source scan that silently finds nothing is the failure mode
    /// this kind of test has.
    @Test func containmentNamesNoFilesystemTouchingApi() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Tests/Sync
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // Sync (package)
            .appendingPathComponent("Sources/Sync/FileLocation.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // The scan can only mean something if it read the right file.
        #expect(text.contains("public static func outsideEveryCloudFolder"),
                "read the wrong file — the scan below would pass vacuously")
        for banned in ["URL(fileURLWithPath:", "standardizingPath", "resolvingSymlinksInPath",
                       "FileManager", "contentsOfDirectory", "fileExists", "lstat"] {
            // Doc comments name `URL(fileURLWithPath:)` to explain why it is absent, so only
            // CODE lines are scanned.
            let offenders = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("///") && !$0.hasPrefix("//") }
                .filter { $0.contains(banned) }
            #expect(offenders.isEmpty, "FileLocation names \(banned): \(offenders)")
        }
    }
}
