import Foundation
import Design
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
                // EVERY entry of a too-short run stays visible. With the default minRun of 2
                // this branch only ever sees a single entry, but appending just run[0] was a
                // latent drop of entries 2..n should the threshold ever rise.
                items.append(contentsOf: run.map { .entry($0) })
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
        // Rendered in the zone the bucket was computed in, not in whatever zone a shared
        // formatter woke up in. `day` is `calendar.startOfDay(for:)`, so `calendar.timeZone` is
        // the only zone in which it means the midnight it was built to mean — read it in any
        // other and the header names the wrong day. In the app `calendar` is `.current`, so this
        // changes nothing there; it is what makes the two agree by construction.
        return (sameYear ? Self.headerThisYear : Self.headerOtherYear)
            .string(from: day, in: calendar.timeZone)
    }

    /// Stable `yyyy-MM-dd` section id — locale-independent so it never collides across days.
    ///
    /// Now also calendar-pinned, which `fixed` brings with it: the id was Gregorian only by
    /// accident of the reader's region, and a Buddhist-calendar Mac keyed its sections `2569-…`.
    /// Nothing compared these ids across machines, so that was invisible rather than broken.
    private static let keyFormatter = ZoneRefreshedFormatter.fixed("yyyy-MM-dd")

    /// The two DISPLAYED day headers, and the reason this file is in the zone sweep at all.
    ///
    /// `byDay` takes each section's `day` from a **fresh** `Calendar.current`, so the bucket
    /// boundary always moved with the system zone — but these formatters captured whichever zone
    /// was current when the Activity Log first drew, so they rendered that boundary in a zone the
    /// machine had left. The result was a header a full day out: entries stamped 2026-06-01,
    /// bucketed at midnight IST, drawn under "Sunday, May 31" by a formatter still on Pacific.
    ///
    /// The `Today`/`Yesterday` branch above never had the bug — it compares against the same fresh
    /// calendar — so this only ever showed on sections two days old and older, which is exactly
    /// where a reader has no other way to tell.
    private static let headerThisYear = ZoneRefreshedFormatter.template("EEEEMMMd")
    private static let headerOtherYear = ZoneRefreshedFormatter.template("MMMdyyyy")
}
