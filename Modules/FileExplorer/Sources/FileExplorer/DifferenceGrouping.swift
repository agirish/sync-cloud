import Foundation
import Sync

/// Splits the differences table's already-sorted rows into top-level folder sections, so a
/// comparison of hundreds of rows can be read and acted on a folder at a time.
///
/// Pure and separate from the view, so its edge cases (empty roots, a single section, a sort
/// that reorders sections) are asserted directly.
enum DifferenceGrouping {

    /// One section: the folder that names it and the rows beneath it, in the order they arrived.
    struct Section: Identifiable, Equatable {
        /// The bucket this section is keyed on: a top-level folder name, or `rootKey` for items
        /// sitting directly in the scan root. An identity, not a label — render `title`.
        let folder: String
        let rows: [FileDifference]
        var id: String { folder }
        var count: Int { rows.count }

        /// What the header prints. The only place `rootKey` becomes words, so nothing else has to
        /// know that the root bucket is spelled differently from the thing it is called.
        var title: String { folder == DifferenceGrouping.rootKey ? DifferenceGrouping.rootLabel : folder }
    }

    /// The bucket a difference lying directly in the compared folder is filed under.
    ///
    /// A "/" rather than the label, because `split(separator: "/")` drops empty components, so no
    /// real folder can produce it. Keying on the label would merge the loose rows with a folder
    /// named "Top level", and selecting that header would select the files beside it too.
    static let rootKey = "/"

    /// What `rootKey` is called. Display only: never a bucket, never compared against a folder
    /// name. See `Section.title`.
    static let rootLabel = "Top level"

    /// The bucketing split. Empty components are dropped (`split` omits them by default), so a
    /// leading slash, a trailing slash and a "//" all land in the same bucket. `folder` is nil only
    /// when nothing is left: an empty parent, or one of pure separators.
    private static func split(_ parent: String) -> (folder: String?, rest: String) {
        var components = parent.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return (nil, "") }
        return (components.removeFirst(), components.joined(separator: "/"))
    }

    /// The bucket a difference belongs to: the first path component of its parent, or `rootKey`
    /// when it has none. Not the whole parent path, which would give mostly one-row sections; the
    /// top-level folder is the unit people decide about.
    static func folder(for difference: FileDifference) -> String {
        split(difference.parentPath).folder ?? rootKey
    }

    /// Groups `sorted` into sections without reordering anything. Sections appear in the order of
    /// their first row, and rows keep their order inside a section, so grouping always follows the
    /// column sort: no separate section order exists to disagree with it.
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

    /// How many rows a section must average before headers pay for themselves. A header over one
    /// or two rows is not a landmark, just a row you can't act on that nearly doubles the list's
    /// height.
    static let minimumAverageRowsPerSection = 3

    /// Whether grouping is worth drawing for this row set. One section is pure chrome, and many
    /// tiny sections cost more space than they save; both fall back to flat. That lets the
    /// preference default on without punishing small comparisons.
    static func isWorthGrouping(_ sections: [Section]) -> Bool {
        guard sections.count > 1 else { return false }
        let rows = sections.reduce(0) { $0 + $1.count }
        return rows >= sections.count * minimumAverageRowsPerSection
    }
}

/// What clicking a folder section header does to the table selection. Pure, because it is easy
/// to get backwards: ⌘-clicking a section that is already fully selected must remove it, or the
/// gesture has no way back.
enum SectionClickIntent: Equatable {
    /// Plain click: this section becomes the whole selection.
    case replace
    /// ⌘-click on a section that is not (fully) selected: add its rows to what is already there.
    case add
    /// ⌘-click on a section whose rows are all selected: take them back out.
    case remove

    static func resolve(commandHeld: Bool, isFullySelected: Bool) -> SectionClickIntent {
        guard commandHeld else { return .replace }
        return isFullySelected ? .remove : .add
    }
}

extension DifferenceGrouping {
    /// The selection a click on `section` produces, given what is selected now.
    static func selection(after intent: SectionClickIntent,
                          section: Section,
                          current: Set<FileDifference.ID>) -> Set<FileDifference.ID> {
        let ids = Set(section.rows.map(\.id))
        switch intent {
        case .replace: return ids
        case .add: return current.union(ids)
        case .remove: return current.subtracting(ids)
        }
    }

    /// Whether every row of `section` is in `selection`: what lights the header, and whether a
    /// ⌘-click adds or removes. An empty section is not fully selected, or it would light a header
    /// holding nothing. Sections are built from their rows, so this only guards a future caller.
    static func isFullySelected(_ section: Section, in selection: Set<FileDifference.ID>) -> Bool {
        guard !section.rows.isEmpty else { return false }
        return section.rows.allSatisfy { selection.contains($0.id) }
    }

    /// The row of `ids` the table draws first, where a reveal scrolls. Display order, not `sorted`
    /// order, when there are sections: the first selected row of `sorted` can sit in the second
    /// section. Folds are ignored, since the one caller follows `DifferencesSession.show`, which
    /// opens every section.
    static func firstShown(of ids: Set<FileDifference.ID>, sorted: [FileDifference],
                           sections: [Section]) -> FileDifference? {
        guard !sections.isEmpty else { return sorted.first { ids.contains($0.id) } }
        return sections.lazy.compactMap { $0.rows.first { ids.contains($0.id) } }.first
    }
}

extension DifferenceGrouping.Section {
    /// Rows this section would copy rightward, and leftward. Shown only when the section is
    /// collapsed, since expanded rows state their own direction.
    var copyToRightCount: Int { rows.count { $0.action == .copyToRight } }
    var copyToLeftCount: Int { rows.count { $0.action == .copyToLeft } }

    /// "11 → Dropbox · 2 → iCloud", either half omitted when it is zero. Empty when the section
    /// somehow has neither, so the header renders nothing rather than a stray separator.
    func directionSummary(leftName: String, rightName: String) -> String {
        var parts: [String] = []
        if copyToRightCount > 0 { parts.append("\(copyToRightCount) → \(rightName)") }
        if copyToLeftCount > 0 { parts.append("\(copyToLeftCount) → \(leftName)") }
        return parts.joined(separator: " · ")
    }
}
