import Foundation

/// Whether this run's launch bootstrap has finished: provider discovery, the panes on their
/// landing folders, the browse tabs restored. Set once, by the bootstrap's last step, and never
/// cleared.
///
/// Kept here, not only on `ContentView`, because the view's flag can be lowered early. An open
/// from Finder makes SwiftUI re-present the window and run `onAppear` twice on the same view, and
/// the second run's reopen path would clear `isBootstrappingProviders` while discovery is still
/// going, so a provider write reads as a user switch and an opened file's pane move can be undone.
/// The reopen path asks this instead, and opens from Finder wait on it. Owned by the delegate, like
/// ``ExternalOpenQueue``, so it outlives any view that reads it.
@MainActor
final class LaunchBootstrap: ObservableObject {
    @Published private(set) var isFinished = false

    func finish() {
        if !isFinished { isFinished = true }
    }
}
