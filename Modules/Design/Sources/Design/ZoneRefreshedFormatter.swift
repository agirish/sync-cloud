import Foundation

/// A shared `DateFormatter` that re-checks the system time zone on every use instead of capturing
/// it once.
///
/// **The defect this exists to prevent.** A `DateFormatter` whose `timeZone` is never set takes the
/// system zone the first time it formats and keeps it for the life of the process. Every date
/// column in this app is a `static let` built once for exactly the right reason — `DateFormatter`
/// is expensive to construct and these run per row, per render — so every one of them kept
/// whichever zone was current when its window first drew. These are windows people leave open, so
/// after a Date & Time change or a flight the column went on reading in the old zone for the rest
/// of the session, an hour or five and a half out, with nothing anywhere saying so.
///
/// **Why this is one type and not a rule copied eleven times.** Three types were fixed one at a
/// time, then eight more sites turned up carrying the same defect, and the fix for each is the same
/// three lines. Eleven types hold sixteen of these formatters between them — `LogGrouping` and
/// `RestructureLens` have three each — so a per-type accessor meant eleven copies of one rule.
/// The `LogViewer` fix already had to delete a verbatim duplicate of its own formatter for this
/// reason: two copies of one rule is how a refresh gets half-applied — the entry rows following a
/// Date & Time change while the folded-run headers directly above them do not, in the same list,
/// with no version of the code saying which is right. Eleven copies is that hazard eleven times
/// over. This is in Design for `ScanFreshness`' reason: Dashboard and FileExplorer both need it and
/// neither can see the other.
///
/// **The one deliberate exception is `Events.LogTimestampFormatter`.** Events is a leaf module that
/// must not depend on Design, and its formatter answers a harder question than these do — it writes
/// `~/sync-cloud.log` and parses history lines back out of it, so the zone decision there is about
/// the file rather than a column. Its doc comment carries that reasoning; do not fold it in here.
///
/// **Locked, not merely shared.** Most callers are `View`s and reach this only from the main actor,
/// but `DetailsSidebar` deliberately does not: its formatter is `nonisolated` so the stat that
/// reads it can run off the main actor. Reading a `DateFormatter` concurrently is safe; writing
/// `timeZone` on one thread while another formats is not. So the zone check and the use are both
/// taken under the lock, and the formatter itself never escapes — `string(from:)` and
/// `date(from:)` are the whole surface, so no caller can hold one across a zone change. Measured
/// cost of the guard over 200k iterations: the lock is 0.009 µs and the zone compare 0.212 µs,
/// against 1.29 µs for the format itself.
///
/// (DST is not this question — a `TimeZone` handles its own transitions.)
///
/// **What this does NOT fix: the locale is still captured.** `DateFormatter` resolves `locale` at
/// construction, so a region change mid-session goes unnoticed the same way a zone change used to.
/// That is a real sibling defect and deliberately out of scope here; ``fixed(_:)`` is immune to it
/// by pinning, and the two localized cases are not.
public final class ZoneRefreshedFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: DateFormatter

    private init(_ formatter: DateFormatter) {
        self.formatter = formatter
    }

    /// A fixed-format formatter with locale and calendar **pinned** (`en_US_POSIX` + Gregorian).
    ///
    /// Both pins matter and neither is about the zone. An unpinned fixed-format `DateFormatter`
    /// follows the system region, which can rewrite even an explicit `HH` into a 12-hour clock; and
    /// an unpinned calendar renders Gregorian dates as another calendar's years — a Buddhist region
    /// showed 2569, an Islamic one 1448. Use this for anything that round-trips, is compared, or has
    /// to agree byte-for-byte with a file or the clipboard.
    public static func fixed(_ format: String) -> ZoneRefreshedFormatter {
        let made = DateFormatter()
        made.locale = Locale(identifier: "en_US_POSIX")
        made.calendar = Calendar(identifier: .gregorian)
        made.dateFormat = format
        return ZoneRefreshedFormatter(made)
    }

    /// A formatter following the reader's own locale, by style. For text that is only ever read by
    /// a person — a Modified column, a card's meta line — where matching their region is the point.
    public static func localized(date: DateFormatter.Style,
                                 time: DateFormatter.Style) -> ZoneRefreshedFormatter {
        let made = DateFormatter()
        made.dateStyle = date
        made.timeStyle = time
        return ZoneRefreshedFormatter(made)
    }

    /// A formatter built from a localized template (`setLocalizedDateFormatFromTemplate`), which
    /// picks the field ORDER the reader's region uses while fixing which fields appear.
    public static func template(_ template: String) -> ZoneRefreshedFormatter {
        let made = DateFormatter()
        made.setLocalizedDateFormatFromTemplate(template)
        return ZoneRefreshedFormatter(made)
    }

    /// Renders `date`, in `zone` — the system zone unless a caller names one.
    ///
    /// The `zone` parameter exists for snapshot references, which otherwise bake in the recording
    /// machine's zone and go red on a frozen fixture when that machine moves. That has happened and
    /// cost a day; see `DashboardSnapshotTests.pinnedZone`.
    public func string(from date: Date, in zone: TimeZone = .current) -> String {
        lock.lock()
        defer { lock.unlock() }
        refresh(to: zone)
        return formatter.string(from: date)
    }

    /// Reads a rendered timestamp back, in `zone` — the same zone ``string(from:in:)`` writes in,
    /// which is the pairing any round trip depends on.
    public func date(from text: String, in zone: TimeZone = .current) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        refresh(to: zone)
        return formatter.date(from: text)
    }

    /// The zone the shared formatter is on right now. A test seam: it is what lets the refresh be
    /// observed without moving `NSTimeZone.default`, which is process-wide and would race every
    /// other suite in the run.
    public var zone: TimeZone {
        lock.lock()
        defer { lock.unlock() }
        return formatter.timeZone
    }

    /// Puts the formatter on `zone` **without** refreshing, so a test can stage the stale state
    /// this type exists to prevent. Test-only; nothing in the app calls it.
    public func stageZoneForTesting(_ zone: TimeZone) {
        lock.lock()
        formatter.timeZone = zone
        lock.unlock()
    }

    /// Callers must hold `lock`. The compare is cheap and the assignment only runs when the zone
    /// has actually moved.
    private func refresh(to zone: TimeZone) {
        if formatter.timeZone != zone { formatter.timeZone = zone }
    }
}
