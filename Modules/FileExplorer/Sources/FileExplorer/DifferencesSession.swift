import Foundation
import Sync

/// How the reader had the differences table narrowed (filter, search, sort, folded sections), kept
/// somewhere that outlives the workspace. `DifferencesView` lives in one arm of `ContentView`'s
/// layout switch, so leaving Compare destroys it, as with ``LensWorkspaceSession``.
///
/// **Trap:** two of these values are reset by `.onChange` handlers in the view, which can't fire
/// while Compare is off screen. Without a remount to reset them, a rescan from elsewhere would
/// leave a fold hiding unseen differences, or a `.failed` filter over an empty table.
/// ``collapsedSectionsScanDate`` and `DifferencesView`'s arrival guards close both.
///
/// The row selections stay in the view on purpose: they are sets of `FileDifference.ID`, which
/// name rows in one comparison, so after a rescan they would point at rows that no longer exist.
@MainActor
public final class DifferencesSession: ObservableObject {

    public init() {}

    /// The type narrowing above the table.
    @Published var selectedFilter: DifferenceFilter = .all

    /// Folder names whose section is folded. Not persisted, and cleared by a rescan: the folders
    /// change between scans, and a remembered fold would hide differences nobody has seen. See
    /// ``collapsedSectionsScanDate``.
    @Published var collapsedSections: Set<String> = []

    /// Which comparison the folds above describe. A rescan from Browse or the Organize rail runs
    /// with Compare torn down, where the view's `.onChange(of: lastScanDate)` can't fire, so the
    /// folds carry their scan and are dropped on arrival when the two disagree.
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

    /// Rows another part of the app (Ask Claude) asked the table to select, applied by the table
    /// when it next draws and then cleared. The table's own selection stays its `@State`.
    @Published var requestedSelection: Set<FileDifference.ID>?

    /// Narrows the table to `filter` and selects `ids` — Ask Claude's “show me the ones only on
    /// Dropbox”. The search and the folds are cleared, so nothing selected is hidden from view.
    public func show(_ filter: DifferenceFilter, selecting ids: Set<FileDifference.ID>) {
        selectedFilter = filter
        searchText = ""
        isSearchExpanded = false
        collapsedSections = []
        requestedSelection = ids
    }
}
