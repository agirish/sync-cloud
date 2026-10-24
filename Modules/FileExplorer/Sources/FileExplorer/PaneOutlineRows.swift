import SwiftUI
import Sync
import Design

/// The pane's outline, as recursive `DisclosureGroup`s over an expansion set the pane owns.
///
/// **Why this is not `OutlineGroup`.** It was, and the two draw the same thing —
/// `OutlineGroup` in a `List` *is* nested `DisclosureGroup`s, which is why the label keeps every
/// modifier it carried before (tag, context menu, row background, position probe) in the same
/// position. What `OutlineGroup` does not have is any way to say “open the ancestors of this path”:
/// it owns its expansion state privately, with no API to write it. Search has to reveal a hit, so
/// the state has to be somewhere the search can reach — which is the whole of this change. A
/// pane-side fold-all becomes possible for the same reason, and was not before.
///
/// **Identity is unchanged.** `ForEach` keys on `PaneRow.id`, which is the node's absolute path —
/// exactly what `OutlineGroup` keyed on — so a republish keeps every row's expansion, selection and
/// scroll position where it was. `PaneRow`'s own `==` is (side, version, path), so walking these
/// rows never costs a deep `FileNode` comparison.
///
/// **`nil` children and `[]` children still differ**, and must: the projection preserves `nil` for a
/// leaf and `[]` for an empty directory, and that distinction is what decides whether a row gets a
/// disclosure triangle at all. A leaf renders as a bare row here exactly as it did there.
struct PaneOutlineRows<Row: View>: View {
    let rows: [PaneRow]
    /// The paths whose children are showing. Owned by the pane (so the search can write it), shared
    /// by every level of the recursion.
    @Binding var expanded: Set<String>
    /// **Asks for a directory the walk did not read**, when one is opened here.
    ///
    /// The Columns presentation has had this since the node budget landed; the outline did not, and
    /// the gap was invisible because it looks like an ordinary empty folder — past
    /// `FileSyncManager.paneNodeBudget` a directory arrives with `children: []` and `isUnexplored`,
    /// which draws a disclosure triangle that opens onto nothing and stays that way for as long as
    /// the pane is on that root. Same fix as the column's, at the moment the user asks: expanding
    /// IS the request.
    let onNeedChildren: (String) -> Void
    /// The pane's walk is running — during the shallow first paint every folder is unexplored, so
    /// an opened empty folder says nothing rather than "Can’t be read". See ``placeholder(for:isLoading:graftsInFlight:)``.
    let isLoading: Bool
    /// Folders whose deferred listing is running right now: an opened one shows a spinner rather
    /// than "Can’t be read".
    let graftsInFlight: Set<String>
    let row: (PaneRow) -> Row

    init(rows: [PaneRow], expanded: Binding<Set<String>>,
         onNeedChildren: @escaping (String) -> Void = { _ in },
         isLoading: Bool = false, graftsInFlight: Set<String> = [],
         @ViewBuilder row: @escaping (PaneRow) -> Row) {
        self.rows = rows
        self._expanded = expanded
        self.onNeedChildren = onNeedChildren
        self.isLoading = isLoading
        self.graftsInFlight = graftsInFlight
        self.row = row
    }

    var body: some View {
        ForEach(rows) { paneRow in
            if let children = paneRow.children {
                DisclosureGroup(isExpanded: isExpanded(paneRow.node.id,
                                                       isUnexplored: paneRow.node.isUnexplored == true)) {
                    if let caption = Self.placeholder(for: paneRow, isLoading: isLoading,
                                                      graftsInFlight: graftsInFlight) {
                        Self.placeholderRow(caption)
                            // A folder opened from a restored expansion was never asked for — the
                            // binding's setter asks only on a click. The column asks on appear for
                            // the same reason, under the same rule.
                            .onAppear {
                                if PaneColumnsView.asksForChildren(
                                    isLoading: isLoading,
                                    isUnexplored: paneRow.node.isUnexplored == true) {
                                    onNeedChildren(paneRow.node.id)
                                }
                            }
                    } else {
                        PaneOutlineRows(rows: children, expanded: $expanded,
                                        onNeedChildren: onNeedChildren, isLoading: isLoading,
                                        graftsInFlight: graftsInFlight, row: row)
                    }
                } label: {
                    row(paneRow)
                }
            } else {
                row(paneRow)
            }
        }
    }

    /// One row's disclosure state, projected out of the shared set.
    ///
    /// A computed `Binding` rather than per-row state: the set is the pane's, so a reveal written
    /// into it opens the row on the next render whether or not that row is currently realized —
    /// which is the point. `List` recycles rows freely, and a row that has never been on screen must
    /// still come back open if the search opened it.
    /// The expansion binding for one row, reachable from tests.
    ///
    /// `isExpanded` is private and called from the view body, so the decision it carries — that
    /// opening an unread row IS the request for its contents — could otherwise only be checked by
    /// mounting a `DisclosureGroup` and testing SwiftUI rather than this rule.
    func expansionBindingForTesting(_ row: PaneRow) -> Binding<Bool> {
        isExpanded(row.node.id, isUnexplored: row.node.isUnexplored == true)
    }

    /// **What an opened folder with nothing under it says (BR14).** The tree expanded onto nothing
    /// for an empty folder and an unreadable one alike, where Columns says "Empty" or
    /// "Can’t be read". This is the column's own rule (`PaneColumnsView.emptyCaption`), asked as
    /// a column one level in — so the two presentations cannot word one state two ways. `nil` for
    /// a folder with children, for a file, and while the pane's walk runs.
    static func placeholder(for row: PaneRow, isLoading: Bool,
                            graftsInFlight: Set<String>) -> PaneColumnsView.Caption? {
        guard let children = row.children, children.isEmpty else { return nil }
        return PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1,
                                            isUnexplored: row.node.isUnexplored == true,
                                            isLoading: isLoading,
                                            isBeingRead: graftsInFlight.contains(row.node.id))
    }

    /// The one dimmed child row that says it — the column's caption, in the column's type and ink.
    /// Untagged, so the `List` never selects it.
    @ViewBuilder
    static func placeholderRow(_ caption: PaneColumnsView.Caption) -> some View {
        Group {
            if let text = caption.text {
                Text(text)
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .allowsHitTesting(false)
    }

    /// - Parameter isUnexplored: whether this row's children were never walked. Opening such a row
    ///   is the request for them — see `onNeedChildren`. Asked on OPEN only: a request on close
    ///   would fire on the way out of a folder somebody is done with, and the collapse animation is
    ///   the worst moment to start a directory listing.
    private func isExpanded(_ id: String, isUnexplored: Bool) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen {
                    expanded.insert(id)
                    if isUnexplored { onNeedChildren(id) }
                } else {
                    expanded.remove(id)
                }
            }
        )
    }
}
