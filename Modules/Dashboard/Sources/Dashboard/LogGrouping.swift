import Foundation
import Design
import Events

/// Pure grouping for the Activity Log, day buckets and folded operation runs, kept out of
/// `LogViewer` so ordering, day boundaries and folding are unit-testable without `@State`.
///
/// The log is a flat stream with no operation id, so operations are recovered from the two message
/// prefixes that emit runs of per-file lines: guided review's `"Synced file: …"` and Filing's
/// `"Filing: filed …"`. Bulk copy/move logs one summary line and needs no folding. Keying on exact
/// prefixes, not a "similar lines" heuristic, means only real per-file runs fold.
enum LogGrouping {

    /// One rendered item: a standalone entry, or a collapsed run of per-file lines from one action.
    enum Item: Identifiable {
        case entry(LogEntry)
        case group(OperationGroup)

        var id: String {
            switch self {
            case .entry(let e): return "e-\(e.id.uuidString)"
            case .group(let g): return "g-\(g.id)"
            }
        }
    }

    /// A folded run of consecutive same-kind per-file log lines, shown as one expandable header.
    struct OperationGroup: Identifiable {
        /// Stable across renders: the first child's entry id.
        let id: String
        let kind: Kind
        /// Children in list order (the input order — newest-first, as the list receives them).
        let children: [LogEntry]
        /// Highest severity among the children, so a failure inside an otherwise-quiet run still
        /// tints the collapsed header a warning/error color.
        let level: LogLevel
        /// The newest child's time (the run's first element, list being newest-first).
        let timestamp: Date

        var count: Int { children.count }
        var title: String { kind.title(count: count) }
        var icon: String { kind.icon }
    }

    /// The per-file operations that emit foldable runs, each identified by its message prefix.
    enum Kind: String, CaseIterable {
        case synced
        case filed

        /// The message prefix that marks one per-file line of this operation.
        var prefix: String {
            switch self {
            case .synced: return "Synced file: "
            case .filed:  return "Filing: filed "
            }
        }

        var icon: String {
            switch self {
            case .synced: return "doc.on.doc"
            case .filed:  return "tray.and.arrow.down"
            }
        }

        func title(count: Int) -> String {
            switch self {
            case .synced: return "Synced \(count) file\(count == 1 ? "" : "s")"
            case .filed:  return "Filed \(count) file\(count == 1 ? "" : "s")"
            }
        }

        static func classify(_ message: String) -> Kind? {
            allCases.first { message.hasPrefix($0.prefix) }
        }
    }

    /// A day's worth of items with a human header ("Today", "Yesterday", or a formatted date).
    struct DaySection: Identifiable {
        let id: String
        let header: String
        let items: [Item]
    }

    /// Folds each maximal run of `minRun`+ consecutive entries that share one operation kind into a
    /// single `.group`; every other entry stays a `.entry`. Input order is preserved. A lone matching
    /// entry (run shorter than `minRun`) is left ungrouped — there is nothing to collapse.
    static func fold(_ entries: [LogEntry], minRun: Int = 2) -> [Item] {
        var items: [Item] = []
        var i = 0
        while i < entries.count {
            guard let kind = Kind.classify(entries[i].message) else {
                items.append(.entry(entries[i])); i += 1; continue
            }
            var j = i + 1
            while j < entries.count, Kind.classify(entries[j].message) == kind { j += 1 }
            let run = Array(entries[i..<j])
            if run.count >= minRun {
                let level = run.max { $0.level.severity < $1.level.severity }?.level ?? run[0].level
                items.append(.group(OperationGroup(
                    id: run[0].id.uuidString, kind: kind, children: run,
                    level: level, timestamp: run[0].timestamp)))
            } else {
                // Every entry of a too-short run stays visible, not just run[0], so nothing is
                // dropped if `minRun` ever rises above 2.
                items.append(contentsOf: run.map { .entry($0) })
            }
            i = j
        }
        return items
    }

    /// Buckets `entries` (already newest-first) into consecutive same-day sections, folding runs
    /// within each day. The input is time-ordered, so one pass yields the sections in order.
    static func byDay(_ entries: [LogEntry], now: Date = Date(), calendar: Calendar = .current) -> [DaySection] {
        var sections: [DaySection] = []
        var startOfCurrent: Date?
        var bucket: [LogEntry] = []

        func flush() {
            guard let day = startOfCurrent, !bucket.isEmpty else { return }
            sections.append(DaySection(id: Self.keyFormatter.string(from: day, in: calendar.timeZone),
                                       header: dayHeader(day, now: now, calendar: calendar),
                                       items: fold(bucket)))
            bucket.removeAll(keepingCapacity: true)
        }

        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            if day != startOfCurrent { flush(); startOfCurrent = day }
            bucket.append(entry)
        }
        flush()
        return sections
    }

    /// "Today" / "Yesterday" for the two nearest days, otherwise a localized date (with the year only
    /// when it isn't the current one, so recent days stay compact).
    static func dayHeader(_ day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        // Drawn in `calendar.timeZone`, the zone the bucket was computed in: `day` is that zone's
        // midnight, and read in any other zone the header names the wrong day.
        return (sameYear ? Self.headerThisYear : Self.headerOtherYear)
            .string(from: day, in: calendar.timeZone)
    }

    /// Stable `yyyy-MM-dd` section id, locale- and calendar-independent (`fixed`), so a
    /// non-Gregorian Mac keys its sections the same way.
    private static let keyFormatter = ZoneRefreshedFormatter.fixed("yyyy-MM-dd")

    /// The two displayed day headers. `byDay` buckets by a fresh `Calendar.current`, so these must
    /// follow the system zone too: a formatter that kept the zone of the log's first draw would put
    /// sections two or more days old under a header a full day out. `Today`/`Yesterday` compare
    /// against the same fresh calendar and need no formatter.
    private static let headerThisYear = ZoneRefreshedFormatter.template("EEEEMMMd")
    private static let headerOtherYear = ZoneRefreshedFormatter.template("MMMdyyyy")
}
