import Foundation

/// Removes a test's log or history file and the `.lock` sidecar `LogFileWriter`'s trim lock
/// creates beside it.
///
/// **Drain every writer on the file first**: declare `defer { writer.flush() }` (or
/// `flushToDisk()`) after the writer, so it runs before this. The writer's queue may still be
/// trimming or appending when the test returns, and a write after the removal recreates the file.
func removeLogFiles(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(atPath: url.path + ".lock")
}
