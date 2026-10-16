import SwiftUI

extension View {
    /// **An editor mounted in a test reads its settings from a suite of its own, never from
    /// `UserDefaults.standard`.**
    ///
    /// `PlainTextEditor` and `PreviewEditorView` read Check Spelling While Typing (and the rest of
    /// `EditorTextSettings`) through `@AppStorage`, and under `swift test` the standard domain is
    /// `swiftpm-testing-helper` — one domain shared by every local run, every worktree and the CI
    /// runner. On 2026-10-15 it held `editorChecksSpelling = 1`, which no test leaves behind on
    /// purpose, so every editor mounted there spell-checked; and every other test process writing
    /// an editor key there reached this one as a change from outside. A spell check, an outside
    /// change and a SwiftUI focus move together can deadlock a run: the spell checker's thread
    /// delivers the change to SwiftUI while holding its own lock, and the main thread, inside
    /// SwiftUI's update, waits on that lock. `docs/flaky-tests.md` ▸ *A spell check and a defaults
    /// change from another process deadlock a SwiftUI focus move* has the stacks. The spell check
    /// itself is closed off for the whole test process by `TestProcessTextChecking`; this is still
    /// what keeps a leaked value or another run's write out of the editors' settings.
    ///
    /// A suite does not search the app's domain — measured: a key written to the process's own
    /// domain from outside reads `nil` through `UserDefaults(suiteName:)` — so a value left in
    /// `swiftpm-testing-helper` cannot reach the mount, nothing outside the process writes the
    /// suite, and spelling stays at its default, off. A test about the setting writes it here.
    func editorTestDefaults(_ defaults: UserDefaults) -> some View {
        defaultAppStorage(defaults)
    }

    /// The same, on a fresh ``ScratchDefaults`` the mount keeps alive and wipes when it goes.
    func editorTestDefaults(_ name: String = "EditorMount") -> some View {
        defaultAppStorage(ScratchDefaults(name))
    }
}
