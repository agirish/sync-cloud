import Foundation
import Sync

/// Splits the differences table's already-sorted rows into top-level folder sections.
///
/// The table is flat today, which is fine at twenty rows and useless at the five hundred a real
/// Documents comparison produces: the only structure is the sort, so "do I want all of
/// Immigration?" means reading a path prefix the Name column has already truncated away.
///
/// Pure, and deliberately separate from the view: the section list is the kind of thing that looks
/// obviously right in a screenshot and is wrong on the third fixture (empty roots, a single
/// section, a sort that reorders sections under you), so it is asserted directly.
enum DifferenceGrouping {

    /// One section: the folder that names it and the rows beneath it, in the order they arrived.
    struct Section: Identifiable, Equatable {
        /// The top-level folder name, or `rootLabel` for items sitting directly in the scan root.
        let folder: String
        let rows: [FileDifference]
        var id: String { folder }
        var count: Int { rows.count }
    }

    /// What a difference lying directly in the compared folder is filed under. Not a real folder
    /// name, so it cannot collide with one: a folder called "Top level" would be grouped under
    /// its own name, and this label is only ever chosen for rows whose `parentPath` is empty.
    static let rootLabel = "Top level"

    /// The top-level folder a difference belongs to — the first path component of its parent, or
    /// `rootLabel` when it has no parent at all.
    ///
    /// First component, not the whole parent path: grouping by the full parent turns 576 rows into
    /// roughly 400 sections of one row each, which is the flat list with extra chrome. The
    /// top-level folder is the unit people actually decide about.
    static func folder(for difference: FileDifference) -> String {
        let parent = difference.parentPath
        guard !parent.isEmpty else { return rootLabel }
        guard let slash = parent.firstIndex(of: "/") else { return parent }
        let first = String(parent[..<slash])
        // A leading slash (or any empty first component) would otherwise produce a nameless
        // section. Fall back to the whole parent, which is at least identifying.
        return first.isEmpty ? parent : first
    }

    /// Groups `sorted` into sections **without reordering anything**.
    ///
    /// Sections appear in the order their first row appears in `sorted`, and rows keep their
    /// relative order inside a section. That single rule is what keeps grouping consistent with
    /// whatever the column sort is doing: sort by Size descending and the section holding the
    /// biggest file comes first; sort by Name and the sections come out name-ordered. No separate
    /// section-ordering rule exists to disagree with the sort — which is the bug this shape avoids,
    /// not merely a nicety, because a table whose groups and rows sort by different keys reads as
    /// broken.
    static func sections(_ sorted: [FileDifference]) -> [Section] {
        var order: [String] = []
        var buckets: [String: [FileDifference]] = [:]
        for difference in sorted {
            let key = folder(for: difference)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(difference)
        }
        return order.map { Section(folder: $0, rows: buckets[$0] ?? []) }
    }

    /// Whether grouping is worth drawing at all for this row set.
    ///
    /// One section means every header would say the same thing about every row — pure chrome, and
    /// worse than the flat table it replaced. An empty list has nothing to head. Both fall back to
    /// flat rather than rendering a lone header, so the feature can be left on permanently without
    /// making small comparisons noisier.
    static func isWorthGrouping(_ sections: [Section]) -> Bool {
        sections.count > 1
    }
}
