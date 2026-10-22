import Foundation

/// **Follows changes to `defaults` without ever making the writer wait for the main thread.**
///
/// `UserDefaults.didChangeNotification` is posted on whatever thread wrote the default. An
/// observer registered with `queue: .main` makes that poster wait until the block has run on
/// main, so every background write to the domain — a test's scratch-suite wipe through
/// `UserDefaults.standard.removePersistentDomain`, a writer holding a lock — waited on the main
/// thread. With main held by one app-target test, those wipes took every user-initiated thread of
/// the cooperative pool (2026-10-20; `docs/flaky-tests.md`, "A main-queue defaults observer parks
/// every scratch-suite wipe on the main thread").
///
/// So the block runs on the posting thread: a post on the main thread rereads on the spot, as
/// `queue: .main` did — Settings ▸ Reset All Settings reaches the open reader at once — and a
/// post from any other thread only schedules the reread.
///
/// **A burst of posts off main schedules one reread**, as the `[glass]` log line's observer does:
/// a background run of writes queued one main-thread reread per write per observer, and the
/// signature store's decodes every saved signature's strokes. The flag is released before the
/// reread reads, so a write landing after the read schedules the next one, and the reread always
/// reads what is stored now — the last write is never lost.
func observeDefaultsChanges(of defaults: UserDefaults,
                            _ reread: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
    let scheduled = DefaultsRereadPending()
    return NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { reread() }
            } else if scheduled.claim() {
                Task { @MainActor in
                    scheduled.release()
                    reread()
                }
            }
        }
}

/// `observeDefaultsChanges`' "a reread is already scheduled" flag, claimed from any thread — the
/// app's `GlassLogLinePending`, which this package cannot see.
final class DefaultsRereadPending: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    /// True for the caller that should schedule the reread; false while one is already on its way.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        pending = false
    }
}
