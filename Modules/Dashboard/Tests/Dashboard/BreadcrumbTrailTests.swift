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
        // A "middle" only exists between the first crumb and the last two, so trails of
        // three or fewer render fully even if maxVisible is smaller.
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: "a/b/c")
        let items = BreadcrumbTrail.displayItems(for: crumbs, maxVisible: 2)
        #expect(items == crumbs.map(BreadcrumbTrail.Item.crumb))
    }

    // MARK: - rootDisplayName(forRootPath:)

    @Test func testRootNameIsLastPathComponent() {
        #expect(BreadcrumbTrail.rootDisplayName(forRootPath: "/Users/me/Documents") == "Documents")
    }

    @Test func testRootNameIgnoresTrailingSlash() {
        #expect(BreadcrumbTrail.rootDisplayName(forRootPath: "/Users/me/Dropbox/") == "Dropbox")
    }

    @Test func testRootNameFallsBackForBareOrEmptyPaths() {
        #expect(BreadcrumbTrail.rootDisplayName(forRootPath: "/") == "Root")
        #expect(BreadcrumbTrail.rootDisplayName(forRootPath: "") == "Root")
    }
}
