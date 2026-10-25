import SwiftUI

private struct RunWriteLockKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    /// **Why writes wait right now** — "Wait for the copy to finish" — or `nil` when nothing is
    /// running. Set once at the window's root from the run on `FileSyncManager.activeProgress`
    /// (decision BZ): the window stays usable for reading during a long run, and every control
    /// that would write to disk reads this, greys itself, and says why.
    var runWriteLock: String? {
        get { self[RunWriteLockKey.self] }
        set { self[RunWriteLockKey.self] = newValue }
    }
}

public extension View {
    /// **A control that writes to disk**: disabled while a run is going, its tooltip the reason.
    ///
    /// Apply it INSIDE the control's own `.help`: the innermost tooltip is the one macOS shows, so
    /// the reason replaces the control's usual words only while the lock holds.
    /// - Parameter applies: `false` for a control built by a shared helper that writes only
    ///   sometimes — Compare beside Copy in one bar.
    func lockedDuringRun(_ applies: Bool = true) -> some View {
        modifier(RunWriteLockModifier(applies: applies))
    }
}

struct RunWriteLockModifier: ViewModifier {
    let applies: Bool
    @Environment(\.runWriteLock) private var reason

    func body(content: Content) -> some View {
        if applies, let reason {
            content
                .disabled(true)
                .help(reason)
        } else {
            content
        }
    }
}
