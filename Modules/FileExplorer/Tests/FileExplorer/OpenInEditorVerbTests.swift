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
