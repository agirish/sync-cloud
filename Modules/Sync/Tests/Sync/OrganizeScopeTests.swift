import Testing
import Foundation
@testable import Sync

/// The scope predicate, rule by rule. Each case asserts a row that is admitted and one that is
/// rejected, and the unscoped answer differs: a test whose expectation equals the unscoped fallback
/// would pass against a predicate that always returns `true`.
@Suite struct OrganizeScopeTests {

    static let root = "/Users/x/Documents"
    static let legal = "/Users/x/Documents/Legal"

    static func scope(_ path: String, root: String = root) -> OrganizeScope {
        OrganizeScope(path: path, providerRoot: root)!
    }

    // MARK: Normalizing the root

    @Test func theProviderRootIsNotAScope() {
        // The whole "one state, one representation" rule: pointing at the root clears the scope
        // rather than encoding the global view a second way.
        #expect(OrganizeScope(path: Self.root, providerRoot: Self.root) == nil)
        #expect(OrganizeScope(path: Self.root + "/", providerRoot: Self.root) == nil)
        #expect(OrganizeScope(path: "~/Documents", providerRoot: Self.root) == nil)
    }

    @Test func aSubtreeIsAScope() {
        let s = OrganizeScope(path: Self.legal, providerRoot: Self.root)
        #expect(s != nil)
        #expect(s?.name == "Legal")
        #expect(s?.relativePath == "Legal")
    }

    @Test func aPathOutsideTheProviderIsNotAScope() {
        // Falls back to the global view rather than filtering everything to nothing — a provider
        // can be switched while a stale scope is still persisted.
        #expect(OrganizeScope(path: "/Users/x/Desktop", providerRoot: Self.root) == nil)
        #expect(OrganizeScope(path: "", providerRoot: Self.root) == nil)
        #expect(OrganizeScope(path: Self.legal, providerRoot: "") == nil)
    }

    @Test func aTildeSpelledScopePathResolvesToTheSameScope() {
        // Fails if `expandingTildeInPath` is dropped from the scope path. The persisted scope and
        // the pane both use tilde paths in places, and an unexpanded "~/Documents/Legal" matches no
        // absolute row, so the scope would silently filter every lens to empty. The fixture
        // resolves inside its root so nil can't pass by accident.
        let home = NSHomeDirectory()
        let root = (home as NSString).appendingPathComponent("Documents")
        let expanded = OrganizeScope(path: (root as NSString).appendingPathComponent("Legal"),
                                     providerRoot: root)
        let tilded = OrganizeScope(path: "~/Documents/Legal", providerRoot: "~/Documents")
        #expect(tilded != nil)
        #expect(tilded == expanded)
        #expect(tilded?.contains((root as NSString).appendingPathComponent("Legal/case.pdf")) == true)
    }

    @Test func aSiblingSharingAStringPrefixIsOutside() {
        // The boundary bug `PathBoundary` exists to prevent, asserted at this layer too: `Legal`
        // must not claim `LegalArchive`.
        let s = Self.scope(Self.legal)
        #expect(s.contains("/Users/x/Documents/Legal/case.pdf"))
        #expect(!s.contains("/Users/x/Documents/LegalArchive/case.pdf"))
    }

    @Test func theScopeContainsItself() {
        #expect(Self.scope(Self.legal).contains(Self.legal))
    }

    // MARK: Ancestors

    @Test func ancestorsAreAncestorsAndTheScopeIsNotItsOwn() {
        let s = Self.scope("/Users/x/Documents/Finance/US/Income Tax")
        #expect(s.isAncestor("/Users/x/Documents/Finance/US"))
        #expect(s.isAncestor("/Users/x/Documents/Finance"))
        #expect(s.isAncestor(Self.root))
        // Not its own ancestor — otherwise every finding about the scope itself would be labelled
        // "about the folder above this one".
        #expect(!s.isAncestor("/Users/x/Documents/Finance/US/Income Tax"))
        #expect(!s.isAncestor("/Users/x/Documents/Medical"))
    }

