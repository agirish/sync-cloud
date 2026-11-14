import Testing
@testable import Dashboard

/// Coverage for the pure breadcrumb logic behind PaneBreadcrumb: path splitting into
/// cumulative crumbs, middle-ellipsis truncation of deep trails, and root crumb naming.
@Suite struct BreadcrumbTrailTests {

    // MARK: - crumbs(forRelativePath:)

    @Test func testEmptyPathYieldsNoCrumbs() {
        #expect(BreadcrumbTrail.crumbs(forRelativePath: "").isEmpty)
    }

    @Test func testSingleComponentPath() {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: "Documents")
        #expect(crumbs == [.init(name: "Documents", relativePath: "Documents")])
    }

    @Test func testCrumbPathsAccumulateAncestors() {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: "Documents/Projects/App")
        #expect(crumbs.map(\.name) == ["Documents", "Projects", "App"])
        #expect(crumbs.map(\.relativePath) == ["Documents", "Documents/Projects", "Documents/Projects/App"])
    }

    @Test func testDoubledAndTrailingSlashesAreNormalized() {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: "a//b/")
        #expect(crumbs.map(\.relativePath) == ["a", "a/b"])
    }

    // MARK: - displayItems(for:)

    @Test func testShallowTrailShowsEveryCrumb() {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: "a/b/c/d")
        let items = BreadcrumbTrail.displayItems(for: crumbs)
        #expect(items == crumbs.map(BreadcrumbTrail.Item.crumb))
    }

    @Test func testDeepTrailCollapsesMiddleKeepingFirstAndLastTwo() {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: "a/b/c/d/e")
        let items = BreadcrumbTrail.displayItems(for: crumbs)
        #expect(items == [
            .crumb(.init(name: "a", relativePath: "a")),
            .collapsed([
                .init(name: "b", relativePath: "a/b"),
                .init(name: "c", relativePath: "a/b/c"),
            ]),
            .crumb(.init(name: "d", relativePath: "a/b/c/d")),
            .crumb(.init(name: "e", relativePath: "a/b/c/d/e")),
        ])
    }

    @Test func testCollapsedMiddlePreservesOrderForLongTrails() {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: "r/1/2/3/4/5/leaf")
        let items = BreadcrumbTrail.displayItems(for: crumbs)
        #expect(items.count == 4)
        guard case .collapsed(let hidden) = items[1] else {
            Issue.record("Second item should be the collapsed middle")
            return
        }
        #expect(hidden.map(\.name) == ["1", "2", "3", "4"])
        // Every hidden crumb still carries its full ancestor path for re-focusing.
        #expect(hidden.last?.relativePath == "r/1/2/3/4")
    }

    @Test func testTinyMaxVisibleNeverCollapsesBelowFourCrumbs() {
        // A middle exists only between the first crumb and the last two, so a trail of three or
        // fewer renders in full even when maxVisible is smaller.
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: "a/b/c")
        let items = BreadcrumbTrail.displayItems(for: crumbs, maxVisible: 2)
        #expect(items == crumbs.map(BreadcrumbTrail.Item.crumb))
    }

    // MARK: - rootDisplayName(forRootPath:)

    /// The last path component, a trailing slash ignored; a bare or empty path falls back to "Root".
    @Test(arguments: [("/Users/me/Documents", "Documents"), ("/Users/me/Dropbox/", "Dropbox"),
                      ("/", "Root"), ("", "Root")])
    func testTheRootIsNamedByItsLastComponent(path: String, name: String) {
        #expect(BreadcrumbTrail.rootDisplayName(forRootPath: path) == name)
    }

    // MARK: - compactItems(for:) — Edit's narrow pane (asked 2026-10-17)

    /// Every folder above the current one goes behind the ellipsis, in order; the current one is
    /// spelled out. At the root there is nothing; one level deep there is nothing to fold.
    @Test func theCompactTrailFoldsEveryAncestorAndSpellsOutTheCurrentFolder() {
        #expect(BreadcrumbTrail.compactItems(for: []).isEmpty)
        let one = BreadcrumbTrail.crumbs(forRelativePath: "Documents")
        #expect(BreadcrumbTrail.compactItems(for: one) == [.crumb(one[0])])
        let deep = BreadcrumbTrail.crumbs(forRelativePath: "Documents/Finance/Chase/2020")
        #expect(BreadcrumbTrail.compactItems(for: deep) == [.collapsed(Array(deep.prefix(3))), .crumb(deep[3])])
    }
}
