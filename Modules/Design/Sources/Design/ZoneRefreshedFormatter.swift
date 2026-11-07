import Foundation

/// A shared `DateFormatter` that re-checks the system time zone on every use instead of capturing
/// it once.
///
/// A `DateFormatter` whose `timeZone` is never set takes the system zone the first time it formats
/// and keeps it for the life of the process. The app's date columns are `static let`s, because a
/// `DateFormatter` is expensive and these run per row, per render; so after a Date & Time change or
/// a flight, a window left open would silently read in the old zone for the rest of the session.
///
/// One type, not a rule copied per formatter: many types hold these formatters, and copies of one
/// rule get half-applied (rows following a zone change while the headers above them don't). It
/// lives in Design because Dashboard and FileExplorer both need it and neither can see the other.
/// `CapturedTimeZoneScanTests` fails on a shipped file outside its allow-list that builds its own
/// `DateFormatter`.
///
/// The one exception is `Events.LogTimestampFormatter`: Events is a leaf module that must not
/// depend on Design, and its formatter writes and parses `~/sync-cloud.log`, so its zone decision
/// is about the file. Its doc comment carries that reasoning; do not fold it in here.
///
/// Locked, not merely shared: `DetailsSidebar`'s formatter is `nonisolated` so its stat can run
/// off the main actor, and writing `timeZone` while another thread formats is unsafe. The zone
/// check and the use both happen under the lock, and the formatter never escapes (`string(from:)`
/// and `date(from:)` are the whole surface). The guard costs about 0.2 µs against 1.3 µs for the
/// format itself.
///
/// DST is not this question: a `TimeZone` handles its own transitions.
///
/// The locale is still captured: `DateFormatter` resolves `locale` at construction, so a region
/// change mid-session goes unnoticed. Deliberately out of scope; ``fixed(_:)`` is immune by
/// pinning, the two localized cases are not.
public final class ZoneRefreshedFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: DateFormatter

    private init(_ formatter: DateFormatter) {
        self.formatter = formatter
    }

    /// A fixed-format formatter with locale and calendar pinned (`en_US_POSIX`, Gregorian).
    /// Unpinned, the system region can rewrite even an explicit `HH` into a 12-hour clock, and
    /// another calendar renders other years (a Buddhist region shows Buddhist-era years). Use this
    /// for anything that round-trips, is compared, or must match a file or the clipboard byte for
    /// byte.
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

    /// Renders `date`, in `zone`: the system zone unless a caller names one. `zone` lets a test pin
    /// the zone, so a frozen fixture doesn't change when the machine moves.
    ///
    /// `locale` renders one string in another region and puts the formatter back, under the lock,
    /// so a test can pin a 12-hour against a 24-hour reading of a ``localized(date:time:)``
    /// formatter whatever the Mac's region. A style-built formatter re-derives its pattern from the
    /// new locale; a ``fixed(_:)`` one keeps its pattern, so such a test fails against a fixed
    /// format.
    public func string(from date: Date, in zone: TimeZone = .current, locale: Locale? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }
        refresh(to: zone)
        guard let locale, locale != formatter.locale else { return formatter.string(from: date) }
        let kept = formatter.locale
        formatter.locale = locale
        defer { formatter.locale = kept }
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
