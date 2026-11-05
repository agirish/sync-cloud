import SwiftUI

private struct RunWriteLockKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    /// Why writes wait right now ("Wait for the copy to finish"), or `nil` when nothing is running.
    /// Set at the window's root from `FileSyncManager.activeProgress`, so the window stays readable
    /// during a long run while every control that would write to disk greys itself and says why.
    var runWriteLock: String? {
        get { self[RunWriteLockKey.self] }
        set { self[RunWriteLockKey.self] = newValue }
    }
}

public extension View {
    /// For a control that writes to disk: disabled while a run is going, the reason its tooltip.
    ///
    /// Apply it inside the control's own `.help`: macOS shows the innermost tooltip, so the reason
    /// replaces the usual words only while the lock holds.
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
