import Foundation
import Events
import FileExplorer
import Sync

/// One row of Activity's Events: a sync run, a message no run carries, a one-way sync, or a setting
/// changed from Ask Claude's chat.
enum ActivityEvent: Identifiable {
    case run(ActivityEventRun)
    case message(ActivityMessage)
    case oneWay(OneWaySyncHistoryEntry)
    case setting(SettingsChange)

    var id: String {
        switch self {
        case .run(let run): "run-\(run.id)"
        case .message(let message): "message-\(message.id)"
        case .oneWay(let entry): "oneway-\(entry.id)"
        case .setting(let change): "setting-\(change.id)"
        }
    }

    var date: Date {
        switch self {
        case .run(let run): run.date
        case .message(let message): message.date
        case .oneWay(let entry): Date(timeIntervalSince1970: TimeInterval(entry.startedAt))
        case .setting(let change): change.at
        }
    }
}

/// One sync run, built from its Sync History records: one row, however many files it touched.
struct ActivityEventRun {
    let id: UUID
    /// The records it lists when opened, newest first: every one, or those the filters keep.
    let records: [SyncHistoryRecord]
    /// How many records it has in all, for "3 of 24".
    let total: Int
    /// The message that reported it, which leads its row. Runs that post none (a pane's rename, New
    /// Folder, an Ask Claude plan), and runs whose message was cleared or aged out, build their own
    /// sentence.
    let message: ActivityMessage?
    /// Some of its records were dropped by Sync History's in-memory cap: `total` is what is kept.
    var isCut = false

    /// Its newest record's time: when it ended.
    var date: Date { records.first?.timestamp ?? .distantPast }

    /// Whether a filter cut it down.
    var isNarrowed: Bool { records.count < total }

    /// The minutes its run wrote to the log, for Show in Log: its message's when it has one.
    var span: ClosedRange<Date> {
        if let message { return message.span }
        let times = records.map(\.timestamp)
        let first = times.min() ?? date
        return first.addingTimeInterval(-60)...date.addingTimeInterval(5)
    }

    /// Its sentence when no message reported it: what one record did, or a count of each kind.
    var headline: String { Self.headline(records) }

    /// "~/Documents/Taxes → ~/Dropbox/Taxes · 3.8 MB": where it happened, and how much it moved.
    var detail: String? { Self.detail(records) }

