import Design
import SwiftUI

extension View {
    /// An editor mounted in a test reads its settings from a suite of its own, never from
    /// `UserDefaults.standard`. The editors read `EditorTextSettings` through `@AppStorage`, and
    /// under `swift test` the standard domain is `swiftpm-testing-helper`, shared by every local
    /// run, worktree and the CI runner: a leaked key (spell checking on, say) or another process's
    /// write would reach every mount. A spell check plus an outside change can deadlock a SwiftUI
    /// focus move (`docs/flaky-tests.md`, "A spell check and a defaults change from another process
    /// deadlock a SwiftUI focus move"). A suite doesn't search the app's domain, so nothing outside
    /// the process reaches it and spelling stays off. A test about a setting writes it here.
    func editorTestDefaults(_ defaults: UserDefaults) -> some View {
        defaultAppStorage(defaults)
    }

    /// The same, on a fresh ``ScratchDefaults`` the mount keeps alive and wipes when it goes.
    func editorTestDefaults(_ name: String = "EditorMount") -> some View {
        defaultAppStorage(ScratchDefaults(name))
    }
}
