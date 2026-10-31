//
//  OneWaySyncHistory.swift
//  SyncCloud
//

import Foundation

/// One sync in Activity ▸ History: what it set out to do, written before anything is applied, and
/// each step ticked off as it lands. It is what *Reverse in iCloud* reads (DE), and what a launch
/// after a crash reads to find a sync cut short.
///
/// SyncCloud's own saved store, not the app's Sync History (`SyncHistoryStore`), which is
/// best-effort and trimmed at 5 MB. A sync's steps are never registered for ⌘Z: nothing here
/// touches an undo manager.
public struct OneWaySyncHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    /// Bumped with any change to this layout or to the saved forms of `OneWaySyncStep` and
    /// `OneWaySyncWait`. An entry of another version is skipped, never half-read.
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    /// The first run the record belonged to (`OneWaySyncSavedRecord`). After a new first run,
    /// earlier entries can no longer be reversed.
    public var firstRun: UUID
    /// Seconds since 1970.
    public var startedAt: Int64
    public var steps: [OneWaySyncHistoryStep]
    /// What waited for the user in this sync: "32 wait for you".
    public var held: [OneWaySyncWait]
    /// Set when the sync ended. Steps it couldn't confirm by then keep their status, and
    /// `unconfirmedSteps` lists them. An entry still open at launch is a sync a crash cut short.
    public var finishedAt: Int64?

    public init(
        version: Int = OneWaySyncHistoryEntry.currentVersion, id: UUID = UUID(), firstRun: UUID, startedAt: Int64,
        steps: [OneWaySyncHistoryStep], held: [OneWaySyncWait], finishedAt: Int64? = nil
    ) {
        self.version = version
        self.id = id
        self.firstRun = firstRun
        self.startedAt = startedAt
        self.steps = steps
        self.held = held
        self.finishedAt = finishedAt
    }

    /// Steps the sync hadn't confirmed when it stopped: after a crash, each is compared again.
    public var unconfirmedSteps: [Int] {
        steps.indices.filter { !steps[$0].status.isOutcome }
    }
}

public struct OneWaySyncHistoryStep: Codable, Equatable, Sendable {
    public var step: OneWaySyncStep
    public var status: Status
    /// When the status was last set, in seconds.
    public var at: Int64?
    /// Where Dropbox's previous version or removed file went, relative to the Dropbox account
    /// folder (`SyncCloud Removed/…`): what *Reverse in iCloud* puts back.
    public var keptAt: String?
    /// The file as recorded once the step landed: Reverse is offered only for an item still
    /// like this on both sides.
    public var recorded: OneWaySyncFileRecord?

    public enum Status: Codable, Equatable, Sendable {
        /// Written before the sync began; not started.
        case pending
        /// About to be written, ticked with where Dropbox's file will go (`keptAt`) before it
        /// moves, so a crash mid-step still leaves History pointing at it.
        case started
        /// Written in Dropbox; Dropbox hasn't reported the upload yet.
        case applied
        /// Dropbox reported the upload, or nothing needed uploading: it counts as synced.
        case confirmed
        /// Not done, and why: Dropbox's copy changed since the diff, a read failed.
        case skipped(String)
        case failed(String)

        var isOutcome: Bool {
            switch self {
            case .pending, .started, .applied: return false
            case .confirmed, .skipped, .failed: return true
            }
        }
    }

    public init(step: OneWaySyncStep, status: Status = .pending, at: Int64? = nil,
                keptAt: String? = nil, recorded: OneWaySyncFileRecord? = nil) {
        self.step = step
        self.status = status
        self.at = at
        self.keptAt = keptAt
        self.recorded = recorded
    }
}

/// The History entries, one pair of files per sync in `History/`:
///
/// - `<id>.json`, the entry, written whole and flushed before anything is applied;
/// - `<id>.ticks`, one line per step outcome, appended and flushed as each step lands.
///
/// Rewriting the entry per step would write it once per step: a first run of 2,000 files would
/// write it 2,000 times. Instead `finish` folds the ticks in, writes the entry whole once more and
/// removes the ticks. A crash anywhere leaves an entry that reads the same: ticks folded twice
/// give the same steps, and a torn last tick is skipped, so that step reads as unconfirmed and is
/// compared again, which is what the design asks of anything not ticked off. A step that moves
/// a file into SyncCloud Removed is ticked `.started` with that path before the move, so a crash
/// mid-step still leaves the path.
///
/// Kept 90 days (`keep`). One process writes (`OneWaySyncProcessLock`), so nothing here locks.
public struct OneWaySyncHistoryStore: Sendable {
    public static let keep: Int64 = 90 * 24 * 60 * 60

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes the entry for a sync about to apply `steps`, before any is applied.
    ///
    /// Nil, and nothing written, for a sync that changes no file and holds nothing new: History
    /// gets an entry only for a sync that changed or held something, and a pass every 15 minutes
    /// still holding the same file isn't a new one. Adopting a file and forgetting one gone from
    /// both sides change only the record; apply those without an entry.
    public func begin(
        steps: [OneWaySyncStep], held: [OneWaySyncWait], firstRun: UUID, now: Date, id: UUID = UUID()
    ) throws -> OneWaySyncHistoryEntry? {
        let held = held.filter(\.reason.needsYou)
        let changes = steps.contains { step in
            switch step.action {
            case .adopt, .forget: return false
            default: return true
            }
        }
        if !changes {
            guard !held.isEmpty else { return nil }
            if let newest = entries().first(where: { $0.firstRun == firstRun }),
               Self.sameWaits(newest.held, held) { return nil }
        }
        let entry = OneWaySyncHistoryEntry(
            id: id, firstRun: firstRun, startedAt: Self.seconds(now),
            steps: steps.map { OneWaySyncHistoryStep(step: $0) }, held: held)
        try write(entry)
        return entry
    }

