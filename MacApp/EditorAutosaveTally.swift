import Foundation
import Design
import Events

/// Autosave's record in the log at the shipped level: the first autosave of a document at Info,
/// then one Info line with the count and the time of the last, when the document is switched
/// away from, closed, or the app quits. Each autosave in between stays a Debug line.
///
/// One per two seconds of typing would bury the failures the log is kept for, but with no Info
/// line at all "did autosave write my file before it vanished" had no answer at the default level.
///
/// Keyed by path and held for the process, not per window: the document outlives the window
/// (`SyncCloudApp.editorDocument`).
@MainActor
enum EditorAutosaveTally {
    private struct Count {
        var more = 0
        var last = Date()
    }

    private static var counts: [String: Count] = [:]

    /// Notes one autosave of `path` and returns the level its line is written at: Info for the
    /// document's first since it was opened, Debug after.
    static func note(_ path: String, at now: Date = Date()) -> LogLevel {
        guard var count = counts[path] else {
            counts[path] = Count(more: 0, last: now)
            return .info
        }
        count.more += 1
        count.last = now
        counts[path] = count
        return .debug
    }

    /// The closing line for `path`, or nil when it was autosaved at most once, and forgets it, so
    /// a reopened document starts again at Info.
    static func closeOut(_ path: String?) -> String? {
        guard let path, let count = counts.removeValue(forKey: path), count.more > 0 else { return nil }
        return "Editor autosaved \(path) \(count.more) more time(s) since the first, the last at "
            + timeFormatter.string(from: count.last)
    }

    /// Every open tally's closing line, for quitting.
    static func closeOutAll() -> [String] {
        counts.keys.sorted().compactMap { closeOut($0) }
    }

    /// Zone-refreshed, as every shipped formatter is: a captured zone would print a wrong clock
    /// after a time-zone change (`CapturedTimeZoneScanTests`).
    private static let timeFormatter = ZoneRefreshedFormatter.fixed("HH:mm:ss")
}
