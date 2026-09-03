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
///
/// **The buffer is observed here and not by `ContentView`, which is the point of it being a
/// modifier at all.** `ContentView` holds the document as an `@ObservedObject` and the App scene
/// holds it as a `@StateObject`, so while the text was published from the document a keystroke
/// re-evaluated the whole window and the whole menu tree to restart one timer. The text now lives
/// on `EditorBuffer` and this modifier is one of the three things that watch it — a change
/// re-invokes `body(content:)` here and nothing above it, because `content` is a proxy rather than
/// a view to rebuild.
struct EditorAutosaveDriver: ViewModifier {
    /// Watched for the file's identity and whether it can be saved at all.
    @ObservedObject var document: EditorDocument
    /// Watched for the version counter the debounce is keyed on — see ``EditorBuffer``.
    @ObservedObject var buffer: EditorBuffer
    /// How long the typing must settle. Injected so a test does not have to wait two real seconds.
    var quiet: Duration = EditorAutosave.quietInterval
    let write: () -> Void

    func body(content: Content) -> some View {
        content.task(id: EditorAutosave.Key(version: buffer.textVersion, path: document.path)) {
            // Nothing to schedule for a document that cannot be written — a read-only decode, a
            // refusal, or nothing open. The flushes at every route out ask the same question again.
            guard document.canSave else { return }
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            write()
        }
    }
}
