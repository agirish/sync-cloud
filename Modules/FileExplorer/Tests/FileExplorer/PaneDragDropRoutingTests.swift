import AppKit
import Foundation
import Testing
import Sync
@testable import FileExplorer

/// Covers the drop-perform path shared by row and background targets
/// (FileTreeView.performPaneDrop): validation gates the delegate call, and the shared
/// drag session is cleared whether the drop is accepted or rejected.
@MainActor
@Suite struct PaneDropPerformTests {

    /// Delegate that records handleDrop calls; everything else is a no-op.
    private final class RecordingDelegate: FileActionDelegate {
        var drops: [(nodes: [FileNode], path: String, isMove: Bool)] = []

        func handleRefresh() {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleDrop(_ nodes: [FileNode], toPath path: String, isMove: Bool) {
            drops.append((nodes, path, isMove))
        }
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
    }

    private let dragged = [FileNode(id: "/left/a.txt", name: "a.txt", isDirectory: false)]

    @Test func testValidDropReachesDelegateAndClearsSession() {
        let delegate = RecordingDelegate()
        let payload = PaneDragPayload(sourceIsLeft: true, nodes: dragged)
        PaneDragSession.shared.active = payload

        let accepted = FileTreeView.performPaneDrop(
            payload, toPath: "/right/dir", targetIsLeft: false, delegate: delegate)

        #expect(accepted)
        #expect(delegate.drops.count == 1)
        #expect(delegate.drops[0].nodes.map(\.id) == ["/left/a.txt"])
        #expect(delegate.drops[0].path == "/right/dir")
        // The modifier is read live from the keyboard at drop time; in a test runner no
        // move modifier is held, so this pins the copy-by-default behavior.
        #expect(delegate.drops[0].isMove == ModifierTracker.moveModifierHeld)
        #expect(PaneDragSession.shared.active == nil)
    }

    @Test func testSamePaneDropIsRejectedWithoutReachingDelegate() {
        let delegate = RecordingDelegate()
        let payload = PaneDragPayload(sourceIsLeft: true, nodes: dragged)
        PaneDragSession.shared.active = payload

        let accepted = FileTreeView.performPaneDrop(
            payload, toPath: "/left/dir", targetIsLeft: true, delegate: delegate)

        #expect(!accepted)
        #expect(delegate.drops.isEmpty)
        // Even a rejected drop ends the drag: the session must not keep a stale payload.
        #expect(PaneDragSession.shared.active == nil)
    }

    @Test func testDropIntoDescendantOfDraggedFolderIsRejectedAtPerformTime() {
        // Perform-time re-validation matters because hover highlights are advisory only.
        let delegate = RecordingDelegate()
        let folder = [FileNode(id: "/shared/dir", name: "dir", isDirectory: true)]
        let payload = PaneDragPayload(sourceIsLeft: true, nodes: folder)
        PaneDragSession.shared.active = payload

        let accepted = FileTreeView.performPaneDrop(
            payload, toPath: "/shared/dir/sub", targetIsLeft: false, delegate: delegate)

        #expect(!accepted)
        #expect(delegate.drops.isEmpty)
        #expect(PaneDragSession.shared.active == nil)
    }
}

/// Covers the app-wide "move instead of copy" modifier rule now shared between the
/// differences list and drag & drop.
@Suite struct ModifierTrackerMoveModifierTests {

    @Test func testShiftOrCommandCountsAsMove() {
        #expect(ModifierTracker.isMoveModifier(.shift))
        #expect(ModifierTracker.isMoveModifier(.command))
        #expect(ModifierTracker.isMoveModifier([.shift, .command]))
        // Extra flags don't disqualify as long as a move modifier is down.
        #expect(ModifierTracker.isMoveModifier([.shift, .option]))
    }

    @Test func testOtherModifiersDoNot() {
        #expect(!ModifierTracker.isMoveModifier([]))
        #expect(!ModifierTracker.isMoveModifier(.option))
        #expect(!ModifierTracker.isMoveModifier(.control))
        #expect(!ModifierTracker.isMoveModifier([.option, .control]))
    }
}

/// The drag payload crosses the drag & drop bridge via CodableRepresentation, so its
/// Codable round-trip must preserve everything a drop target needs.
@Suite struct PaneDragPayloadCodingTests {

    @Test func testPayloadSurvivesCodableRoundTrip() throws {
        let payload = PaneDragPayload(sourceIsLeft: false, nodes: [
            FileNode(id: "/right/dir", name: "dir", isDirectory: true),
            FileNode(id: "/right/b.txt", name: "b.txt", isDirectory: false),
        ])

        let decoded = try JSONDecoder().decode(
            PaneDragPayload.self, from: JSONEncoder().encode(payload))

        #expect(decoded == payload)
        #expect(decoded.sourceIsLeft == false)
        #expect(decoded.nodes.map(\.id) == ["/right/dir", "/right/b.txt"])
        #expect(decoded.nodes.map(\.isDirectory) == [true, false])
    }
}