    @Test func relationSeparatesAllThreeAnswers() {
        let s = Self.scope("/Users/x/Documents/Finance/US")
        #expect(s.relation(of: "/Users/x/Documents/Finance/US/Income Tax") == .inside)
        #expect(s.relation(of: "/Users/x/Documents/Finance/US") == .inside)
        #expect(s.relation(of: "/Users/x/Documents/Finance") == .aboutAncestor)
        #expect(s.relation(of: "/Users/x/Documents/Medical") == .outside)
    }

    // MARK: To File

    static func suggestion(_ path: String) -> FilingSuggestion {
        FilingSuggestion(filePath: path, fileName: (path as NSString).lastPathComponent,
                         size: 1, modificationDate: nil, candidates: [])
    }

    @Test func toFileAdmitsFilesUnderTheScopeAndRejectsOthers() {
        let s = Self.scope(Self.legal)
        let inside = Self.suggestion("/Users/x/Documents/Legal/lease.pdf")
        let deeper = Self.suggestion("/Users/x/Documents/Legal/2024/lease.pdf")
        let outside = Self.suggestion("/Users/x/Documents/Medical/scan.pdf")

        #expect(OrganizeScopeFilter.matches(inside, scope: s))
        #expect(OrganizeScopeFilter.matches(deeper, scope: s))
        #expect(!OrganizeScopeFilter.matches(outside, scope: s))

        // And the unscoped answer genuinely differs, so the assertions above cannot be satisfied
        // by a predicate that ignores its scope.
        #expect(OrganizeScopeFilter.matches(outside, scope: nil))
    }

    // MARK: Names

    static func risky(_ path: String) -> RiskyName {
        RiskyName(id: path, relativePath: path, currentName: (path as NSString).lastPathComponent,
                  sanitizedName: "ok", reason: "r", isDirectory: false)
    }

    @Test func namesFilterToTheScope() {
        let s = Self.scope(Self.legal)
        #expect(OrganizeScopeFilter.matches(Self.risky("/Users/x/Documents/Legal/a?.pdf"), scope: s))
        #expect(!OrganizeScopeFilter.matches(Self.risky("/Users/x/Documents/Medical/a?.pdf"), scope: s))
        #expect(OrganizeScopeFilter.matches(Self.risky("/Users/x/Documents/Medical/a?.pdf"), scope: nil))
    }

    @Test func aRiskyFolderNameAtTheScopeRootIsInScope() {
        // The node itself, not its parent — a scope whose own name is risky is a finding about the
        // scope, and testing the parent would push it outside.
        let s = Self.scope(Self.legal)
        #expect(OrganizeScopeFilter.matches(Self.risky(Self.legal), scope: s))
    }

    // MARK: Renames

    static func plan(_ folder: String) -> RenamePlan {
        RenamePlan(folderPath: folder, relativePath: folder, scheme: .position, steps: [], skips: [])
    }

    @Test func renamesFilterToTheScope() {
        let s = Self.scope(Self.legal)
        #expect(OrganizeScopeFilter.matches(Self.plan("/Users/x/Documents/Legal/2024"), scope: s))
        #expect(!OrganizeScopeFilter.matches(Self.plan("/Users/x/Documents/Finance/2024"), scope: s))
        #expect(OrganizeScopeFilter.matches(Self.plan("/Users/x/Documents/Finance/2024"), scope: nil))
    }

    // MARK: Duplicates

