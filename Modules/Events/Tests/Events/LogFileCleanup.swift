import Foundation

/// Removes a test's log or history file and the `.lock` sidecar `LogFileWriter`'s trim lock
/// creates beside it.
///
/// Drain every writer on the file first — `defer { writer.flush() }` (or `flushToDisk()`) declared
/// AFTER the writer, so it runs BEFORE this. The writer's background queue is still running its
/// init-time trim and any appends when the test returns, and a write landing after the removal
/// recreates the file: measured 2026-10-15, one Events run left 9 `SyncHistoryStoreTest-*.jsonl`
/// that a `defer` had already removed, and every run left each fixture's `.lock`.
func removeLogFiles(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(atPath: url.path + ".lock")
}