    static func headline(_ records: [SyncHistoryRecord]) -> String {
        if records.count == 1, let record = records.first { return sentence(record) }
        let order: [SyncAction] = [.copy, .move, .delete, .matchDates, .newFolder]
        // A delete with no way back is "deleted", not "to the Trash", as its own sentence says.
        let counts = Dictionary(grouping: records.filter { !$0.isPermanentDelete }, by: \.action).mapValues(\.count)
        var parts = order.compactMap { action -> String? in
            guard let count = counts[action] else { return nil }
            return phrase(action, count)
        }
        let deleted = records.filter(\.isPermanentDelete).count
        if deleted > 0 { parts.append("\(deleted.formatted()) deleted") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func sentence(_ record: SyncHistoryRecord) -> String {
        let name = "“\(lastComponent(record.sourcePath))”"
        switch record.action {
        case .copy:
            return "Copied \(name)"
        case .move:
            guard let dest = record.destPath else { return "Moved \(name)" }
            if parent(dest) == parent(record.sourcePath) { return "Renamed \(name) to “\(lastComponent(dest))”" }
            return "Moved \(name) to “\(lastComponent(parent(dest)))”"
        case .delete:
            return record.isPermanentDelete ? "Deleted \(name)" : "Moved \(name) to the Trash"
        case .matchDates:
            return "Matched the date of \(name)"
        case .newFolder:
            return "Made the folder \(name)"
        }
    }

    private static func phrase(_ action: SyncAction, _ count: Int) -> String {
        let n = count.formatted()
        switch action {
        case .copy: return count == 1 ? "1 copy" : "\(n) copies"
        case .move: return count == 1 ? "1 move" : "\(n) moves"
        case .delete: return "\(n) to the Trash"
        case .matchDates: return count == 1 ? "1 date match" : "\(n) date matches"
        case .newFolder: return count == 1 ? "1 new folder" : "\(n) new folders"
        }
    }

    static func detail(_ records: [SyncHistoryRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        var parts: [String] = []
        // A side with no folder in common (two volumes, say) is left unnamed rather than called "/".
        let from = commonFolder(records.map { parent($0.sourcePath) })
        let destinations = records.compactMap(\.destPath)
        let to = destinations.count == records.count ? commonFolder(destinations.map(parent)) : nil
        switch (from == "/" ? nil : from, to == "/" ? nil : to) {
        case let (from?, to?): parts.append(from == to ? tilde(from) : "\(tilde(from)) → \(tilde(to))")
        case let (from?, nil): parts.append(tilde(from))
        case let (nil, to?): parts.append("→ \(tilde(to))")
        case (nil, nil): break
        }
        let bytes = records.compactMap(\.sizeBytes).reduce(0, +)
        if bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    /// The deepest folder every one of `folders` is in.
    static func commonFolder(_ folders: [String]) -> String {
        guard var common = folders.first?.split(separator: "/", omittingEmptySubsequences: true) else { return "/" }
        for folder in folders.dropFirst() {
            let parts = folder.split(separator: "/", omittingEmptySubsequences: true)
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        return "/" + common.joined(separator: "/")
    }

    private static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    private static func lastComponent(_ path: String) -> String { (path as NSString).lastPathComponent }
    private static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// What Events' Action menu keeps.
enum ActivityEventsChoice: Hashable {
    case all
    /// Runs, narrowed to one kind of record.
    case action(SyncAction)
    /// Messages no run carries: a failure, a stop, a PDF saved.
    case messages
    case oneWaySync
    case settings

    var keepsRuns: Bool {
        switch self {
        case .all, .action: true
        default: false
        }
    }

    var action: SyncAction? {
        if case .action(let action) = self { return action }
        return nil
    }
}

@MainActor
enum ActivityEvents {
    /// The timeline, newest first, as the filters leave it.
    ///
    /// A run's records come from Sync History, grouped by run; its message is the Recent message
    /// that reported it. A message whose run left no records here (cleared, trimmed, or Edit's,
    /// which have none) is a row of its own. A path or action filter keeps every run with a match
    /// and lists only the matching records; a search also finds a run by its message's words.
    static func build(records: [SyncHistoryRecord], messages: [ActivityMessage], oneWay: [OneWaySyncHistoryEntry],
                      changes: [SettingsChange], choice: ActivityEventsChoice, search: String,
                      start: Date?, trimmedRuns: Set<UUID> = []) -> [ActivityEvent] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var events: [ActivityEvent] = []

        // Every run with records, and how many each has, before any filter.
        let totals = Dictionary(grouping: records, by: \.runId).mapValues(\.count)
        var messageForRun: [UUID: ActivityMessage] = [:]
        for message in messages.reversed() {
            if let runId = message.runId, totals[runId] != nil { messageForRun[runId] = message }
        }

        if choice.keepsRuns {
            let kept = SyncHistoryFilter.apply(records, action: choice.action, search: needle, start: start)
            var order: [UUID] = []
            var byRun: [UUID: [SyncHistoryRecord]] = [:]
            for record in kept {
                if byRun[record.runId] == nil { order.append(record.runId) }
                byRun[record.runId, default: []].append(record)
            }
            // A search for a message's words finds its whole run.
            if !needle.isEmpty, choice == .all {
                let matched = messageForRun.filter { byRun[$0.key] == nil && says($0.value, needle) }
                // One pass over the records for every matched message, not one per message.
                let unfiltered = matched.isEmpty ? [:] : Dictionary(
                    grouping: SyncHistoryFilter.apply(records, action: nil, search: "", start: start), by: \.runId)
                for runId in matched.keys {
                    guard let own = unfiltered[runId], !own.isEmpty else { continue }
                    order.append(runId)
                    byRun[runId] = own
                }
            }
            for runId in order {
                guard let own = byRun[runId], let total = totals[runId] else { continue }
                var run = ActivityEventRun(id: runId, records: own, total: total, message: messageForRun[runId])
                run.isCut = trimmedRuns.contains(runId)
                events.append(.run(run))
            }
        }

        if choice == .all || choice == .messages {
            for message in messages {
                if let runId = message.runId, totals[runId] != nil { continue }
                if let start, message.date < start { continue }
                if !needle.isEmpty, !says(message, needle) { continue }
                events.append(.message(message))
            }
        }

        if choice == .all || choice == .oneWaySync {
            for entry in oneWay {
                if let start, OneWaySyncHistoryEntryRow.date(entry) < start { continue }
                guard OneWaySyncHistoryEntryRow.matches(entry, search: needle) else { continue }
                events.append(.oneWay(entry))
            }
        }

        if choice == .all || choice == .settings {
            events += HistorySettingsChanges.filter(changes, search: needle, start: start).map(ActivityEvent.setting)
        }

        return events.sorted { $0.date > $1.date }
    }

    private static func says(_ message: ActivityMessage, _ needle: String) -> Bool {
        message.message.localizedCaseInsensitiveContains(needle)
            || (message.detail?.localizedCaseInsensitiveContains(needle) ?? false)
    }

    /// The events by day, newest day first, each headed "Today", "Yesterday", or its date.
    static func days(_ events: [ActivityEvent], now: Date = Date(),
                     calendar: Calendar = .current) -> [(title: String, events: [ActivityEvent])] {
        var order: [Date] = []
        var byDay: [Date: [ActivityEvent]] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(event)
        }
        return order.map { day in (dayTitle(day, now: now, calendar: calendar), byDay[day] ?? []) }
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide)
                                      : .dateTime.weekday(.wide).day().month(.wide).year())
    }
}
