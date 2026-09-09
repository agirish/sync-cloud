import AppKit
import Design
import Quartz
import SwiftUI
import Sync
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The Tree preview's *layout*, mounted — the half `TreePreviewTargetTests` cannot see.
///
/// Those tests pin which file the tree previews. These pin that the answer is plumbed into the
/// pane's geometry, which is where this can fail in the way that costs the most and shows the
/// least: the outline is a `List` that fills whatever it is given, so a preview merely placed
/// beside it would be laid out past the pane's right edge — present, correct, and permanently off
/// screen. Every width below is read back off the laid-out AppKit views, never from the constants
/// that produced them.
@MainActor
@Suite struct TreePreviewLayoutTests {

    private struct StubDelegate: FileActionDelegate {
        func handleRefresh() {}
        func handleOpenInEditor(_ path: String) {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
    }

    private final class Box: ObservableObject {
        @Published var selection: Set<String> = []
        /// Published so a test can flip the setting under a pane that is already on screen — the
        /// app's own comes from `ContentView`'s `@AppStorage`, and the pane takes it as a binding.
        @Published var previewEnabled = true
    }

    /// A real directory with real files: the preview's probe is a real `lstat`, and a fabricated
    /// path classifies as `.missing`, which never mounts Quick Look.
    private final class Fixture {
        let root: String
        let file: String
        let folder: String
        init() throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("TreePreviewLayoutTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            root = dir.path
            let note = dir.appendingPathComponent("note.txt")
            try Data("hello".utf8).write(to: note)
            file = note.path
            let sub = dir.appendingPathComponent("Folder")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            folder = sub.path
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }

        func tree() -> PaneTree {
            PaneTree(side: .left, version: 1, nodes: [
                FileNode(id: folder, name: "Folder", isDirectory: true, children: []),
                FileNode(id: file, name: "note.txt", isDirectory: false, fileSize: 5,
                         kind: UTType.plainText.identifier),
            ])
        }
    }

    /// The pane in TREE mode, mounted the way `ContentView` mounts it. `isSingleSource: true` is the
    /// rail, which carries no action bar — so nothing overlays the preview and the widths read here
    /// are the layout's own.
    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let root: String
        let defaults: UserDefaults

        var body: some View {
            FileTreeView(
                tree: tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: false, currentPath: root,
                selection: $box.selection, otherSelection: [],
                isLeft: true, delegate: StubDelegate(),
                isSingleSource: true,
                viewMode: .tree,
                previewEnabled: Binding(get: { box.previewEnabled },
                                        set: { box.previewEnabled = $0 })
            )
            .defaultAppStorage(defaults)
        }
    }

