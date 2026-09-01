import SwiftUI
import FileExplorer

/// The timer half of autosave: waits for the typing to settle, then asks the host to write.
///
/// **A `ViewModifier` on `ContentView`, not on the editor's own view.** The workspace view is torn
/// down every time you switch tabs, and a debounce living there would stop counting the moment the
/// editor left the screen — which is precisely when the flush matters. `ContentView` outlives every
/// workspace switch, so the timer does too. (`BrowseTabPersistence` is a modifier for a related
/// reason: `ContentView.body`'s modifier chain is already at the type-checker's budget.)
///
/// **`.task(id:)` IS the debounce.** SwiftUI cancels and restarts the task whenever the id changes,
/// so a keystroke throws away the pending write and starts the wait again; a burst of typing
/// therefore writes once, at the end of it. Keyed on the buffer's version counter rather than on
/// the text, for the reason `EditorDocument.textVersion` exists — comparing a 4 MiB string on every
/// render pass to decide whether to restart a timer costs more than the write it is deferring.
///
/// **The path is in the key as well as the version.** Two documents can hold the same text at the
/// same version — a fresh file opened at version 0 after another was closed at version 0 — and an
/// id that could not tell them apart would leave a pending write aimed at the previous file.
struct EditorAutosaveDriver: ViewModifier {
    @ObservedObject var document: EditorDocument
    /// How long the typing must settle. Injected so a test does not have to wait two real seconds.
    var quiet: Duration = EditorAutosave.quietInterval
    let write: () -> Void

    func body(content: Content) -> some View {
        content.task(id: EditorAutosave.Key(version: document.textVersion, path: document.path)) {
            // Nothing to schedule for a document that cannot be written — a read-only decode, a
            // refusal, or nothing open. The flushes at every route out ask the same question again.
            guard document.canSave else { return }
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            write()
        }
    }
}
