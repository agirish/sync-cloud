import Testing
import SwiftUI
import Sync
@testable import FileExplorer

/// The empty-pane placeholder classification: validity, enablement, tree emptiness and loading must
/// map to distinct states, so a genuinely empty folder is never conflated with a misconfigured
/// provider root.
@Suite struct PaneEmptyStateTests {

    private func classify(
        treeIsEmpty: Bool = true,
        isLoading: Bool = false,
        providerIsEnabled: Bool = true,
        rootIsValid: Bool = true,
        hasOnlyHiddenEntries: Bool = false
    ) -> PaneEmptyState {
        PaneEmptyState.classify(
            treeIsEmpty: treeIsEmpty,
            isLoading: isLoading,
            providerIsEnabled: providerIsEnabled,
            rootIsValid: rootIsValid,
            hasOnlyHiddenEntries: hasOnlyHiddenEntries
        )
    }

    @Test func testNonEmptyTreeShowsNoPlaceholderRegardlessOfProblems() {
        // Rows on screen always win: even stale validity or a disabled provider must not overlay a
        // tree the user can still browse.
        #expect(classify(treeIsEmpty: false) == .none)
        #expect(classify(treeIsEmpty: false, isLoading: true) == .none)
        #expect(classify(treeIsEmpty: false, providerIsEnabled: false, rootIsValid: false) == .none)
    }

    @Test func testLoadingWinsOverEveryOtherState() {
        // While the walk runs the pane shows the scanning state, whatever else is true.
        #expect(classify(isLoading: true) == .loading)
        #expect(classify(isLoading: true, providerIsEnabled: false) == .loading)
        #expect(classify(isLoading: true, rootIsValid: false) == .loading)
        #expect(classify(isLoading: true, hasOnlyHiddenEntries: true) == .loading)
    }

    @Test func testDisabledProviderOutranksInvalidRoot() {
        // Re-enabling is the actionable fix; the root may be stale-invalid on top.
        #expect(classify(providerIsEnabled: false) == .providerDisabled)
        #expect(classify(providerIsEnabled: false, rootIsValid: false) == .providerDisabled)
    }

    @Test func testInvalidRootIsDistinctFromEmptyFolder() {
        #expect(classify(rootIsValid: false) == .invalidRoot)
        #expect(classify(rootIsValid: false, hasOnlyHiddenEntries: true) == .invalidRoot)
    }

    @Test func testEmptyFolderCarriesHiddenEntriesHint() {
        #expect(classify() == .emptyFolder(hasOnlyHiddenEntries: false))
        #expect(classify(hasOnlyHiddenEntries: true) == .emptyFolder(hasOnlyHiddenEntries: true))
    }
}

/// FileTreeView must derive its placeholder from the plumbed-in flags, and callers that don't plumb
/// them must classify by the defaults: valid and enabled.
@MainActor
@Suite struct FileTreeViewEmptyStateTests {

    private func treeView(
        tree: [FileNode] = [],
        isLoading: Bool = false,
        rootPathIsValid: Bool = true,
        providerIsEnabled: Bool = true,
        hasOnlyHiddenEntries: Bool = false,
        rootPath: String? = nil
    ) -> FileTreeView {
        FileTreeView(
            tree: PaneTree(side: .left, version: 0, nodes: tree),
            otherTree: PaneTree(side: .right, version: 0, nodes: []),
            isLoading: isLoading, currentPath: "/root/focused",
            selection: .constant([]), otherSelection: [],
            isLeft: true, delegate: NoOpFileActionDelegate(),
            rootPathIsValid: rootPathIsValid, providerIsEnabled: providerIsEnabled,
            hasOnlyHiddenEntries: hasOnlyHiddenEntries, rootPath: rootPath
        )
    }

    @Test func testViewDerivesStateFromFlags() {
        #expect(treeView().emptyState == .emptyFolder(hasOnlyHiddenEntries: false))
        #expect(treeView(isLoading: true).emptyState == .loading)
        #expect(treeView(rootPathIsValid: false).emptyState == .invalidRoot)
        #expect(treeView(providerIsEnabled: false).emptyState == .providerDisabled)
        #expect(treeView(hasOnlyHiddenEntries: true).emptyState == .emptyFolder(hasOnlyHiddenEntries: true))
    }

    @Test func testInvalidPlaceholderShowsProviderRootNotFocusedPath() {
        // Validity is root-scoped, so the offending path shown must be the root the user
        // configures in Settings, not whatever subfolder the pane happens to focus.
        #expect(treeView(rootPathIsValid: false, rootPath: "/root").rootPath == "/root")
    }

    @Test func testRootPathDefaultsToCurrentPathWhenNotPlumbed() {
        #expect(treeView(rootPath: nil).rootPath == "/root/focused")
    }
}
