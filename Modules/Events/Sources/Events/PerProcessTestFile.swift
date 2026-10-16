import Foundation

/// The per-process files a test runner writes in place of the user's real log and history, and
/// the sweep that stops them piling up in the temp directory.
///
/// Under a test runner, `Logger.defaultLogFileURL()` and `SyncHistoryStore.defaultFileURL()` give
/// each process its own `<stem>-<pid>.<ext>`, so two concurrent runs never share — or, through a
/// clear, truncate — one file. `LogFileWriter` adds a `.lock` sidecar beside each. Nothing ever
/// removed either: Swift Testing has no process-wide teardown, so a `defer` cannot reach them, and
/// on 2026-10-15 `$TMPDIR` held ~1,200 `sync-cloud-tests` logs and ~170 history files, each with
/// its lock.
///
/// So the resolver sweeps instead, once per process, before it hands out the new path. A file is
/// removed, with every sidecar that shares its name, only when BOTH hold:
/// - its pid is no longer running (`kill(pid, 0)` says ESRCH) — a concurrent run's files are
///   live, and are the one thing this must never take; and
/// - nothing in the group has been written for ``retention``. A finished run's log is the
///   post-mortem `docs/flaky-tests.md` sends readers to, and on a machine where other sessions
///   start a test process every few minutes, "dead" alone would delete it before anyone looked.
///
/// Test-runner branch only: production resolves to `~/sync-cloud.log` and
/// `~/sync-cloud-history.jsonl` without calling anything here.
enum PerProcessTestFile {
    /// The stem of the shared logger's per-process test log.
    static let logStem = "sync-cloud-tests"
    /// The stem of the shared history store's per-process test file.
    static let historyStem = "sync-cloud-history-tests"

    /// How long a dead process's files are kept after their last write.
    static let retention: TimeInterval = 60 * 60

    /// `<stem>-<this pid>.<ext>` in the temp directory, sweeping dead runs' copies first (once per
    /// stem per process).
    ///
    /// The sweep must not log: `Logger.shared` is being initialised when the log path resolves, and
    /// a line from here would re-enter that initialiser.
    static func url(stem: String, extension ext: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
        if claimSweep(stem) {
            sweep(stem: stem, extension: ext, in: directory)
        }
        return directory.appendingPathComponent("\(stem)-\(ProcessInfo.processInfo.processIdentifier).\(ext)")
    }

    /// Removes every `<stem>-<pid>.<ext>…` in `directory` whose pid is not running and whose newest
    /// file is older than `retention`. Returns the names it removed, sorted.
    @discardableResult
    static func sweep(stem: String,
                      extension ext: String,
                      in directory: URL,
                      now: Date = Date(),
                      retention: TimeInterval = PerProcessTestFile.retention,
                      isRunning: (pid_t) -> Bool = PerProcessTestFile.isRunning) -> [String] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }

        var groups: [pid_t: [String]] = [:]
        for name in names {
            if let pid = pid(inFileNamed: name, stem: stem, extension: ext) {
                groups[pid, default: []].append(name)
            }
        }

        var removed: [String] = []
        for (pid, group) in groups where !isRunning(pid) {
            let newest = group.compactMap { name in
                (try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.modificationDate] as? Date
            }.max()
            // No readable date means another sweeper got there first; leave it to them.
            guard let newest, now.timeIntervalSince(newest) >= retention else { continue }
            for name in group where (try? fileManager.removeItem(at: directory.appendingPathComponent(name))) != nil {
                removed.append(name)
            }
        }
        return removed.sorted()
    }

    /// The pid in `<stem>-<pid>.<ext>` or one of its sidecars (`.<ext>.lock`, an atomic write's
    /// `.<ext>.sb-…`); nil for any other name.
    static func pid(inFileNamed name: String, stem: String, extension ext: String) -> pid_t? {
        let prefix = stem + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let tail = rest.dropFirst(digits.count)
        guard !digits.isEmpty,
              tail == "." + ext || tail.hasPrefix("." + ext + "."),
              let pid = pid_t(digits), pid > 0 else { return nil }
        return pid
    }

    /// Whether a process with this pid exists. EPERM (someone else's process) counts as running;
    /// only ESRCH says it is gone.
    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private static let sweptLock = NSLock()
    nonisolated(unsafe) private static var swept: Set<String> = []

    /// True the first time it is asked about `stem` in this process.
    private static func claimSweep(_ stem: String) -> Bool {
        sweptLock.lock()
        defer { sweptLock.unlock() }
        return swept.insert(stem).inserted
    }
}
