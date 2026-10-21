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
func observeDefaultsChanges(of defaults: UserDefaults,
                            _ reread: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { reread() }
            } else {
                Task { @MainActor in reread() }
            }
        }
}
