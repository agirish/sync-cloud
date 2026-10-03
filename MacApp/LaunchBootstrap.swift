import Foundation

/// **Whether this run's launch bootstrap has finished** — provider discovery, the panes on their
/// landing folders, the browse tabs restored. Set once, by the bootstrap's own last step, and never
/// cleared.
///
/// **Here, not only on `ContentView`, because the view's own flag can be lowered early.** Measured
/// 2026-10-03 with a per-view token logged in `onAppear`: a launch caused by opening a file from
/// Finder runs `onAppear` TWICE, the same view both times, because SwiftUI re-presents the window
/// for the open event. The second run takes the reopen path, whose `.endProviderBootstrapGuard`
/// cleared `isBootstrappingProviders` at once — while the first run's discovery was still going.
/// Every guard reading that flag was down for the rest of discovery: a provider write was taken as
/// the user switching provider, and the opened file's pane move could be undone. The same re-run
/// happens on every later open from Finder, and on a window closed and brought back.
///
/// So the reopen path asks this instead of assuming no discovery is pending, and the opens from
/// Finder wait on it. Owned by the delegate, for the same reason as ``ExternalOpenQueue``: it has
/// to outlive any view that reads it.
@MainActor
final class LaunchBootstrap: ObservableObject {
    @Published private(set) var isFinished = false

    func finish() {
        if !isFinished { isFinished = true }
    }
}
