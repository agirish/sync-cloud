import Foundation
import Testing

/// Awaits a semaphore off the main actor (a blocking `wait` on the test's actor would deadlock
/// anything the signaller needs from it). Bounded, so a mis-wired test fails instead of hanging.
func awaitSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 10) async {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            _ = semaphore.wait(timeout: .now() + timeout)
            cont.resume()
        }
    }
}

/// Polls a main-actor condition until it holds or the timeout expires, recording a labeled
/// test failure on timeout. The single shared replacement for the per-suite polling helpers
/// and the fixed post-operation sleeps that flaked under parallel-suite main-actor
/// congestion: always wait for the observable effect, never a guessed duration.
@MainActor
func waitUntil(_ what: Comment, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), what)
}

/// Creates a fresh, uniquely named temp directory for real-filesystem tests and returns it
/// CANONICALIZED — macOS's temporaryDirectory lives behind the /var -> /private/var symlink,
/// while the real enumerator and contentsOfDirectory(at:) yield canonical (/private/var/...)
/// child URLs. Code under test matches roots against those children by exact path prefix
/// (the diff engine's relative-key trim, buildTree's cache/subtree helpers), so a test using
/// the raw /var/... root would silently mismatch and pass vacuously or flake.
/// resolvingSymlinksInPath can't do this job: it deliberately STRIPS /private instead of
/// adding it — only the canonicalPath resource value gives the enumerator's form.
///
/// The caller owns cleanup: `defer { try? FileManager.default.removeItem(at: root) }`.
func makeCanonicalTempRoot(prefix: String) throws -> URL {
    let fm = FileManager.default
    let raw = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try fm.createDirectory(at: raw, withIntermediateDirectories: true)
    let canonical = try raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
    return URL(fileURLWithPath: canonical ?? raw.path, isDirectory: true)
}
