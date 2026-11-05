import Combine
import Events
import Foundation

/// Accumulates every entry the shared `Logger` publishes, from construction until it is released.
///
/// `Logger.shared.entries` is capped at 1,000 and shared by every suite running in parallel, so
/// reading the whole buffer races other suites' logging: a line can be evicted before it is read,
/// and an absence assertion then passes having examined nothing. See "A log assertion reading a
/// window that has already rolled" in `docs/flaky-tests.md`.
///
/// This removes the race. Every entry appears in the publish that appended it
/// (`flushPendingEntries` appends, then trims, and both publish), and a captured entry can't be
/// trimmed away. Each publish adds a run at the end, so a capture walks back to the last line it
/// has seen and takes what follows, rather than checking every id on every publish.
///
/// Package test targets link this library; the app target's tests compile the file in (see
/// `project.yml`). The app never links it. `LogBufferReadScanTests` holds every test tree to it.
///
/// **Construct it before the call under test**: it is a window opening, not a query.
/// ```swift
/// let log = LogCapture()
/// await manager.doTheThing()
/// #expect(await log.holds(.warning, containing: "the thing went wrong"))
/// ```
@MainActor
public final class LogCapture {
    private var seen: [LogEntry] = []
    private var ids: Set<UUID> = []
    private var primed = false
    private var cancellable: AnyCancellable?

    public init() {
        // A `@Published` publisher replays its current value on subscribe. Those lines predate the
        // capture, so they are marked seen, not captured: a sibling's identical sentence from
        // before the call under test must not satisfy it. `dropFirst()` would skip only the replay,
        // and the next publish would carry every older line anyway.
        cancellable = Logger.shared.$entries.sink { [weak self] published in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.primed else {
                    self.primed = true
                    self.ids.formUnion(published.lazy.map(\.id))
                    return
                }
                var start = published.endIndex
                while start > published.startIndex, !self.ids.contains(published[start - 1].id) {
                    start -= 1
                }
                for entry in published[start...] {
                    self.ids.insert(entry.id)
                    self.seen.append(entry)
                }
            }
        }
    }

    /// Everything captured since construction, oldest first.
    public var entries: [LogEntry] {
        get async {
            // `Logger.log` hands entries to a FIFO queue a `@MainActor` task drains, so a line just
            // written may not be published yet; awaiting one more entry drains everything enqueued
            // before it. Only that: a line sent through `Task { @MainActor in … }` may not be
            // enqueued yet ("A log line hopped to the main actor, so the capture's flush marker
            // finishes without it" in `docs/flaky-tests.md`).
            await Logger.shared.debug("log-capture flush marker").value
            return seen
        }
    }

    /// True when anything captured since construction is at `level` and contains `fragment`.
    public func holds(_ level: LogLevel, containing fragment: String) async -> Bool {
        await entries.contains { $0.level == level && $0.message.contains(fragment) }
    }

    /// True when anything captured since construction contains `fragment`, at any level.
    public func holds(containing fragment: String) async -> Bool {
        await entries.contains { $0.message.contains(fragment) }
    }

    /// The most recent captured message containing `fragment`, or nil.
    public func line(containing fragment: String) async -> String? {
        await entries.last { $0.message.contains(fragment) }?.message
    }
}
