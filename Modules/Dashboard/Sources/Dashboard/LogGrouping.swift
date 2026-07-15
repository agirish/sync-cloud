import Foundation
import Events

/// Pure grouping for the Activity Log — day buckets and collapsed operation runs — kept out of the
/// `LogViewer` View so the ordering, day boundaries, and run-folding are unit-testable without
/// `@State`. Internal (never crosses a module boundary; matches `LogEntryFilter`), tested via
/// `@testable import Dashboard`.
///
/// The log is a flat, one-line-per-event stream (`LogEntry` carries no operation id), so "operations"
/// are recovered here from the two message prefixes that actually emit *runs* of per-file lines —
/// guided review's `"Synced file: …"` and Filing's `"Filing: filed …"`. Bulk copy/move already logs a
/// single summary line, so it needs no folding. Keying on those exact prefixes (rather than a general
/// "collapse similar lines" heuristic) means only genuine per-file runs fold; every other line renders
/// as itself.
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
                items.append(.entry(run[0]))
            }
            i = j
        }
        return items
    }

    /// Buckets `entries` (already newest-first) into consecutive same-calendar-day sections, folding
    /// operation runs within each day. Because the input is time-ordered, a single left-to-right pass
    /// yields the sections in order; a day boundary starts a new section.
    static func byDay(_ entries: [LogEntry], now: Date = Date(), calendar: Calendar = .current) -> [DaySection] {
        var sections: [DaySection] = []
        var startOfCurrent: Date?
        var bucket: [LogEntry] = []

        func flush() {
            guard let day = startOfCurrent, !bucket.isEmpty else { return }
            sections.append(DaySection(id: Self.keyFormatter.string(from: day),
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
        return (sameYear ? Self.headerThisYear : Self.headerOtherYear).string(from: day)
    }

    /// Stable `yyyy-MM-dd` section id — locale-independent so it never collides across days.
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let headerThisYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return f
    }()

    private static let headerOtherYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return f
    }()
}
