import SwiftUI
import Sync
import Design

/// The pane's outline, as recursive `DisclosureGroup`s over an expansion set the pane owns.
///
/// Not `OutlineGroup`, which draws the same nested `DisclosureGroup`s but keeps its expansion
/// private, with no way to open a path's ancestors. Search must reveal a hit, and the pane can fold
/// all, so the state lives where both can write it.
///
/// `ForEach` keys on `PaneRow.id`, the node's absolute path, so a republish keeps each row's
/// expansion, selection and scroll position. `PaneRow`'s `==` is (side, version, path), so walking
/// rows never costs a deep `FileNode` comparison.
///
/// `nil` children (a leaf) and `[]` (an empty directory) must stay distinct: that decides whether a
/// row gets a disclosure triangle.
struct PaneOutlineRows<Row: View>: View {
    let rows: [PaneRow]
    /// The paths whose children are showing. Owned by the pane (so the search can write it), shared
    /// by every level of the recursion.
    @Binding var expanded: Set<String>
    /// Asks for a directory the walk did not read, when one is opened here. Past
    /// `FileSyncManager.paneNodeBudget` a directory arrives with `children: []` and `isUnexplored`,
    /// and would open onto nothing; as in Columns, expanding is the request.
    ///
    /// The second argument is `passive`: `true` only for the placeholder's `onAppear`, which fires
    /// on every scroll past, so the manager may hold back a folder it already found unreadable.
    /// Opening a row passes `false`: a person asking again is a retry (`loadColumnChildren`).
    let onNeedChildren: (String, Bool) -> Void
    /// The pane's walk is running. During the shallow first paint every folder is unexplored, so an
    /// opened empty folder says nothing rather than "Can’t be read".
    /// See ``placeholder(for:isLoading:graftsInFlight:)``.
    let isLoading: Bool
    /// Folders whose deferred listing is running right now: an opened one shows a spinner rather
    /// than "Can’t be read".
    let graftsInFlight: Set<String>
    let row: (PaneRow) -> Row

    init(rows: [PaneRow], expanded: Binding<Set<String>>,
         onNeedChildren: @escaping (String, Bool) -> Void = { _, _ in },
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
                            // A folder opened from a restored expansion was never asked for (the
                            // setter asks only on a click), so ask on appear, as the column does.
                            .onAppear {
                                if PaneColumnsView.asksForChildren(
                                    isLoading: isLoading,
                                    isUnexplored: paneRow.node.isUnexplored == true) {
                                    onNeedChildren(paneRow.node.id, true) // passive: a scroll past
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

    /// The expansion binding for one row, reachable from tests, so the rule that opening an unread
    /// row requests its contents can be checked without mounting a `DisclosureGroup`.
    func expansionBindingForTesting(_ row: PaneRow) -> Binding<Bool> {
        isExpanded(row.node.id, isUnexplored: row.node.isUnexplored == true)
    }

    /// What an opened folder with nothing under it says: the column's own rule
    /// (`PaneColumnsView.emptyCaption`) asked one level in, so the outline and Columns word one
    /// state the same way. `nil` for a folder with children, for a file, and while the walk runs.
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
                    .accessibilityLabel(PaneColumnsView.Caption.loadingLabel)
            }
        }
        .allowsHitTesting(false)
    }

    /// One row's disclosure state, projected from the pane's shared set rather than per-row state:
    /// `List` recycles rows, and a row never on screen must still come back open if search opened it.
    ///
    /// - Parameter isUnexplored: whether this row's children were never walked. Opening such a row
    ///   is the request for them (see `onNeedChildren`). Asked on open only: on close it would start
    ///   a listing mid-collapse, for a folder the user is done with.
    private func isExpanded(_ id: String, isUnexplored: Bool) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen {
                    expanded.insert(id)
                    if isUnexplored { onNeedChildren(id, false) }
                } else {
                    expanded.remove(id)
                }
            }
        )
    }
}
