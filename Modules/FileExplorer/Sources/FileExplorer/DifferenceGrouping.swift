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
    /// A "/" rather than the words below, and that is the whole point: `split(separator: "/")`
    /// drops empty components, so no path can ever yield a component containing a separator —
    /// which makes this key unreachable by any real folder, by construction.
    ///
    /// Keying on the LABEL, as this used to, merged the loose rows into a folder literally named
    /// "Top level": both sides answered "Top level" from `folder(for:)` and landed in one bucket,
    /// so the header counted rows that were not in that folder and — once the header became a
    /// selection target — selecting the folder also selected files sitting beside it. The comment
    /// here claimed the collision could not happen, which is the version of this worth naming: the
    /// label and the identity were the same string, so there was nothing to keep honest.
    static let rootKey = "/"

    /// What `rootKey` is CALLED. Display only — never a bucket, never compared against a folder
    /// name. See `Section.title`.
    static let rootLabel = "Top level"

    /// The single split `folder(for:)` and `pathWithinSection(_:)` both read, so the header and the
    /// row prefix under it cannot disagree about where the boundary falls.
    ///
    /// One function, not two, because these two must PARTITION the parent path: whatever the header
    /// names, the prefix must not repeat, and between them they must account for the whole path.
    /// Two independent implementations each owning their own edge cases is how that invariant
    /// breaks — and it had. A parent of "/Immigration" made `folder(for:)` fall back to the whole
    /// string while `pathWithinSection` dropped only the slash, yielding a header reading
    /// "/Immigration" over rows reading "Immigration/…": the folder said twice, which is precisely
    /// the defect the prefix drop exists to prevent. Engine-built `relativePath`s never start with
    /// "/", so that was latent rather than live — the fix is for the disagreement, not the symptom.
    ///
    /// Empty components are dropped (`split` omits them by default), which is what makes a leading
    /// slash, a trailing slash and a "//" all land on the same answer from both sides.
    /// `folder` is nil only when nothing is left — an empty parent, or a parent of pure separators.
    private static func split(_ parent: String) -> (folder: String?, rest: String) {
        var components = parent.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return (nil, "") }
        return (components.removeFirst(), components.joined(separator: "/"))
    }

    /// The bucket a difference belongs to — the first path component of its parent, or `rootKey`
    /// when it has no parent at all.
    ///
    /// First component, not the whole parent path: grouping by the full parent turns 576 rows into
    /// roughly 400 sections of one row each, which is the flat list with extra chrome. The
    /// top-level folder is the unit people actually decide about.
    static func folder(for difference: FileDifference) -> String {
        split(difference.parentPath).folder ?? rootKey
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
        split(difference.parentPath).rest
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

/// What clicking a folder section header does to the table selection.
///
/// Pure, because the rule reads obvious and is easy to implement backwards: ⌘-clicking a section
/// that is ALREADY fully selected has to remove it, not re-add it, or the gesture has no way back.
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

    /// Whether every row of `section` is in `selection` — what lights the header, and what decides
    /// whether a ⌘-click adds or removes.
    ///
    /// An empty section is NOT "fully selected": vacuous truth would light a header holding
    /// nothing and make ⌘-click a no-op that reads as broken. Sections are never empty in practice
    /// (they are built from their rows), so this only guards a future caller.
    static func isFullySelected(_ section: Section, in selection: Set<FileDifference.ID>) -> Bool {
        guard !section.rows.isEmpty else { return false }
        return section.rows.allSatisfy { selection.contains($0.id) }
    }
}

extension DifferenceGrouping.Section {
    /// Rows this section would copy rightward, and leftward. Only shown when the section is
    /// COLLAPSED: expanded, every row states its own direction and the header would be repeating
    /// them; collapsed, the rows are gone and this is the only thing left that can say which way
    /// the folder's work points.
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
