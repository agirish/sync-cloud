import Testing
import AppKit
import Design
import Quartz
import SwiftUI
import Sync
import UniformTypeIdentifiers
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
        /// The preview setting, published so `testFlippingTheSettingRelaysAMountedPane` can flip it
        /// under a pane that is already on screen. The pane takes it as a binding — the app's comes
        /// from `ContentView`, whose two `@AppStorage` properties are what make Browse's answer
        /// separate from Compare's — so a test that wants a LIVE flip has to own something
        /// observable, exactly as the host does.
        @Published var previewEnabled = true
    }

    /// A real directory with real files: the preview's probe is a real `lstat`, and a fabricated
    /// path would classify as `.missing` and never mount Quick Look.
    private final class Fixture {
        let root: String
        let file: String
        /// A file one level down, for the stacks that need two columns open.
        let nestedFile: String
        init() throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ColumnPreviewLayoutTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            root = dir.path
            let note = dir.appendingPathComponent("note.txt")
            try Data("hello".utf8).write(to: note)
            file = note.path
            let sub = dir.appendingPathComponent("Folder")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let nested = sub.appendingPathComponent("nested.txt")
            try Data("nested".utf8).write(to: nested)
            nestedFile = nested.path
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }

        func tree() -> PaneTree {
            PaneTree(side: .left, version: 1, nodes: [
                FileNode(id: "\(root)/Folder", name: "Folder", isDirectory: true, children: [
                    FileNode(id: nestedFile, name: "nested.txt", isDirectory: false, fileSize: 6,
                             kind: UTType.plainText.identifier),
                ]),
                FileNode(id: file, name: "note.txt", isDirectory: false, fileSize: 5,
                         kind: UTType.plainText.identifier),
            ])
        }
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex
        let root: String
        let defaults: UserDefaults
        /// The surface. Defaults to the single-source rail, which is where the preview started; `false` is a
        /// comparison pane, which gets the same preview since the rail-only gate came out.
        var isSingleSource: Bool = true
        /// Non-nil exactly on a surface that shows the action bar — the signal the preview column
        /// reads to hold a band clear for it. `nil` is the rail's value.
        var placement: PaneBarPlacement?

        var body: some View {
            PaneColumnsView(
                tree: tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index, treeRoot: root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: isSingleSource, density: .compact, isActivePane: true,
                placement: placement, onBarEdgeFlip: nil, onQuickLook: { _ in },
                onBackgroundDeselect: { _ in },
                // From the box, not `defaults`: which stored key a surface reads is the host's
                // decision, so the pane holds no `@AppStorage` for it. The column and preview
                // WIDTHS still come from `defaults`.
                previewEnabled: Binding(get: { box.previewEnabled },
                                        set: { box.previewEnabled = $0 })
            )
            // The column and preview WIDTHS come from defaults, so the test owns a domain of its own
            // rather than reading whatever the host process happens to hold. (The preview's on/off
            // setting is threaded in as a binding — see `previewEnabled` above.)
            .defaultAppStorage(defaults)
            // A known ground, for the one test here that reads PIXELS rather than view frames. A
            // hosted pane with no background renders over an undefined backing, and every pixel then
            // reads as ink — which is exactly how the clearance measurement first came back as
            // "lowest painted row = the last row" for both sides, a lift of zero that looked like a
            // broken fix. The frame-reading tests are indifferent to it.
            .background(Color.white)
        }
    }

    /// Mounts the pane at `paneWidth` with `selection` already committed.
    private func mount(
        _ fixture: Fixture, paneWidth: CGFloat, selection: Set<String>, previewEnabled: Bool,
        browsePath: PaneBrowsePath = PaneBrowsePath(),
        columnWidth: CGFloat = PaneViewMode.defaultColumnWidth,
        previewWidth: CGFloat = PaneViewMode.defaultPreviewColumnWidth,
        isSingleSource: Bool = true,
        placement: PaneBarPlacement? = nil
    ) -> (window: NSWindow, host: NSHostingView<Harness>) {
        let defaults = ScratchDefaults("ColumnPreviewLayoutTests")
        defaults.set(Double(columnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        defaults.set(Double(previewWidth), forKey: PaneViewMode.previewColumnWidthDefaultsKey)
        let box = Box()
        box.previewEnabled = previewEnabled
        box.selection = selection
        box.browsePath = browsePath
        let tree = fixture.tree()
        let host = NSHostingView(rootView: Harness(
            box: box, tree: tree,
            index: PaneChildrenIndex(tree: tree, treeRoot: fixture.root),
            root: fixture.root, defaults: defaults, isSingleSource: isSingleSource,
            placement: placement))
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

    /// The column stack's own scroll view is the outermost one. Its FRAME is the area the columns
    /// were given — the pane minus the pinned preview — which is the only place the preview's width
    /// is observable, since the preview holds no AppKit view of its own until Quick Look mounts.
    private func stackViewportWidth(in view: NSView) -> CGFloat? {
        descendants(of: view).lazy.compactMap { ($0 as? NSScrollView)?.frame.width }.first
    }

    /// The scrolling content's width — the columns alone, now that the preview is not in it.
    private func stackDocumentWidth(in view: NSView) -> CGFloat? {
        descendants(of: view).lazy.compactMap { ($0 as? NSScrollView)?.documentView?.frame.width }.first
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

    /// The load-bearing case: selecting a file must hand part of the pane to the preview. A column
    /// still measuring the full pane width is the bug this whole suite exists for — the preview
    /// would have nowhere to be laid out.
    ///
    /// The lone column fills what is LEFT rather than stepping back to `columnWidth`. It has no
    /// divider — dividers are only drawn between columns, and the seam at the preview is the
    /// preview's — so a column pinned to `columnWidth` here would be narrow, flanked by dead space,
    /// and impossible to widen. Filling its area is what makes that unnecessary.
    ///
    /// The width is the assertion, and it is a synchronous one: the stack lays out from the
    /// selection, with nothing to wait for. Whether Quick Look has *finished* mounting inside that
    /// column is a separate question, asked separately below — waiting for it here would make this
    /// case's outcome depend on how busy the test host is.
    @Test func testSelectingAFileShrinksTheColumnToMakeRoomForThePreview() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [fixture.file], previewEnabled: true,
                            previewWidth: 420)
        await pump(mounted.window, seconds: 0.3)
        #expect(columnWidths(in: mounted.host) == [570])
        #expect(stackViewportWidth(in: mounted.host) == 570)
        // Both must outlive the assertions: releasing `fixture` runs its `deinit`, which DELETES the
        // directory the preview's probe reads (a released fixture classifies as `.missing`), and
        // releasing the window tears the hosted views down.
        withExtendedLifetime((fixture, mounted)) {}
    }

    /// A comparison pane gets the preview too, and gets it on the same terms as the rail.
    ///
    /// This was the rail's alone until the `isSingleSource` gate came out of
    /// `PaneColumnsView.previewItem`. Asserted as an equality against the rail rather than against a
    /// literal 570, because the claim is not "a comparison pane reserves 420 points" but "the surface
    /// no longer enters into it" — a rule that stayed surface-dependent in some *other* term would
    /// still satisfy a hard-coded number on this side.
    ///
    /// The second half is what makes the header's new pill worth having there: the setting still
    /// governs the pane, so the switch we now offer a comparison pane is a switch that does something.
    @Test func testAComparisonPaneGetsThePreviewToo() async throws {
        let fixture = try Fixture()
        let rail = mount(fixture, paneWidth: 990, selection: [fixture.file], previewEnabled: true,
                         previewWidth: 420)
        let compare = mount(fixture, paneWidth: 990, selection: [fixture.file], previewEnabled: true,
                            previewWidth: 420, isSingleSource: false)
        await pump(rail.window, seconds: 0.3)
        await pump(compare.window, seconds: 0.3)
        #expect(columnWidths(in: compare.host) == columnWidths(in: rail.host))
        #expect(stackViewportWidth(in: compare.host) == stackViewportWidth(in: rail.host))
        // Non-vacuous: the pane really did give room away, rather than both sides reporting nothing.
        #expect(columnWidths(in: compare.host) == [570])

        // And the setting still rules it here — off, the comparison pane keeps every point.
        let off = mount(fixture, paneWidth: 990, selection: [fixture.file], previewEnabled: false,
                        previewWidth: 420, isSingleSource: false)
        await pump(off.window, seconds: 0.3)
        #expect(columnWidths(in: off.host) == [990])
        withExtendedLifetime((fixture, rail, compare, off)) {}
    }

    /// The clearance is WIRED, not merely available: a pane that has an action bar paints its
    /// preview's last ink higher up the column than the same pane without one.
    ///
    /// `ColumnPreviewClearanceTests` proves the column honours the parameter and that the constant
    /// covers the real bar. Neither notices if `PaneColumnsView` passes 0 — the exact shape of "the
    /// fix exists but is connected to nothing" that this review turned up in the header. Measured on
    /// the mounted pane, restricted to the preview's own x-band so the columns' rows cannot supply
    /// the ink.
    @Test func testAPaneWithAnActionBarHoldsRoomForItInThePreview() async throws {
        let fixture = try Fixture()
        let bar = mount(fixture, paneWidth: 990, selection: [fixture.file], previewEnabled: true,
                        previewWidth: 420, isSingleSource: false, placement: PaneBarPlacement())
        let none = mount(fixture, paneWidth: 990, selection: [fixture.file], previewEnabled: true,
                         previewWidth: 420, isSingleSource: false)
        await pump(bar.window, seconds: 0.4)
        await pump(none.window, seconds: 0.4)

        // The preview occupies the trailing 420pt of the 990pt pane (x 570…990). The band starts
        // INSIDE that, past the resize divider: the divider is an overlay on the preview's leading
        // edge running the column's full height, so a band that included x=570 would find its ink at
        // the very bottom row in both renders and report a lift of zero whatever the fix did. Learned
        // by measuring — the first version of this test failed for exactly that reason.
        let band = CGFloat(600)..<CGFloat(980)
        let withBar = try lowestInk(in: bar.host, xRange: band)
        let withoutBar = try lowestInk(in: none.host, xRange: band)
        #expect(withoutBar > 0, "nothing was painted in the preview band — the measurement is vacuous")
        #expect(withBar > 0)
        let lifted = withoutBar - withBar
        #expect(abs(lifted - ColumnPreviewColumn.actionBarClearance) <= 2,
                "expected the bar's band to be held clear (\(ColumnPreviewColumn.actionBarClearance)pt), lifted \(lifted)")
        withExtendedLifetime((fixture, bar, none)) {}
    }

    /// Lowest painted row inside a mounted pane, in points from the top of the host.
    private func lowestInk(in host: NSHostingView<Harness>, xRange: Range<CGFloat>) throws -> CGFloat {
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(PaintedInk.lowestRow(in: rep, pointHeight: host.bounds.height,
                                                 pointXRange: xRange))
    }

    /// Flipping the setting re-lays a pane that is ALREADY on screen — which is the toggle's entire
    /// job, and the one thing none of these tests covered.
    ///
    /// Every other case here mounts a pane with the setting already at its final value, so all of
    /// them would pass against a pane that read the preference once and never looked again. The pill
    /// in the header writes this binding from a different view entirely; nothing but a live flip
    /// proves the pane hears it. Asserted in both directions, because "off" and "on" reach the layout
    /// through different branches — off must give the width back, not merely hide the preview.
    @Test func testFlippingTheSettingRelaysAMountedPane() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 990, selection: [fixture.file], previewEnabled: true,
                            previewWidth: 420, isSingleSource: false)
        await pump(mounted.window, seconds: 0.3)
        #expect(columnWidths(in: mounted.host) == [570])

        mounted.host.rootView.box.previewEnabled = false
        await pump(mounted.window, seconds: 0.5)
        #expect(columnWidths(in: mounted.host) == [990], "turning the preview off must return its width")
        #expect(previews(in: mounted.host).isEmpty)

        mounted.host.rootView.box.previewEnabled = true
        await pump(mounted.window, seconds: 0.5)
        #expect(columnWidths(in: mounted.host) == [570], "turning it back on must take the width again")
        withExtendedLifetime((fixture, mounted)) {}
    }

    /// The point of the whole reshape, mounted: a wide preview must take its width from the SCROLL
    /// VIEW, leaving the columns their own width and their scrolling intact.
    ///
    /// Two columns of 260 need 520; the preview takes 600 of a 900pt pane, so the columns are left a
    /// 300pt viewport holding 520pt of content — narrower than what it holds, which is exactly the
    /// scrollbar that used to disappear when the preview grew. A layout that still derived the
    /// preview from the columns' slack could not produce these numbers: it would have given the
    /// columns the whole pane and the preview 380.
    @Test func testAWidePreviewLeavesTheColumnsScrolling() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, paneWidth: 900, selection: [fixture.nestedFile],
                            previewEnabled: true, browsePath: PaneBrowsePath(components: ["Folder"]),
                            columnWidth: 260, previewWidth: 600)
        await pump(mounted.window, seconds: 0.3)
        #expect(columnWidths(in: mounted.host) == [260, 260])
        #expect(stackViewportWidth(in: mounted.host) == 300)
        let document = try #require(stackDocumentWidth(in: mounted.host))
        #expect(document == 520)
        #expect(document > 300, "the columns must still overflow their viewport, i.e. still scroll")
        withExtendedLifetime((fixture, mounted)) {}
    }

    /// The preview's width is its own: the same drag gives the same preview whether the columns
    /// beside it are wide or narrow. Under the old rule the columns' width decided it entirely.
    @Test func testThePreviewKeepsItsWidthWhateverTheColumnsDo() async throws {
        let fixture = try Fixture()
        let wide = mount(fixture, paneWidth: 900, selection: [fixture.file],
                         previewEnabled: true, columnWidth: 320, previewWidth: 500)
        let narrow = mount(fixture, paneWidth: 900, selection: [fixture.file],
                           previewEnabled: true, columnWidth: 150, previewWidth: 500)
        await pump(wide.window, seconds: 0.3)
        await pump(narrow.window, seconds: 0.3)
        #expect(stackViewportWidth(in: wide.host) == 400)
        #expect(stackViewportWidth(in: narrow.host) == 400)
        // A lone column takes the viewport whatever `columnWidth` says, so both fill it — the case
        // that used to leave a 150pt column stranded beside a band of dead space.
        #expect(columnWidths(in: wide.host) == [400])
        #expect(columnWidths(in: narrow.host) == [400])
        withExtendedLifetime((fixture, wide, narrow)) {}
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
