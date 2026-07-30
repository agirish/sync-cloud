import Testing
import AppKit
import Design
import Quartz
import SwiftUI
import Sync
@testable import FileExplorer

/// The preview column's *layout*, mounted — the half `ColumnPreviewTests` cannot see.
///
/// Those tests pin the rules (which file, and whether Quick Look may have it). These pin that the
/// rules are actually plumbed into the stack's geometry, which is where this feature can fail
/// silently in the one way that matters: a Columns pane at rest frames its single column to the FULL
/// pane width, so a preview column that is merely appended would be laid out beyond the pane's right
/// edge — present, correct, and permanently off screen.
///
/// Widths are read back off the laid-out AppKit views, never from the constants that produced them.
@MainActor
@Suite struct ColumnPreviewLayoutTests {

    private struct StubDelegate: FileActionDelegate {
        func handleRefresh() {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleDrop(_ nodes: [FileNode], toPath path: String, isMove: Bool) {}
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
    }

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    /// A real directory with real files: the preview's probe is a real `lstat`, and a fabricated
    /// path would classify as `.missing` and never mount Quick Look.
    private final class Fixture {
        let root: String
        let file: String
        init() throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ColumnPreviewLayoutTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            root = dir.path
            let note = dir.appendingPathComponent("note.txt")
            try Data("hello".utf8).write(to: note)
            file = note.path
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }

        func tree() -> PaneTree {
            PaneTree(side: .left, version: 1, nodes: [
                FileNode(id: "\(root)/Folder", name: "Folder", isDirectory: true, children: []),
                FileNode(id: file, name: "note.txt", isDirectory: false, fileSize: 5, kind: "Plain text"),
            ])
        }
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex
        let root: String
        let defaults: UserDefaults

