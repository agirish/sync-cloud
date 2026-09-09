import Foundation
import Sync

/// How the reader had the differences table narrowed — the filter, the search, the sort, the folded
/// sections — kept somewhere that outlives the workspace.
///
/// Same defect as ``LensWorkspaceSession``, in the workspace next door: `DifferencesView` is mounted
/// inside one arm of `ContentView`'s layout switch, so leaving Compare destroyed it and coming back
/// gave you the filter on All, the search closed and empty, the sort back to filename ascending and
/// every folder section re-expanded.
///
/// **What is deliberately NOT here, and why this was not simply the same change again.** Two of
/// these values are reset by `.onChange` handlers that — as the comment beside one of them already
/// says — never fire on a remount. Today the remount IS the reset: a rescan starting while Compare
/// is off screen clears nothing, and the fresh mount covers it. Moving the state out without moving
/// that guarantee would have reintroduced exactly the two defects those handlers exist to prevent:
/// a remembered collapse hiding differences the reader has never seen, and a `.failed` filter left
/// standing after the failures went away, which is an empty table with no way back to a full one.
/// ``collapsedSectionsScanDate`` and `DifferencesView`'s arrival guards close both.
///
/// The row selections stay in the view on purpose. They are sets of `FileDifference.ID`, and an ID
/// names a row in one comparison; carrying them across a rescan would point them at rows that no
/// longer exist, and the review cursor rides `reviewSelection`. Nothing was reported lost there, and
/// preserving an identity-keyed selection is a different question from preserving a narrowing.
@MainActor
public final class DifferencesSession: ObservableObject {

    public init() {}

    /// The type narrowing above the table.
    @Published var selectedFilter: DifferenceFilter = .all

    /// Folder names whose section is folded.
    ///
    /// Still not persisted across launches, and still cleared by a rescan — the folders themselves
    /// change between scans, so a remembered fold is a preference about a list that no longer
    /// exists, and restoring it hides differences nobody has seen. What changed is only that the
    /// clearing can no longer rely on the view being rebuilt; see ``collapsedSectionsScanDate``.
    @Published var collapsedSections: Set<String> = []

    /// Which comparison the folds above describe.
    ///
    /// **The remount's job, made explicit.** `collapsedSections` was cleared by an
    /// `.onChange(of: lastScanDate)` inside the view, and that handler cannot fire while the view is
    /// not mounted — a rescan started from Browse or from the Organize rail happens with Compare
    /// torn down. It never mattered, because the rebuild cleared the set anyway. It matters now, so
    /// the set carries the scan it belongs to and is dropped on arrival when they disagree.
    @Published var collapsedSectionsScanDate: Date?

    /// What is typed in the table's search field, and whether the field is showing.
    @Published var searchText = ""
    @Published var isSearchExpanded = false

    /// The table's sort. Filename ascending by default, with the localized comparator the column
    /// header applies.
    @Published var sortOrder: [KeyPathComparator<FileDifference>] =
        [KeyPathComparator(\.fileName, comparator: .localizedStandard, order: .forward)]

    /// Whether the per-side item totals beside the count pill are revealed.
    @Published var showItemCounts = false
}