    static func copyAt(_ path: String, keeper: Bool = false) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 10, itemCount: 1, modificationDate: nil, uniqueItemCount: 0,
                      depth: 1, isRecommendedKeeper: keeper, contentUnverified: false,
                      isProtectedFromRemoval: false)
    }

    static func group(_ paths: [String]) -> DuplicateGroup {
        DuplicateGroup(matchType: .identical, name: "dup", isDirectory: false,
                       copies: paths.enumerated().map { Self.copyAt($1, keeper: $0 == 0) },
                       reclaimableBytes: 10)
    }

    @Test func aGroupIsInScopeWhenANYMemberIs() {
        let s = Self.scope(Self.legal)
        let straddling = Self.group(["/Users/x/Documents/Legal/a.pdf",
                                     "/Users/x/Documents/Medical/a.pdf"])
        let entirelyOutside = Self.group(["/Users/x/Documents/Medical/a.pdf",
                                          "/Users/x/Documents/Finance/a.pdf"])
        #expect(OrganizeScopeFilter.matches(straddling, scope: s))
        #expect(!OrganizeScopeFilter.matches(entirelyOutside, scope: s))
        #expect(OrganizeScopeFilter.matches(entirelyOutside, scope: nil))
    }

    @Test func aGroupWhoseKEEPERIsOutsideTheScopeIsStillAdmitted() {
        // Fails if "any member" becomes "the keeper only". The keeper is the shallowest path, so it
        // often sits outside a narrow scope while the redundant copy is in the folder the user is
        // looking at. Testing the keeper alone would hide the groups offering to delete something
        // under the user's feet.
        let s = Self.scope(Self.legal)
        let keeperOutside = DuplicateGroup(
            matchType: .identical, name: "dup", isDirectory: false,
            copies: [Self.copyAt("/Users/x/Documents/Archive/a.pdf", keeper: true),
                     Self.copyAt("/Users/x/Documents/Legal/a.pdf")],
            reclaimableBytes: 10)
        #expect(keeperOutside.keeper.path == "/Users/x/Documents/Archive/a.pdf")
        #expect(!s.contains(keeperOutside.keeper.path))
        #expect(OrganizeScopeFilter.matches(keeperOutside, scope: s))
    }

    @Test func theOutOfScopeCopiesOfAnAdmittedGroupAreLabelledNotHidden() {
        // A straddling group keeps both copies, and the label's predicate tells them apart. Hiding
        // half a group turns a two-copy decision into a one-copy one, and the wrong copy gets
        // trashed.
        let s = Self.scope(Self.legal)
        let straddling = Self.group(["/Users/x/Documents/Legal/a.pdf",
                                     "/Users/x/Documents/Medical/a.pdf"])
        #expect(straddling.copies.count == 2)
        #expect(OrganizeScopeFilter.isCopyInScope(straddling.copies[0], scope: s))
        #expect(!OrganizeScopeFilter.isCopyInScope(straddling.copies[1], scope: s))
        // Unscoped, the label never renders.
        #expect(straddling.copies.allSatisfy { OrganizeScopeFilter.isCopyInScope($0, scope: nil) })
    }

    // MARK: Handoffs

    @Test func aRevealForAFileOUTSIDETheScopeClearsIt() {
        // The reveal resolves against the whole group list while rows draw through the scoped one.
        // Without clearing, the group is marked and then filtered away, and a question about a
        // named file comes back as a silent no.
        let s = Self.scope(Self.legal)
        #expect(OrganizeScopeFilter.revealClearsScope(
            revealedPath: "/Users/x/Documents/Medical/scan.pdf", scope: s))
    }

    @Test func aRevealForAFileINSIDETheScopeLeavesItAlone() {
        // Clearing unconditionally would drop the scope whenever the user asked about a row they
        // were already looking at.
        let s = Self.scope(Self.legal)
        #expect(!OrganizeScopeFilter.revealClearsScope(
            revealedPath: "/Users/x/Documents/Legal/lease.pdf", scope: s))
        #expect(!OrganizeScopeFilter.revealClearsScope(
            revealedPath: "/Users/x/Documents/Legal/2024/lease.pdf", scope: s))
    }

    @Test func aRevealWithNoScopeClearsNothing() {
        #expect(!OrganizeScopeFilter.revealClearsScope(
            revealedPath: "/Users/x/Documents/Medical/scan.pdf", scope: nil))
    }

    @Test func aRevealForASIBLINGSHARINGAPREFIXClearsTheScope() {
        // `Legal` must not be treated as containing `LegalArchive`, or the handoff would leave the
        // scope in place and hide the very group it was asked about.
        let s = Self.scope(Self.legal)
        #expect(OrganizeScopeFilter.revealClearsScope(
            revealedPath: "/Users/x/Documents/LegalArchive/lease.pdf", scope: s))
    }

    // MARK: Restructure

    static func finding(_ family: String) -> StructureFinding {
        StructureFinding(family: family,
                         schemes: [.init(vocabulary: ["a"], members: ["x", "y"]),
                                   .init(vocabulary: ["b"], members: ["z", "w"])])
    }

    @Test func restructureSeparatesInsideAncestorAndOutside() {
        let s = Self.scope("/Users/x/Documents/Finance/US/Income Tax")
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Finance/US/Income Tax"),
                                             profileRoot: Self.root, scope: s) == .inside)
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Finance/US/Income Tax/2024"),
                                             profileRoot: Self.root, scope: s) == .inside)
        // The honest answer at a leaf: the family above is about this folder's surroundings.
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Finance/US"),
                                             profileRoot: Self.root, scope: s) == .aboutAncestor)
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Immigration/Authorization/H-4"),
                                             profileRoot: Self.root, scope: s) == .outside)
    }

    @Test func theProfileRootFamilyIsAnAncestorNotAnOutsider() {
        // `family == "."` is the profile root. `appendingPathComponent` would spell it "<root>/."
        // and `PathBoundary` does no `.` resolution, so without a special case it reads `.outside`.
        let s = Self.scope(Self.legal)
        #expect(OrganizeScopeFilter.relation(of: Self.finding("."),
                                             profileRoot: Self.root, scope: s) == .aboutAncestor)
    }

    @Test func restructureIsUnfilteredWithoutAScope() {
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Immigration/Authorization/H-4"),
                                             profileRoot: Self.root, scope: nil) == .inside)
    }

    @Test func aTildeProfileRootResolvesLikeTheScopeDoes() {
        // The live profile stores its root as the literal "~/Documents", while a scope is always
        // absolute. Without expansion every finding reads `.outside` and Restructure goes silently
        // empty under every scope. The fixture uses the real home because `expandingTildeInPath`
        // resolves against `NSHomeDirectory()`; a synthetic home would test the wrong thing.
        let home = NSHomeDirectory()
        let root = (home as NSString).appendingPathComponent("Documents")
        let s = Self.scope((root as NSString).appendingPathComponent("Legal"), root: root)
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Legal/Cases"),
                                             profileRoot: "~/Documents", scope: s) == .inside)
        // Still discriminates with a tilde root, so it can't be answering `.inside` for everything.
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Medical/Bills"),
                                             profileRoot: "~/Documents", scope: s) == .outside)
    }

    // MARK: Rules — there is no predicate, and that is the assertion

    // The scope does not reach Rules (`OrganizeLens.isScoped`), so there is no rule predicate to
    // test here. `OrganizeLensTests` in FileExplorer covers that rule; the reason is on
    // `OrganizeScopeFilter`.

    // MARK: - Whether an answer can be given at all

    /// Filtering a scan's results to zero and the scan finding nothing are different facts, and
    /// only the second is "clean". A scan covers its own root and what is under it, never a scope
    /// it didn't enter.
    @Test func aScanCoversOnlyItsOwnRootAndWhatIsUnderIt() {
        // The scan that covers it: the subject itself, and any ancestor of it.
        #expect(OrganizeScopeFilter.scanCovers(subject: Self.legal, scannedRoot: Self.legal))
        #expect(OrganizeScopeFilter.scanCovers(subject: Self.legal, scannedRoot: Self.root))
        // Not a sibling, nor a descendant: scanning `Legal/2024` says nothing about the rest of
        // `Legal`.
        #expect(!OrganizeScopeFilter.scanCovers(subject: Self.legal, scannedRoot: Self.root + "/Photos"))
        #expect(!OrganizeScopeFilter.scanCovers(subject: Self.legal, scannedRoot: Self.legal + "/2024"))
        // A prefix that is not a path boundary is not an ancestor.
        #expect(!OrganizeScopeFilter.scanCovers(subject: Self.legal, scannedRoot: Self.root + "/Leg"))
        // Nothing has run at all.
        #expect(!OrganizeScopeFilter.scanCovers(subject: Self.legal, scannedRoot: nil))
    }

    /// With no scope the subject is the provider root, not "whatever ran": the overview's clean
    /// message is about everything, so a scan of one browsed subfolder does not cover it. Passing
    /// the scanned root as the subject would ask whether the scan covered itself.
    @Test func withNoScopeTheSubjectIsTheProviderRootAndASubfolderScanDoesNotCoverIt() {
        #expect(!OrganizeScopeFilter.scanCovers(subject: Self.root, scannedRoot: Self.root + "/Photos"),
                "a scan of one subfolder was allowed to answer for the whole tree")
        #expect(!OrganizeScopeFilter.looseFileScanCovers(subject: Self.root,
                                                        scannedFolder: Self.root + "/Photos"))
        // Scanning the tree's top does cover it, which is the ordinary global case.
        #expect(OrganizeScopeFilter.scanCovers(subject: Self.root, scannedRoot: Self.root))
        #expect(OrganizeScopeFilter.looseFileScanCovers(subject: Self.root, scannedFolder: Self.root))
    }

    /// Only with NO subject at all — no scope and no provider — does the question fall back to
    /// "has anything run", because there is nothing to have covered.
    @Test func withNoSubjectAtAllCoverageIsJustWhetherAPassHasRun() {
        for empty in [nil, ""] as [String?] {
            #expect(OrganizeScopeFilter.scanCovers(subject: empty, scannedRoot: Self.root + "/Photos"))
            #expect(!OrganizeScopeFilter.scanCovers(subject: empty, scannedRoot: nil))
            #expect(OrganizeScopeFilter.looseFileScanCovers(subject: empty, scannedFolder: Self.root))
            #expect(!OrganizeScopeFilter.looseFileScanCovers(subject: empty, scannedFolder: nil))
        }
    }

    /// A one-level pass answers only for the folder it enumerated. The ancestor case matters: the
    /// root's loose files are all outside `Legal`, so a root-level filing scan leaves `Legal`'s
    /// count zero by construction, and "covered" there would be a false clean.
    @Test func aOneLevelScanAnswersOnlyForTheFolderItEnumerated() {

        #expect(OrganizeScopeFilter.looseFileScanCovers(subject: Self.legal, scannedFolder: Self.legal))
        #expect(!OrganizeScopeFilter.looseFileScanCovers(subject: Self.legal, scannedFolder: Self.root),
                "an ancestor scan enumerated its own loose files, not the scope's")
        #expect(!OrganizeScopeFilter.looseFileScanCovers(subject: Self.legal,
                                                        scannedFolder: Self.legal + "/2024"))
        #expect(!OrganizeScopeFilter.looseFileScanCovers(subject: Self.legal,
                                                        scannedFolder: Self.root + "/Photos"))
        #expect(!OrganizeScopeFilter.looseFileScanCovers(subject: Self.legal, scannedFolder: nil))
        // Same folder, spelled two ways — equality has to go through the path rules, not `==`.
        #expect(OrganizeScopeFilter.looseFileScanCovers(subject: Self.legal, scannedFolder: Self.legal + "/"))
    }
}
