import Testing
import Foundation
@testable import Sync

/// The scope predicate, rule by rule.
///
/// **Every fixture here is built so that in-scope and out-of-scope answer differently.** A scope
/// test whose expected value equals the unscoped fallback cannot fail — it passes just as happily
/// against a predicate that returns `true` unconditionally — and that shape has already cost this
/// codebase a mutation that survived. So each case asserts a row that is admitted *and* a row that
/// is rejected, and the counts differ from the unfiltered count.
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
        // Dropping `expandingTildeInPath` from the scope path SURVIVED the first draft: the only
        // tilde argument any test passed was one that resolved OUTSIDE its fake root, so nil came
        // back either way and the expansion was never actually exercised.
        //
        // It matters because the persisted scope and the pane both deal in tilde-abbreviated paths
        // in places, and an unexpanded "~/Documents/Legal" is a literal relative path that matches
        // no absolute row — the scope would silently filter every lens to empty.
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
        // The mutation "any member -> the keeper only" SURVIVED the first draft of these tests,
        // because every fixture happened to make the keeper the in-scope copy.
        //
        // It is the dangerous direction. The keeper is chosen by canonicality — shallowest path
        // wins — so the copy that survives is routinely the one filed high in the tree, *outside*
        // a narrow scope, while the redundant copy is the one sitting in the folder the user is
        // looking at. Testing the keeper alone would drop exactly the groups a scoped user most
        // needs to see: the ones offering to delete something under their own feet.
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
        // The safety property spelled out: a straddling group keeps BOTH copies, and the predicate
        // that drives the label distinguishes them. Hiding half a group turns a two-copy decision
        // into a one-copy one, which is how the wrong copy gets trashed.
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
        // The defect: the reveal outcome is resolved against the WHOLE group list while the rows
        // are drawn through the scoped one. Without this the resolver reports "revealed", writes
        // the query, marks the group — and the group is then filtered away, so a direct question
        // about a named file comes back as a silent no.
        let s = Self.scope(Self.legal)
        #expect(OrganizeScopeFilter.revealClearsScope(
            revealedPath: "/Users/x/Documents/Medical/scan.pdf", scope: s))
    }

    @Test func aRevealForAFileINSIDETheScopeLeavesItAlone() {
        // The discriminating half. Clearing unconditionally would throw away a scope every time
        // the user asked about one of the rows they were already looking at.
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
        // and PathBoundary does no `.` resolution, so this case is the one that silently became
        // `.outside` if the root is not special-cased.
        let s = Self.scope(Self.legal)
        #expect(OrganizeScopeFilter.relation(of: Self.finding("."),
                                             profileRoot: Self.root, scope: s) == .aboutAncestor)
    }

    @Test func restructureIsUnfilteredWithoutAScope() {
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Immigration/Authorization/H-4"),
                                             profileRoot: Self.root, scope: nil) == .inside)
    }

    @Test func aTildeProfileRootResolvesLikeTheScopeDoes() {
        // **The live profile stores its root as the literal string "~/Documents"** (verified in
        // `folder-profile.json`), while a scope is always absolute. Without the expansion the two
        // never meet, every finding reads `.outside`, and Restructure goes silently empty under
        // every scope — the exact shape of the "12 green tests, zero findings on the real profile"
        // failure this feature already had once.
        //
        // The fixture has to hang off the REAL home for the same reason: `expandingTildeInPath`
        // resolves against `NSHomeDirectory()`, so a synthetic "/Users/x" home would make this test
        // pass or fail for reasons that have nothing to do with the rule under test. The first
        // draft of this test did exactly that and reported `.outside` against a correct predicate.
        let home = NSHomeDirectory()
        let root = (home as NSString).appendingPathComponent("Documents")
        let s = Self.scope((root as NSString).appendingPathComponent("Legal"), root: root)
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Legal/Cases"),
                                             profileRoot: "~/Documents", scope: s) == .inside)
        // And the rule still discriminates when the root is tilde-spelled — otherwise expanding it
        // could just as well be returning `.inside` for everything.
        #expect(OrganizeScopeFilter.relation(of: Self.finding("Medical/Bills"),
                                             profileRoot: "~/Documents", scope: s) == .outside)
    }

    // MARK: Rules — there is no predicate, and that is the assertion

    // `OrganizeScopeFilter.matches(_ rule: AutomationRule, scope:)` and its `literalPrefix` helper
    // were deleted with the tests that lived here, because the scope does not reach Rules at all
    // any more (`OrganizeLens.isScoped`). Their replacement is `OrganizeLensScopeTests` in
    // FileExplorer, next to the rule; the reason for the deletion is on `OrganizeScopeFilter`.
    //
    // Nothing is asserted here because there is nothing to assert: a stub retained "for coverage"
    // would be a predicate that no caller reaches, which is the state this removed.

    // MARK: The global view is genuinely unfiltered

    @Test func nilScopeAdmitsEverything() {
        #expect(OrganizeScopeFilter.matches(Self.suggestion("/anywhere/at/all.pdf"), scope: nil))
        #expect(OrganizeScopeFilter.matches(Self.risky("/anywhere/at/all.pdf"), scope: nil))
        #expect(OrganizeScopeFilter.matches(Self.plan("/anywhere/at/all"), scope: nil))
        #expect(OrganizeScopeFilter.matches(Self.group(["/anywhere/a.pdf"]), scope: nil))
    }
}
