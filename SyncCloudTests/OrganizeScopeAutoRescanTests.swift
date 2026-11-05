import Testing
import Foundation
@testable import SyncCloud

/// The auto-rescan refreshes the subject, not wherever the pane is standing.
/// `autoRescanLensIfShowing` fires on every pane-folder change; aimed at the pane, browsing from a
/// scoped `Legal` into another scanned folder would republish `filingSuggestions` with that
/// folder's files, which the scope then filters to nothing, and To File empties unexplained.
///
/// `ContentView` has no seam to instantiate here, so the wiring is read from source, bounded by
/// the declaration's closing brace, failing loudly if the declaration can't be found.
@Suite struct OrganizeScopeAutoRescanTests {

    static func contentView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read MacApp/ContentView.swift — this scan would be vacuous")
        // `#require`, not `#expect`: on a truncated file every `!contains` below would pass, so
        // stop instead of reporting one issue in front of a page of green.
        try #require(text.count > 10_000, "ContentView.swift is implausibly short — the scans below would be near-vacuous")
        return text
    }

    /// The shared reader, ``declarationBody(of:in:)``, whose uniqueness guard stops a decoy
    /// declaration above the real one being read silently.
    static func body(of declaration: String, in source: String) throws -> String {
        try declarationBody(of: declaration, in: source)
    }

    @Test func theAutoRescanPrefersTheScopeOverThePane() throws {
        let source = try Self.contentView()
        let body = try Self.body(of: "func autoRescanLensIfShowing() {", in: source)
        #expect(body.contains("let target = organizeScope?.path ?? lensScanRootExpanded"),
                "the auto-rescan is aimed at the pane again — browsing will replace a scoped queue")
        // Both arms must use it: one left on the pane root breaks that lens alone, which is easy to
        // miss.
        #expect(body.contains("autoRescanDuplicatesIfEligible(root: URL(fileURLWithPath: target)"))
        #expect(body.contains("folder: URL(fileURLWithPath: target)"))
        // And neither arm may still read the pane directly.
        #expect(!body.contains("let root = lensScanRootExpanded"),
                "an arm is still resolving the pane's folder as its scan target")
    }

    /// The same rule for the scans the user starts by hand: `findDuplicatesAction` and
    /// `findFilingSuggestionsAction`, behind every run control on the All screen. Aimed at the
    /// pane, a Rescan scoped to `Legal` with the pane in `Photos/2024` would hash `Photos/2024`,
    /// replace the duplicate list, and report `Legal` clean.
    @Test func theManualScansPreferTheScopeOverThePaneToo() throws {
        let source = try Self.contentView()

        let duplicates = try Self.body(of: "func findDuplicatesAction() {", in: source)
        #expect(duplicates.contains("let root = organizeScope?.path ?? lensScanRootExpanded"),
                "Find Duplicates is aimed at the pane again — a scoped scan will answer about wherever the user last browsed")

        let filing = try Self.body(of: "func findFilingSuggestionsAction(ignoringCache: Bool = false) {",
                                   in: source)
        #expect(filing.contains("organizeScope?.path ?? filingScanTargetFolder"),
                "the filing scan is aimed at the pane again")
        // File Into's folder is the taxonomy root: the source anchor unless the source is a folder
        // or the user chose another, for the reason below.
        #expect(filing.contains("let root = lensFilingDestinationRoot"))
    }

    @Test func theSourceAnchorIsStillTheTaxonomyRoot() throws {
        // The scope narrows what is scanned; destinations still anchor at the source, or a rule's
        // "Home/Utilities/…" would nest under whatever subtree is scoped.
        //
        // The anchor (the landing folder), not the account root above it: destinations and
        // taxonomies are relative to the documents folder, so anchoring at the root would repoint
        // them all silently. `TODO`, the inbox default, can name a real folder at both levels of a
        // OneDrive account. See `ContentView.lensProviderAnchorExpanded`.
        //
        // The root is File Into's folder, which for a cloud source with no choice made is the
        // anchor, so the anchor rule lives in `filingDestinationRoot(forProviderId:)`, pinned here.
        let source = try Self.contentView()
        let body = try Self.body(of: "func autoRescanLensIfShowing() {", in: source)
        #expect(body.contains("let root = lensFilingDestinationRoot"))
        #expect(body.contains("providerRoot: URL(fileURLWithPath: root)"))
        let fileInto = try Self.contentViewFileInto()
        let resolve = try Self.body(of: "func filingDestinationRoot(forProviderId id: String) -> String {", in: fileInto)
        #expect(resolve.contains("let anchor = providerAnchorExpanded(forProviderId: id)"),
                "File Into defaults from the account root again: rule destinations resolve one level too deep")
        #expect(resolve.contains("sourceAnchor: anchor"))
        #expect(fileInto.contains("var lensFilingDestinationRoot: String { filingDestinationRoot(forProviderId: lensProviderId) }"))
    }

    static func contentViewFileInto() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FileInto.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read MacApp/ContentView+FileInto.swift — this scan would be vacuous")
        try #require(text.count > 2_000, "ContentView+FileInto.swift is implausibly short")
        return text
    }

    /// Every entry point that starts a filing scan files into File Into's folder, and says when
    /// that tree isn't the source, so Names and Renames aren't answered about another tree. Row
    /// menus resolve it from the row's anchor, not the focused pane's.
    @Test func everyFilingScanFilesIntoFileIntosFolder() throws {
        let source = try Self.contentView()
        let manual = try Self.body(of: "func findFilingSuggestionsAction(ignoringCache: Bool = false) {", in: source)
        #expect(manual.contains("reportsTreeFindings: lensFilingReportsTreeFindings"))
        let auto = try Self.body(of: "func autoRescanLensIfShowing() {", in: source)
        #expect(auto.contains("reportsTreeFindings: lensFilingReportsTreeFindings"))
        let row = try Self.body(of: "func organizeFolderAction(_ node: FileNode, providerRoot: String, providerAnchor: String) {", in: source)
        #expect(row.contains("let into = filingDestinationRoot(forAnchor: providerAnchor)"))
        #expect(row.contains("providerRoot: URL(fileURLWithPath: into)"))
        #expect(row.contains("reportsTreeFindings: into == providerAnchor"))
        #expect(source.contains("fileInto: fileIntoChoice,"), "the lens is not handed File Into")
    }

    /// The lens workspace is handed both folders, and each of its two questions gets the right one.
    /// Given only the root, the rule editor would store `…/OneDrive-X/Documents/Invoices` as
    /// `Documents/Invoices` and the preview would apply it at `…/Documents/Documents/Invoices`,
    /// creating a folder and moving files into it. And `looseFileScanCovers`, comparing by
    /// equality, would report a finished unscoped pass as never run.
    ///
    /// A source scan, because both values are plain strings: swapped, they compile and run and
    /// produce wrong folders, not an error.
    @Test func theLensWorkspaceGetsTheAnchorAndTheRootSeparately() throws {
        let source = try Self.contentView()
        // A `Comment` takes a literal, not a concatenation — kept on one line each.
        #expect(source.contains("providerAnchor: lensProviderAnchorExpanded"),
                "the lens taxonomy is aimed at the account root again: rule destinations resolve one level too deep and an unscoped scan never covers its own subject")
        #expect(source.contains("providerRoot: lensProviderRootExpanded"),
                "the scope lost the root that bounds it: a folder above the landing folder now normalizes to the global view")
    }

    /// The other actions that anchor at the taxonomy, so swapping one back to
    /// `lensProviderRootExpanded` fails here too.
    @Test func everyTaxonomyAnchoredActionUsesTheAnchor() throws {
        let source = try Self.contentView()
        let survey = try Self.body(of: "func updateFolderMemoryAction() {", in: source)
        #expect(survey.contains("lensProviderAnchorExpanded"), "the re-survey is anchored at the account root again")
        // The Rules preview resolves into To File's tree, which is anchored (see above).
        let preview = try Self.body(of: "func startAutomationPreviewAction(only: UUID? = nil) {", in: source)
        #expect(preview.contains("let providerRoot = lensFilingDestinationRoot"),
                "the Rules preview resolves into a different tree from To File's")
    }

    @Test func theScopeIsResolvedThroughOneHelperForReadsAndWrites() throws {
        // Read and write must agree that a stored provider root means "no scope", or the chip and
        // the filter would disagree about the same string.
        let source = try Self.contentView()
        #expect(source.contains("var organizeScope: OrganizeScope? { resolvedOrganizeScope(organizeScopePath) }"))
        let setter = try Self.body(of: "func setOrganizeScope(_ path: String?, providerRoot: String) {", in: source)
        #expect(setter.contains("OrganizeScope.normalizedPath(path, providerRoot: providerRoot)"),
                "the setter has its own copy of the normalization again")
    }
}