        var body: some View {
            PaneColumnsView(
                tree: tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index, treeRoot: root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                // The Tidy rail — the one surface that shows a preview.
                isSingleSource: true, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }, onBackgroundDeselect: { _ in }
            )
            // Both the preview setting and the column width come from defaults, so the test owns a
            // domain of its own rather than reading whatever the host process happens to hold.
            .defaultAppStorage(defaults)
        }
    }

    /// Mounts the pane at `paneWidth` with `selection` already committed.
    private func mount(
        _ fixture: Fixture, paneWidth: CGFloat, selection: Set<String>, previewEnabled: Bool
    ) -> (window: NSWindow, host: NSHostingView<Harness>) {
        let defaults = ScratchDefaults("ColumnPreviewLayoutTests")
        defaults.set(previewEnabled, forKey: PaneViewMode.previewColumnDefaultsKey)
        defaults.set(Double(PaneViewMode.defaultColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        let box = Box()
        box.selection = selection
        let tree = fixture.tree()
        let host = NSHostingView(rootView: Harness(
            box: box, tree: tree,
            index: PaneChildrenIndex(tree: tree, treeRoot: fixture.root),
            root: fixture.root, defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return (window, host)
    }

    private func pump(_ window: NSWindow, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
    }

    private func previews(in view: NSView) -> [QLPreviewView] {
        descendants(of: view).compactMap { $0 as? QLPreviewView }
    }

    /// Each column's `List` is an `NSTableView`; its enclosing scroll view is the column, so these
    /// widths are the laid-out column widths.
    private func columnWidths(in view: NSView) -> [CGFloat] {
        descendants(of: view)
            .compactMap { ($0 as? NSTableView)?.enclosingScrollView?.frame.width }
    }

    private func descendants(of view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ v: NSView) {
            found.append(v)
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    /// The load-bearing case: selecting a file must step the list column back to `columnWidth` and
    /// hand the rest of the pane to the preview. A column still measuring the full pane width is the
    /// bug this whole suite exists for — the preview would be laid out off the right edge.
    ///
    /// The width is the assertion, and it is a synchronous one: the stack lays out from the
    /// selection, with nothing to wait for. Whether Quick Look has *finished* mounting inside that
    /// column is a separate question, asked separately below — waiting for it here would make this
    /// case's outcome depend on how busy the test host is.
    @Test func testSelectingAFileShrinksTheColumnToMakeRoomForThePreview() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [fixture.file], previewEnabled: true)
        await pump(mounted.window, seconds: 0.3)
        #expect(columnWidths(in: mounted.host) == [PaneViewMode.defaultColumnWidth])
        // Both must outlive the assertions: releasing `fixture` runs its `deinit`, which DELETES the
        // directory the preview's probe reads (a released fixture classifies as `.missing`), and
        // releasing the window tears the hosted views down.
        withExtendedLifetime((fixture, mounted)) {}
    }

    /// The Quick Look mount itself, tested where it is deterministic: `makeNSView` runs during the
    /// layout pass, so hosting the wrapper directly needs no waiting at all.
    ///
    /// Asserted separately from the column because inside the column the mount waits out
    /// `previewSettleDelay` and a probe, both of which resume on the main actor — and in a headless
    /// test host contended by 70-odd other mounted suites, "not yet" is indistinguishable from
    /// "never". The wiring this pins is the part that can actually break in code: that the wrapper
    /// produces a real `QLPreviewView` and hands it the file it was given.
    @Test func testTheQuickLookWrapperMountsAPreviewOfItsFile() throws {
        let fixture = try Fixture()
        let host = NSHostingView(rootView: QuickLookPreview(url: URL(fileURLWithPath: fixture.file)))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()

        let preview = try #require(previews(in: host).first)
        #expect((preview.previewItem as? NSURL) as URL? == URL(fileURLWithPath: fixture.file))
        // Off, or selecting a video would start playing it.
        #expect(preview.autostarts == false)
        withExtendedLifetime((fixture, window)) {}
    }

    /// The resting state Columns is built on, unchanged: nothing selected, one column, the whole
    /// pane. The width is the non-vacuous half of the assertion — it is observed, not waited for —
    /// and the absent preview is checked after twice the settle delay has passed.
    @Test func testAtRestTheColumnStillSpansTheWholePane() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [], previewEnabled: true)
        await pump(mounted.window, seconds: 0.6)
        #expect(columnWidths(in: mounted.host) == [990])
        #expect(previews(in: mounted.host).isEmpty)
        // Both must outlive the assertions: releasing `fixture` runs its `deinit`, which DELETES the
        // directory the preview's probe reads (a released fixture classifies as `.missing`, so the
        // preview never mounts), and releasing the window tears the hosted views down.
        withExtendedLifetime((fixture, mounted)) {}
    }

    /// A folder selection is not a preview target: its click opens its own column instead.
    @Test func testSelectingAFolderLeavesTheRestingLayout() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: ["\(fixture.root)/Folder"],
                            previewEnabled: true)
        await pump(mounted.window, seconds: 0.6)
        #expect(columnWidths(in: mounted.host) == [990])
        #expect(previews(in: mounted.host).isEmpty)
        // Both must outlive the assertions: releasing `fixture` runs its `deinit`, which DELETES the
        // directory the preview's probe reads (a released fixture classifies as `.missing`, so the
        // preview never mounts), and releasing the window tears the hosted views down.
        withExtendedLifetime((fixture, mounted)) {}
    }

    /// The setting is a real switch, and switching it off restores the resting geometry exactly —
    /// not merely a hidden preview beside a shrunken column.
    @Test func testTheSettingOffKeepsThePaneAsItWas() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [fixture.file], previewEnabled: false)
        await pump(mounted.window, seconds: 0.6)
        #expect(columnWidths(in: mounted.host) == [990])
        #expect(previews(in: mounted.host).isEmpty)
        // Both must outlive the assertions: releasing `fixture` runs its `deinit`, which DELETES the
        // directory the preview's probe reads (a released fixture classifies as `.missing`, so the
        // preview never mounts), and releasing the window tears the hosted views down.
        withExtendedLifetime((fixture, mounted)) {}
    }

    /// A pane with no room for a full column beside a minimum preview keeps every point for its
    /// files. Without this the pane would start scrolling sideways because a file was clicked.
    @Test func testATooNarrowPaneKeepsItsWidthForTheFiles() async throws {
        let paneWidth = PaneViewMode.defaultColumnWidth + PaneViewMode.minimumPreviewColumnWidth - 1
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: paneWidth, selection: [fixture.file], previewEnabled: true)
        await pump(mounted.window, seconds: 0.6)
        #expect(columnWidths(in: mounted.host) == [paneWidth])
        #expect(previews(in: mounted.host).isEmpty)
        // Both must outlive the assertions: releasing `fixture` runs its `deinit`, which DELETES the
        // directory the preview's probe reads (a released fixture classifies as `.missing`, so the
        // preview never mounts), and releasing the window tears the hosted views down.
        withExtendedLifetime((fixture, mounted)) {}
    }
}
