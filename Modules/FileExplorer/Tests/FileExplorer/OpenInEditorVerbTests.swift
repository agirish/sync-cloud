import Testing
import Foundation
import SwiftUI
import AppKit
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

/// The verb that hands a row to the Editor, and the rows it is offered on.
///
/// The gate is `PairContentKind`'s text set, the same table the rail filters on. A menu item that
/// opened a JPEG into a text editor would offer something the editor then refuses, so the two
/// surfaces must agree about what "a text file" means.
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
    /// not. This is the classifier alone; that the menu item applies it is asserted by
    /// `thePredicateAgreesWithTheGateTheRowMenuApplies` below.
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

    /// The public predicate the doors outside this package ask, over the whole table.
    /// `PairContentKind` is internal, so the Info inspector and the File menu gate their Open in
    /// Edit on `EditableText.isText`, and it must accept exactly what the row menu's gate accepts.
    /// It loops over `textExtensions`, not a hand-written sample (unlike
    /// `theRailListsTheTextFilesAndPDFsAndOnlyThose`), because the claim is that no entry is
    /// missed.
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

    /// The predicate and the menu item's own gate are one answer, not two that agree today. Checked
    /// against each other over the same inputs, since each against its own list would miss them
    /// drifting apart. The menu is read as drawn, because the item asks `opensInEdit` (text, or a
    /// PDF read-only) rather than the text kind. `openInEditor` is a `@ViewBuilder` that builds
    /// nothing for a row Edit can't open, and an empty build has no size, so deleting the item or
    /// dropping the `if` that gates it fails here.
    @Test func thePredicateAgreesWithTheGateTheRowMenuApplies() {
        let delegate = Recorder()
        for name in ["notes.md", "readme.txt", "Package.swift", "photo.jpg", "report.pdf", "noext"] {
            let drawn = NSHostingView(rootView: AnyView(
                SharedFileMenuItems.openInEditor(name, delegate: delegate).labelsHidden())).fittingSize.height > 0
            #expect(EditableText.opensInEdit(path: name) == drawn,
                    "the predicate and the row menu's gate disagree about \(name)")
        }
        // And the predicate is text OR PDF, nothing wider.
        #expect(EditableText.opensInEdit(path: "notes.md"), "no item was built for a text row — the verb is gone")
        #expect(EditableText.opensInEdit(path: "/a/report.pdf") && EditableText.isPDF(path: "/a/report.pdf"))
        #expect(!EditableText.isText(path: "/a/report.pdf"), "isText must keep meaning text")
        #expect(!EditableText.opensInEdit(path: "/a/photo.jpg"))
    }

    /// The rail lists exactly the text files and the PDFs, spelled out rather than re-derived: an
    /// expectation built with `PairContentKind.classify`, which `EditorRail.entries` filters on,
    /// would move with the code. The photo is not listed.
    @Test func theRailListsTheTextFilesAndPDFsAndOnlyThose() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-verb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["notes.md", "readme.txt", "photo.jpg", "paper.pdf"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let listed = Set(EditorRail.entries(in: folder.path, showsHidden: false,
                                            isCloudOnly: { _ in false }).map(\.name))
        #expect(listed == ["notes.md", "readme.txt", "paper.pdf"], "the rail lists \(listed)")
    }

    /// The menu as drawn, in order, not the source that describes it. The app target pins the order
    /// too (`PaneTabWiringTests.openInEditLeadsTheRowMenusSingleFileBranch`), but by reading the
    /// file as text, which can't see a `@ViewBuilder` branch that never builds. Hosted in a
    /// `VStack`, `FileContextMenu`'s `Group` flattens, so each item is one focus-ring view at its
    /// own y: the drawn order.
    ///
    /// The hosted rows carry no readable text (`accessibilityChildren()` returns an empty group
    /// here, as `OrganizeRailTests` notes), so a row is recognised by its width: each item rendered
    /// alone, then matched in the whole menu. No hard-coded pixel counts, so not machine-pinned; it
    /// assumes the three labels measure differently, and fails loudly if they stop.
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

        // …and the same menu over an archive draws no editor row at all, which makes the index
        // above a fact about this item rather than about whatever sits second.
        let archive = Self.drawnRowWidths(for: "/a/bundle.zip", delegate: delegate)
        #expect(!archive.contains(editorWidth), "an archive row draws Open in Edit")
        #expect(archive.first == refreshWidth && archive.dropFirst().first == getInfoWidth,
                "with no editor item, Get Info should lead the single-file branch")
        // A PDF row draws it, in the same place.
        let pdf = Self.drawnRowWidths(for: "/a/report.pdf", delegate: delegate)
        #expect(pdf.firstIndex(of: editorWidth) == 1, "a PDF row does not lead with Open in Edit")
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
                                   onQuickLook: { _ in }, selectionResolver: PaneSelectionResolver())
        return focusRingFrames(in: AnyView(VStack(alignment: .leading, spacing: 0) { menu }.frame(width: 260)),
                               height: 600).map(\.width)
    }

    /// The hosted focus-ring view of every `Button`, top to bottom. The one handle AppKit gives on
    /// a SwiftUI menu item's box: a `Divider` has none, so these are the items and nothing else.
    private static func focusRingFrames(in view: AnyView, height: CGFloat) -> [CGRect] {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        host.layoutSubtreeIfNeeded()
        return FocusRings.frames(in: host).sorted { $0.minY < $1.minY }
    }
}
