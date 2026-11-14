import Foundation

/// Follows changes to `defaults` without ever making the writer wait for the main thread.
///
/// `UserDefaults.didChangeNotification` is posted on the writing thread, and a `queue: .main`
/// observer makes that writer wait for main. With main busy, background writes (a test's
/// scratch-suite wipe, a writer holding a lock) can exhaust the cooperative pool
/// (`docs/flaky-tests.md`, "A main-queue defaults observer parks every scratch-suite wipe on the
/// main thread"). So a post on main rereads on the spot, and a post from any other thread only
/// schedules the reread.
///
/// A burst of posts off main schedules one reread, as the `[glass]` log line's observer does, so
/// costly rereads (the signature store decodes every saved signature) don't pile up. The flag is
/// released before the reread reads, so a later write schedules the next one and the last write
/// is never lost.
public func observeDefaultsChanges(of defaults: UserDefaults,
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

/// `observeDefaultsChanges`' "a reread is already scheduled" flag, claimed from any thread. The
/// app's `GlassLogLine` uses it too.
public final class DefaultsRereadPending: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    public init() {}

    /// True for the caller that should schedule the reread; false while one is already on its way.
    public func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        pending = false
    }
}
