import Testing
import Foundation
import SwiftUI
import AppKit
import Sync
@testable import FileExplorer

/// The verb that hands a row to the Editor, and the rows it is offered on.
///
/// **The gate is `PairContentKind`'s text set — the same table the rail filters on.** A menu item
/// that opened a JPEG into a text editor would offer something the editor then refuses, and the two
/// surfaces disagreeing about what "a text file" means is the thing worth pinning.
@MainActor
@Suite struct OpenInEditorVerbTests {

    /// A delegate that records the hand-off, so the wiring can be asserted rather than assumed.
    private final class Recorder: FileActionDelegate, @unchecked Sendable {
        var opened: [String] = []
        func handleOpenInEditor(_ path: String) { opened.append(path) }
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

    /// The gate the menu item is written with, over the kinds the rail lists and the kinds it does
    /// not. **This is the classifier alone** — that the MENU ITEM actually applies it is asserted
    /// by `theRowMenuOffersTheEditorOnlyForTextFiles` below, which was missing entirely: deleting
    /// `SharedFileMenuItems.openInEditor`, or dropping its `if`, left every test here green.
    @Test func theVerbIsOfferedForTextKindsAndNothingElse() {
        for name in ["notes.md", "readme.txt", "data.json", "run.sh", "Package.swift", "notes.markdown"] {
            #expect(PairContentKind.classify(path: name) == .text,
                    "\(name) is not a text kind, so the row menu would not offer the editor")
        }
        for name in ["photo.jpg", "paper.pdf", "archive.zip", "clip.mov", "app.dmg"] {
            #expect(PairContentKind.classify(path: name) != .text,
                    "\(name) would be offered to a text editor")
        }
    }

    /// **The public predicate the doors outside this package ask, over the whole table.**
    ///
    /// `EditableText.isText` exists because `PairContentKind` is internal and the Info inspector
    /// and the File menu are not: each has to gate its own Open in Edit on the same answer this
    /// menu item does. So the claim worth pinning is agreement — every extension the row menu's
    /// gate accepts, the predicate accepts, and nothing else does. Looping over `textExtensions`
    /// rather than a hand-written sample is deliberate here (and is the opposite of
    /// `theRailListsTheTextFilesAndOnlyThose`'s choice, for the opposite reason): the claim is not
    /// "these six files are text", it is "there is no entry in the table the predicate misses".
    @Test func thePublicPredicateAnswersForEveryTextExtensionAndNoOther() {
        for ext in PairContentKind.textExtensions {
            #expect(EditableText.isText(path: "/a/notes.\(ext)"),
                    "the table lists .\(ext) but the predicate refuses it — a door would withhold it")
        }
        for name in ["photo.jpg", "report.pdf", "archive.zip", "clip.mov", "Makefile", "/a/Downloads"] {
            #expect(!EditableText.isText(path: name),
                    "\(name) reads as text — a door would offer it and the editor would refuse")
        }
        // Case, because a door is handed whatever the filesystem spells.
        #expect(EditableText.isText(path: "/a/READ.MD"), "an upper-cased extension is not matched")
    }

    /// **The predicate and the menu item's own gate are one answer, not two that agree today.**
    ///
    /// The point of the predicate is that the inspector and the File menu cannot drift from this
    /// menu; a test that checks each side against its own hand-written list would not see them
    /// drift apart. This asserts them against each other over the same inputs.
    @Test func thePredicateAgreesWithTheGateTheRowMenuApplies() {
        for name in ["notes.md", "readme.txt", "Package.swift", "photo.jpg", "report.pdf", "noext"] {
            #expect(EditableText.isText(path: name) == (PairContentKind.classify(path: name) == .text),
                    "the predicate and the row menu's gate disagree about \(name)")
        }
    }

    /// **The rail lists exactly the text files, spelled out rather than re-derived.**
    ///
    /// The expectation used to be `names.filter { PairContentKind.classify(path: $0) == .text }` —
    /// the same call `EditorRail.entries` filters on, so both sides of the comparison moved
    /// together and the test could only fail if `contentsOfDirectory` broke. Written out by hand,
    /// it is an independent claim about which of these four files a person should see.
    @Test func theRailListsTheTextFilesAndOnlyThose() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-verb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["notes.md", "readme.txt", "photo.jpg", "paper.pdf"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let listed = Set(EditorRail.entries(in: folder.path, showsHidden: false,
                                            isCloudOnly: { _ in false }).map(\.name))
        #expect(listed == ["notes.md", "readme.txt"], "the rail lists \(listed)")
    }

    /// **The menu item itself, not the classifier it consults.**
    ///
    /// The suite is titled for the verb that hands a row to the Editor and asserted only
    /// `PairContentKind.classify`, a pure function that predates the branch — so deleting
    /// `SharedFileMenuItems.openInEditor` outright, or dropping the `if` that gates it so a JPEG
    /// offered it, went unnoticed by every test in the file. `openInEditor` is a `@ViewBuilder`
    /// returning nothing at all for a non-text row, which is a difference a rendered measurement
    /// can see: an empty build has no size.
    @MainActor
    @Test func theRowMenuOffersTheEditorOnlyForTextFiles() {
        let delegate = Recorder()
        func drawn(_ path: String) -> CGSize {
            NSHostingView(rootView: AnyView(
                SharedFileMenuItems.openInEditor(path, delegate: delegate).labelsHidden()
            )).fittingSize
        }
        let text = drawn("/a/notes.md")
        let image = drawn("/a/photo.jpg")
        #expect(text.height > 0, "no item was built for a text row — the verb is gone")
        #expect(image.height == 0, "an item was built for a JPEG — the text gate is not applied")
    }

    /// **The menu as it is actually DRAWN, in order — not the source that describes it.**
    ///
    /// The order is pinned in the app target too (`PaneTabWiringTests.openInEditLeadsTheRowMenus\
    /// SingleFileBranch`), but that reads the file as text: it cannot see a `@ViewBuilder` branch
    /// that never builds, and this repo has shipped a green geometry test sitting over a control
    /// that was not drawn. Hosting `FileContextMenu` in a `VStack` flattens its `Group` into that
    /// stack, so each item becomes one focus-ring view at its own y — which is the drawn order.
    ///
    /// **Identity by measurement, because the hosted rows carry no readable text.**
    /// `accessibilityChildren()` on a hosting view returns an empty group here (measured, and
    /// recorded in `OrganizeRailTests` for the rail), so a row is recognised by its WIDTH, which is
    /// its label's intrinsic width — each item rendered alone, then matched inside the whole menu.
    /// Nothing is compared against a hard-coded pixel count, so this is not machine-pinned; it does
    /// assume the three labels measure differently, and says so out loud if they ever stop.
    @Test func theDrawnMenuPutsOpenInEditAboveGetInfo() throws {
        let delegate = Recorder()
        let editorWidth = Self.soloWidth(SharedFileMenuItems.openInEditor("/a/notes.md", delegate: delegate))
        let getInfoWidth = Self.soloWidth(SharedFileMenuItems.getInfo(for: "/a/notes.md", delegate: delegate))
        let refreshWidth = Self.soloWidth(SharedFileMenuItems.refresh(delegate: delegate))
        #expect(editorWidth > 0 && getInfoWidth > 0 && refreshWidth > 0, "an item drew nothing at all")
        #expect(Set([editorWidth, getInfoWidth, refreshWidth]).count == 3,
                "two of these labels now measure the same, so a row cannot be told from its neighbour")

        let drawn = Self.drawnRowWidths(for: "/a/notes.md", delegate: delegate)
        #expect(drawn.filter { $0 == editorWidth }.count == 1, "Open in Edit is drawn \(drawn.filter { $0 == editorWidth }.count) times")
        let editor = try #require(drawn.firstIndex(of: editorWidth), "Open in Edit is not drawn at all")
        let getInfo = try #require(drawn.firstIndex(of: getInfoWidth), "Get Info is not drawn at all")
        #expect(editor < getInfo, "Open in Edit is drawn below Get Info")
        // Refresh and its divider are all that precede it: the item leads the single-file branch.
        #expect(editor == 1, "Open in Edit is the \(editor + 1)th item drawn, not the first after Refresh")
        #expect(drawn.first == refreshWidth, "Refresh no longer leads the menu")

        // …and the same menu over a PDF draws no editor row at all, which is what makes the index
        // above a fact about THIS item rather than about whatever sits second.
        let pdf = Self.drawnRowWidths(for: "/a/report.pdf", delegate: delegate)
        #expect(!pdf.contains(editorWidth), "a PDF row draws Open in Edit")
        #expect(pdf.first == refreshWidth && pdf.dropFirst().first == getInfoWidth,
                "with no editor item, Get Info should lead the single-file branch")
    }

    /// One item hosted alone, measured at the width the menu gives it.
    private static func soloWidth<V: View>(_ item: V) -> CGFloat {
        focusRingFrames(in: AnyView(VStack(alignment: .leading) { item }.frame(width: 260)), height: 80)
            .first?.width ?? 0
    }

    /// Every item of the row menu for `path`, in drawn order, as widths.
    private static func drawnRowWidths(for path: String, delegate: FileActionDelegate) -> [CGFloat] {
        let node = FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
        let menu = FileContextMenu(row: PaneRow(side: .left, version: 1, node: node, children: nil),
                                   selection: [],
                                   tree: PaneTree(side: .left, version: 1, nodes: [node]),
                                   otherTree: PaneTree(side: .right, version: 1, nodes: []),
                                   otherSelection: [], isLeft: true, currentPath: "/a",
                                   delegate: delegate, otherPaneName: "Right", isSingleSource: false,
                                   onQuickLook: { _ in })
        return focusRingFrames(in: AnyView(VStack(alignment: .leading, spacing: 0) { menu }.frame(width: 260)),
                               height: 600).map(\.width)
    }

    /// The hosted focus-ring view of every `Button`, top to bottom. The one handle AppKit gives on
    /// a SwiftUI menu item's box: a `Divider` has none, so these are the items and nothing else.
    private static func focusRingFrames(in view: AnyView, height: CGFloat) -> [CGRect] {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        host.layoutSubtreeIfNeeded()
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("FocusRing") { found.append(v.frame) }
            v.subviews.forEach(walk)
        }
        walk(host)
        return found.sorted { $0.minY < $1.minY }
    }

    /// **The delegate the app really wires, forwarding the path to the closure ContentView hands
    /// it.** This asserted a test double calling its own recorder — no production symbol was in
    /// the room, so `PaneActionDelegate.handleOpenInEditor` could have been deleted and it passed.
    /// That delegate lives in the app target, so the real test lives beside it, in
    /// `SyncCloudTests/EditorHandOffTests.swift`.
    @Test func theRecorderUsedByTheseTestsRecords() {
        let recorder = Recorder()
        recorder.handleOpenInEditor("/a/b/notes.md")
        #expect(recorder.opened == ["/a/b/notes.md"], "the double these tests rely on does not record")
    }
}
