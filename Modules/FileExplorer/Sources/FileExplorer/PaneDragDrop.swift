import CoreTransferable
import Sync
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Pane-to-pane drag payload. Only produced and consumed inside the app, so it is not
    /// declared in the Info.plist; other apps see opaque data they won't accept.
    static let paneDragPayload = UTType(exportedAs: "com.abhishekgirish.synccloud.pane-drag")
}

/// Everything a drop target needs to know about an in-flight row drag: the resolved
/// (multi-selection aware, pruned) nodes and which pane they came from, so targets can
/// reject same-pane drops.
struct PaneDragPayload: Codable, Equatable, Transferable {
    let sourceIsLeft: Bool
    let nodes: [FileNode]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .paneDragPayload)
    }
}

/// Publishes the payload of the drag currently in flight. SwiftUI's `dropDestination` only
/// delivers the payload when the drop is performed, so targets consult this to decide whether
/// to show a highlight while hovering. Set when a drag begins; cleared on drop. A cancelled
/// drag leaves a stale value behind, which is harmless: it is only read while a target is
/// actively hovered, and the next drag overwrites it.
@MainActor
final class PaneDragSession: ObservableObject {
    static let shared = PaneDragSession()
    @Published var active: PaneDragPayload?

    private init() {}
}

/// Pure drag & drop rules for the two comparison panes, kept UI-free so they are unit-testable.
enum PaneDropLogic {
    /// The nodes a drag starting on `node` carries: the whole multi-selection when the dragged
    /// row is part of it (same semantics as the context menu), pruned so a folder and its
    /// descendants never travel together, and slimmed of `children` — the transfer operations
    /// only use each node's path and name, and a deep folder would otherwise serialize its
    /// entire subtree into the drag item.
    static func dragNodes(for node: FileNode, selection: Set<String>, tree: [FileNode]) -> [FileNode] {
        FileContextMenu.resolvedSelection(node: node, selection: selection, tree: tree)
            .pruneNestedNodes()
            .map { n in
                var slim = n
                slim.children = nil
                return slim
            }
    }

    /// Whether dropping `draggedIds` (dragged from the pane where `sourceIsLeft`) onto the
    /// directory at `targetDirectoryPath` in the pane where `targetIsLeft` is allowed.
    /// Rejects drops onto the source pane (which also keeps same-pane drags into subfolders
    /// unsupported rather than half-working), onto a dragged item itself, and into a
    /// descendant of a dragged folder.
    static func canDrop(draggedIds: [String], sourceIsLeft: Bool, targetIsLeft: Bool, targetDirectoryPath: String) -> Bool {
        guard sourceIsLeft != targetIsLeft, !draggedIds.isEmpty else { return false }
        var target = targetDirectoryPath
        while target.count > 1 && target.hasSuffix("/") {
            target.removeLast()
        }
        for id in draggedIds {
            if id == target || target.hasPrefix(id + "/") {
                return false
            }
        }
        return true
    }
}
