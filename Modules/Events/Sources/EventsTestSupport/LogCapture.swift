import Combine
import Events
import Foundation

/// Accumulates every entry the shared `Logger` publishes, from construction until it is released.
///
/// **`Logger.shared.entries` is capped at 1,000, and every test target runs its suites in parallel
/// against that one process-wide buffer, so a whole-buffer read is a race with every other suite's
/// logging.** When it loses, `contains` finds nothing and the assertion reports a missing log line —
/// indistinguishable from the defect the test exists to catch — and an absence assertion passes
/// having examined nothing. That is "A log assertion reading a window that has already rolled" in
/// `docs/flaky-tests.md`, and it reddened the v4.4 release run and two attempts at the v4.5 one.
///
/// **The rules written in that section diagnose it; they do not fix it.** An opening marker plus a
/// `#require` makes an evicted window *say* it was evicted rather than report an absence — which is
/// the right diagnosis and still a red, and in fact a redder one, because the marker is older than
/// the lines it bounds and so is evicted first. Measured: applying them to `FilingRenamePassTests`
/// took the full package from green to failing-with-a-better-message.
///
/// This removes the race instead. An entry captured at publish time cannot be taken away by a later
/// trim, and every entry appears in at least the publish that appended it (`flushPendingEntries`
/// appends and then trims, and both mutations publish), so accumulating across publishes sees
/// everything. Deduplicated by `LogEntry.id`, since each publish carries the whole array.
///
/// **Only what is new is read.** The logger only appends at the end and trims from the front, so
/// what a publish adds is a run at the END of it; a capture walks back to the first line it has
/// already seen and takes what follows. It used to check every id in the array — up to 1,000 — on
/// every publish, and measured 2026-09-27 that cost each live capture ~240 µs of main thread per
/// publish: ten captures turned 2,000 flushes from 0.08 s into 4.9 s.
///
/// **One file for every test target.** The package test targets link this library; the app
/// target's tests compile the file in instead, for the reason `project.yml` gives. The app itself
/// never links it. `LogBufferReadScanTests` holds every test tree in the repository to it.
///
/// **Construct it BEFORE the call under test** — it is a window opening, not a query:
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
        // A `@Published` publisher replays its CURRENT value on subscribe. Those lines predate this
        // capture, so they are marked seen rather than captured: a capture means "since I started",
        // and a sibling's identical sentence from before the call under test must not satisfy it.
        // `dropFirst()`, which this replaced, skipped only the replay — the next publish still
        // carried every older line in the buffer, so each capture began with whatever it held.
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
            // The visibility half of the rolled-window section's rule 1, which this still needs:
            // `Logger.log` is `nonisolated` and hands the entry to a FIFO queue a `@MainActor` task
            // drains, so without awaiting one more entry a line the call under test just wrote may
            // not have been published yet. The queue being FIFO, this drains everything enqueued
            // before it.
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