    private func mount(
        _ fixture: Fixture, paneWidth: CGFloat, selection: Set<String>, previewEnabled: Bool,
        previewWidth: CGFloat = PaneViewMode.defaultPreviewColumnWidth
    ) -> (window: NSWindow, host: NSView, box: Box) {
        let defaults = ScratchDefaults("TreePreviewLayoutTests")
        defaults.set(Double(previewWidth), forKey: PaneViewMode.previewColumnWidthDefaultsKey)
        let box = Box()
        box.previewEnabled = previewEnabled
        box.selection = selection
        let host = NSHostingView(rootView: Harness(
            box: box, tree: fixture.tree(), root: fixture.root, defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return (window, host, box)
    }

    private func descendants(of view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ v: NSView) {
            found.append(v)
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// The outline's laid-out width. The tree is one `List`, so one `NSTableView`, and the scroll
    /// view around it is the area the rows were given.
    private func outlineWidth(in view: NSView) -> CGFloat? {
        descendants(of: view).lazy
            .compactMap { ($0 as? NSTableView)?.enclosingScrollView?.frame.width }.first
    }

    private func quickLookPaths(in view: NSView) -> [String] {
        descendants(of: view).compactMap {
            guard let preview = $0 as? QLPreviewView else { return nil }
            return ((preview.previewItem as? NSURL) as URL?)?.path
        }
    }

    private func pump(_ window: NSWindow, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
    }

    /// The load-bearing case: selecting a file in a tree hands part of the pane to the preview, and
    /// the outline is framed to what is left. An outline still measuring the full pane width is the
    /// bug this suite exists for — the preview would have nowhere to be laid out.
    ///
    /// The width is a synchronous assertion: the pane lays out from the selection, with nothing to
    /// wait for. Whether Quick Look has finished mounting is a separate question, asked separately
    /// below.
    @Test func testSelectingAFileShrinksTheOutlineToMakeRoomForThePreview() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [fixture.file],
                            previewEnabled: true, previewWidth: 420)
        await pump(mounted.window, seconds: 0.3)
        #expect(outlineWidth(in: mounted.host) == 570)
    }

    /// And the preview really is Quick Look, on the file that was selected — not a placeholder that
    /// happens to occupy the right number of points.
    ///
    /// **Waited on a CONDITION, not a clock.** `ColumnPreviewColumn` deliberately holds the mount
    /// back by `previewSettleDelay`, so this is the one assertion here that waits for something
    /// rather than reading a layout that is already final — and what it waits for arrives on
    /// main-actor turns, which a full-package run does not deliver on a wall-clock schedule. A fixed
    /// 1.2s pump passed under `--filter` and failed in the full suite after 124 seconds, having been
    /// granted a handful of turns. `LayoutPumpWait` is the shared loop with a floor in passes; see
    /// its `pumpFloor` note and `docs/flaky-tests.md` mechanism 2.
    @Test func testTheSelectedFileIsHandedToQuickLook() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [fixture.file],
                            previewEnabled: true)
        let settled = await LayoutPumpWait.pump(mounted.window, upTo: 10) {
            !quickLookPaths(in: mounted.host).isEmpty
        }
        try #require(settled.held,
                     "no Quick Look mounted after \(settled.pumps) layout passes — the tree's preview never settled")
        #expect(quickLookPaths(in: mounted.host) == [fixture.file])
    }

    /// With the setting off the pane is exactly the pane it was before this feature: the outline
    /// spans the whole width and nothing is mounted beside it.
    @Test func testTheSettingOffLeavesTheOutlineSpanningThePane() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [fixture.file],
                            previewEnabled: false)
        await pump(mounted.window, seconds: 0.3)
        #expect(outlineWidth(in: mounted.host) == 990)
        #expect(quickLookPaths(in: mounted.host).isEmpty)
    }

    /// The setting is live on a pane already on screen — the pill and ⇧⌘P write the same binding
    /// mid-session, so a pane that only read it at mount would ignore both.
    @Test func testFlippingTheSettingRelaysAMountedPane() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [fixture.file],
                            previewEnabled: true, previewWidth: 420)
        await pump(mounted.window, seconds: 0.3)
        #expect(outlineWidth(in: mounted.host) == 570)

        mounted.box.previewEnabled = false
        await pump(mounted.window, seconds: 0.3)
        #expect(outlineWidth(in: mounted.host) == 990)
    }

    /// A folder click is not a preview. The outline keeps the pane, so selecting folders while
    /// walking a tree never makes the rows jump narrower and back.
    @Test func testAFolderSelectionLeavesTheOutlineSpanningThePane() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [fixture.folder],
                            previewEnabled: true)
        await pump(mounted.window, seconds: 0.3)
        #expect(outlineWidth(in: mounted.host) == 990)
        #expect(quickLookPaths(in: mounted.host).isEmpty)
    }

    /// Below the gate the pane refuses the preview outright rather than showing an illegible pair.
    /// One point under `minimumTreeListWidth + minimumPreviewColumnWidth` is the whole test.
    @Test func testAPaneTooNarrowForBothShowsOnlyTheOutline() async throws {
        let fixture = try Fixture()
        let narrow = PaneViewMode.minimumTreeListWidth + PaneViewMode.minimumPreviewColumnWidth - 1
        let mounted = mount(fixture, paneWidth: narrow, selection: [fixture.file],
                            previewEnabled: true)
        await pump(mounted.window, seconds: 0.3)
        #expect(outlineWidth(in: mounted.host) == narrow)
        #expect(quickLookPaths(in: mounted.host).isEmpty)
    }

    /// The preview never squeezes the outline out of existence: a width dragged past what the pane
    /// can spare is capped, and the outline keeps its floor exactly.
    @Test func testAnOversizedPreviewIsCappedSoTheOutlineSurvives() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 700, selection: [fixture.file],
                            previewEnabled: true,
                            previewWidth: PaneViewMode.maximumPreviewColumnWidth)
        await pump(mounted.window, seconds: 0.3)
        #expect(outlineWidth(in: mounted.host) == PaneViewMode.minimumTreeListWidth)
    }
}
