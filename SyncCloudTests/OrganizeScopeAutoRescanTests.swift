import Testing
import Foundation
@testable import SyncCloud

/// The auto-rescan refreshes **the subject**, not wherever the pane is standing.
///
/// `autoRescanTidyLensIfShowing` fires on every pane-folder change and used to target
/// `tidyScanRootExpanded`. With a scope set that is the queue-destroying failure the design rejects
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
        #expect(text.count > 10_000, "ContentView.swift is implausibly short")
        return text
    }

    static func body(of declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — the scan below would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(declaration)")
        return String(rest[..<end.lowerBound])
    }

    @Test func theAutoRescanPrefersTheScopeOverThePane() throws {
        let source = try Self.contentView()
        let body = try Self.body(of: "func autoRescanTidyLensIfShowing() {", in: source)
        #expect(body.contains("let target = organizeScope?.path ?? tidyScanRootExpanded"),
                "the auto-rescan is aimed at the pane again — browsing will replace a scoped queue")
        // Both arms must use it. Leaving either on the pane root reintroduces the defect for that
        // lens alone, which is the shape that hides: five lenses behave and one does not.
        #expect(body.contains("autoRescanDuplicatesIfEligible(root: URL(fileURLWithPath: target)"))
        #expect(body.contains("folder: URL(fileURLWithPath: target)"))
        // And neither arm may still read the pane directly.
        #expect(!body.contains("let root = tidyScanRootExpanded"),
                "an arm is still resolving the pane's folder as its scan target")
    }

    @Test func theProviderRootIsStillTheTaxonomyRoot() throws {
        // The scope narrows what is *scanned*; destinations still anchor at the provider root, or a
        // rule's "Home/Utilities/…" would nest under whatever subtree happened to be scoped.
        let source = try Self.contentView()
        let body = try Self.body(of: "func autoRescanTidyLensIfShowing() {", in: source)
        #expect(body.contains("let root = tidyProviderRootExpanded"))
        #expect(body.contains("providerRoot: URL(fileURLWithPath: root)"))
    }

    @Test func theScopeIsResolvedThroughOneHelperForReadsAndWrites() throws {
        // The read has to agree with the write that a stored provider root means "no scope", or the
        // chip and the filter would disagree about the same stored string.
        let source = try Self.contentView()
        #expect(source.contains("var organizeScope: OrganizeScope? { resolvedOrganizeScope(organizeScopePath) }"))
        let setter = try Self.body(of: "func setOrganizeScope(_ path: String?) {", in: source)
        #expect(setter.contains("resolvedOrganizeScope(path)?.path ?? \"\""),
                "the setter has its own copy of the normalization again")
    }
}
