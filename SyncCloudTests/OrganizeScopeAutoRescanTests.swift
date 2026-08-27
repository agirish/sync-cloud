import Testing
import Foundation
@testable import SyncCloud

/// The auto-rescan refreshes **the subject**, not wherever the pane is standing.
///
/// `autoRescanLensIfShowing` fires on every pane-folder change and used to target
/// `lensScanRootExpanded`. With a scope set that is the queue-destroying failure the design rejects
/// live-binding to prevent, arriving through a different door: browse from a scoped `Legal` into
/// some other previously-scanned folder and the rescan silently republishes `filingSuggestions`
/// with *that* folder's files, which the `Legal` scope then filters to nothing. To File empties and
/// nothing on screen explains it.
///
/// `ContentView` is a SwiftUI view in the app target with no seam to instantiate here, so the
/// wiring is read from source — bounded by the declaration's own closing brace, and failing loudly
/// if the declaration cannot be found, because a scan that matches nothing passes just as green as
/// one that proves something.
@Suite struct OrganizeScopeAutoRescanTests {

    static func contentView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read MacApp/ContentView.swift — this scan would be vacuous")
        // `#require`, not `#expect`: a file that exists but is truncated hands a short string on,
        // after which every `contains` here answers false and every `!contains` answers true. One
        // quiet issue standing in front of a page of green is the wrong signal — stop instead.
        try #require(text.count > 10_000, "ContentView.swift is implausibly short — the scans below would be near-vacuous")
        return text
    }

    /// The shared reader — see ``declarationBody(of:in:)``. This copy had no uniqueness guard, so
    /// a decoy declaration above the real one was read silently.
    static func body(of declaration: String, in source: String) throws -> String {
        try declarationBody(of: declaration, in: source)
    }

    @Test func theAutoRescanPrefersTheScopeOverThePane() throws {
        let source = try Self.contentView()
        let body = try Self.body(of: "func autoRescanLensIfShowing() {", in: source)
        #expect(body.contains("let target = organizeScope?.path ?? lensScanRootExpanded"),
                "the auto-rescan is aimed at the pane again — browsing will replace a scoped queue")
        // Both arms must use it. Leaving either on the pane root reintroduces the defect for that
        // lens alone, which is the shape that hides: five lenses behave and one does not.
        #expect(body.contains("autoRescanDuplicatesIfEligible(root: URL(fileURLWithPath: target)"))
        #expect(body.contains("folder: URL(fileURLWithPath: target)"))
        // And neither arm may still read the pane directly.
        #expect(!body.contains("let root = lensScanRootExpanded"),
                "an arm is still resolving the pane's folder as its scan target")
    }

    /// **The same rule for the scans the user starts by hand, which never had it.** The auto-rescan
    /// was corrected for exactly this hazard while `findDuplicatesAction` and
    /// `findFilingSuggestionsAction` — the closures behind every run control on the All screen —
    /// went on targeting the pane. Scoped to `Legal` with the pane in `Photos/2024`, the Rescan
    /// whose tooltip promises "every file in scope is hashed" hashed `Photos/2024`, replaced the
    /// duplicate list, and left the overview reporting "clean" for `Legal`.
    @Test func theManualScansPreferTheScopeOverThePaneToo() throws {
        let source = try Self.contentView()

        let duplicates = try Self.body(of: "func findDuplicatesAction() {", in: source)
        #expect(duplicates.contains("let root = organizeScope?.path ?? lensScanRootExpanded"),
                "Find Duplicates is aimed at the pane again — a scoped scan will answer about wherever the user last browsed")

        let filing = try Self.body(of: "func findFilingSuggestionsAction(ignoringCache: Bool = false) {",
                                   in: source)
        #expect(filing.contains("organizeScope?.path ?? filingScanTargetFolder"),
                "the filing scan is aimed at the pane again")
        // The source ANCHOR stays the taxonomy root in both, for the reason below.
        #expect(filing.contains("let root = lensProviderAnchorExpanded"))
    }

    @Test func theSourceAnchorIsStillTheTaxonomyRoot() throws {
        // The scope narrows what is *scanned*; destinations still anchor at the source, or a rule's
        // "Home/Utilities/…" would nest under whatever subtree happened to be scoped.
        //
        // The ANCHOR — the landing folder — and not the account root, which is a different folder
        // since sources gained one above their documents tree. Every automation destination and
        // every filing taxonomy was authored when "provider-relative" meant relative to the
        // documents folder, so anchoring at the root would repoint them all silently: `TODO`, the
        // inbox default, names a real folder at the top of a OneDrive account as well as one inside
        // its Documents. See `ContentView.lensProviderAnchorExpanded`.
        let source = try Self.contentView()
        let body = try Self.body(of: "func autoRescanLensIfShowing() {", in: source)
        #expect(body.contains("let root = lensProviderAnchorExpanded"))
        #expect(body.contains("providerRoot: URL(fileURLWithPath: root)"))
    }

    @Test func theScopeIsResolvedThroughOneHelperForReadsAndWrites() throws {
        // The read has to agree with the write that a stored provider root means "no scope", or the
        // chip and the filter would disagree about the same stored string.
        let source = try Self.contentView()
        #expect(source.contains("var organizeScope: OrganizeScope? { resolvedOrganizeScope(organizeScopePath) }"))
        let setter = try Self.body(of: "func setOrganizeScope(_ path: String?, providerRoot: String) {", in: source)
        #expect(setter.contains("OrganizeScope.normalizedPath(path, providerRoot: providerRoot)"),
                "the setter has its own copy of the normalization again")
    }
}
