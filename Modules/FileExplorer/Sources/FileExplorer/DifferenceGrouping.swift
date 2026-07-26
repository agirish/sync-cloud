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

    /// The parent path with the section's own folder taken off the front — what the Name cell
    /// shows once a header is already naming that folder.
    ///
    /// Without this the grouped table says the folder twice: a header reading "Claude" over a row
    /// reading `Claude/Projects/Investing/US/Trump Accounts/ Trump_Accounts_Research.md`. The
    /// repetition lands in the one column that was already truncating, which is the opposite of
    /// what grouping is for.
    ///
    /// Returns "" for a row sitting directly in the section folder (its whole parent WAS the
    /// folder) and for root-level rows, so the Name cell drops the prefix entirely rather than
    /// printing a bare "/".
    static func pathWithinSection(_ difference: FileDifference) -> String {
        let parent = difference.parentPath
        guard !parent.isEmpty else { return "" }
        guard let slash = parent.firstIndex(of: "/") else {
            // The parent IS the top-level folder — the header already says it.
            return ""
        }
        return String(parent[parent.index(after: slash)...])
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

    /// How many rows a section must average before headers pay for themselves.
    ///
    /// Set from a real comparison rather than taste. A 22-difference scan spread over eight
    /// folders rendered as header/row/gap/header/row/gap — eight headers heading eleven rows
    /// between them, which very nearly doubled the list's height to say what the Name column's
    /// path prefix already said. A header that heads one or two rows is not a landmark; it is a
    /// row you cannot act on. The same comparison at 576 differences averages dozens per folder
    /// and is exactly what grouping is for.
    static let minimumAverageRowsPerSection = 3

    /// Whether grouping is worth drawing at all for this row set.
    ///
    /// Two ways to fail. One section means every header says the same thing about every row —
    /// pure chrome, and worse than the flat table it replaced. Many tiny sections mean the headers
    /// cost more vertical space than the landmarks save. Both fall back to flat, which is what
    /// lets the preference default ON without punishing small comparisons: grouping appears when
    /// there is something to group.
    static func isWorthGrouping(_ sections: [Section]) -> Bool {
        guard sections.count > 1 else { return false }
        let rows = sections.reduce(0) { $0 + $1.count }
        return rows >= sections.count * minimumAverageRowsPerSection
    }
}