    /// Ticks step `index` off. The tick is flushed before this returns.
    public func tick(
        _ entry: UUID, step index: Int, status: OneWaySyncHistoryStep.Status, now: Date,
        keptAt: String? = nil, recorded: OneWaySyncFileRecord? = nil
    ) throws {
        let tick = Tick(step: index, status: status, at: Self.seconds(now), keptAt: keptAt, recorded: recorded)
        try OneWaySyncFiles.appendLine(OneWaySyncStore.encode(tick), to: ticksURL(entry))
    }

    /// Marks the entry finished, with its ticks folded in. Throws when the entry can't be read,
    /// so the caller never takes a lost entry for a finished one.
    public func finish(_ id: UUID, now: Date) throws {
        guard var entry = entry(id) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: entryURL(id).path]) }
        entry.finishedAt = Self.seconds(now)
        try write(entry)
        try OneWaySyncFiles.remove(ticksURL(id))
    }

    /// The entry with its ticks folded in, or nil when it's missing, unreadable or of another
    /// version.
    public func entry(_ id: UUID) -> OneWaySyncHistoryEntry? {
        guard let data = try? Data(contentsOf: entryURL(id)) else { return nil }
        struct Header: Decodable { var version: Int }
        guard (try? JSONDecoder().decode(Header.self, from: data))?.version == OneWaySyncHistoryEntry.currentVersion,
              var entry = try? JSONDecoder().decode(OneWaySyncHistoryEntry.self, from: data) else { return nil }
        if let ticks = try? Data(contentsOf: ticksURL(id)) {
            for line in ticks.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let tick = try? JSONDecoder().decode(Tick.self, from: Data(line)),
                      entry.steps.indices.contains(tick.step) else { continue }
                entry.steps[tick.step].status = tick.status
                entry.steps[tick.step].at = tick.at
                if let keptAt = tick.keptAt { entry.steps[tick.step].keptAt = keptAt }
                if let recorded = tick.recorded { entry.steps[tick.step].recorded = recorded }
            }
        }
        return entry
    }

    /// Every readable entry, newest first.
    public func entries() -> [OneWaySyncHistoryEntry] {
        entryIDs().compactMap(entry).sorted { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
    }

    /// Entries of the record's first run that a crash or a quit cut short, oldest first: the sync
    /// to recover before the next one. One from an earlier first run names records that are
    /// gone; `prune` takes it.
    public func unfinished(firstRun: UUID) -> [OneWaySyncHistoryEntry] {
        entries().filter { $0.finishedAt == nil && $0.firstRun == firstRun }.reversed()
    }

    /// Whether *Reverse in iCloud* may be offered on `entry` at all: finished, made under the
    /// record's current first run, and under 90 days old. Each item also needs to be unchanged on
    /// both sides, which is the caller's to check against `recorded`.
    public static func canReverse(_ entry: OneWaySyncHistoryEntry, firstRun: UUID, now: Date) -> Bool {
        guard entry.finishedAt != nil, entry.firstRun == firstRun else { return false }
        let age = seconds(now) - entry.startedAt
        return age >= 0 && age < keep
    }

    /// Removes what can no longer be shown or recovered: finished entries started 90 days or
    /// more before `now`, unfinished ones of an earlier first run, and files this build can't
    /// read last changed 90 days or more ago. An unfinished entry of the current first run stays
    /// until its recovery finishes it. A clock moved backwards removes nothing by age.
    @discardableResult
    public func prune(now: Date, firstRun: UUID) -> Int {
        let cutoff = Self.seconds(now) - Self.keep
        var removed = 0
        func remove(_ id: UUID) {
            try? OneWaySyncFiles.remove(ticksURL(id))
            if (try? OneWaySyncFiles.remove(entryURL(id))) != nil { removed += 1 }
        }
        for id in entryIDs() {
            guard let entry = entry(id) else {
                let changed = (try? entryURL(id).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let changed, Self.seconds(changed) <= cutoff { remove(id) }
                continue
            }
            if entry.finishedAt == nil ? entry.firstRun != firstRun : entry.startedAt <= cutoff { remove(id) }
        }
        return removed
    }

    /// The same waits, in any order.
    static func sameWaits(_ a: [OneWaySyncWait], _ b: [OneWaySyncWait]) -> Bool {
        a.count == b.count && a.allSatisfy(b.contains) && b.allSatisfy(a.contains)
    }

    // MARK: Files

    func entryURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    func ticksURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).ticks") }

    private func entryIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
    }

    private func write(_ entry: OneWaySyncHistoryEntry) throws {
        try OneWaySyncFiles.writeDurably(OneWaySyncStore.encode(entry), to: entryURL(entry.id))
    }

    private struct Tick: Codable {
        var step: Int
        var status: OneWaySyncHistoryStep.Status
        var at: Int64
        var keptAt: String?
        var recorded: OneWaySyncFileRecord?
    }

    public static func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
}
