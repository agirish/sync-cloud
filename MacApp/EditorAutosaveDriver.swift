import SwiftUI
import FileExplorer

/// The timer half of autosave: waits for the typing to settle, then asks the host to write.
///
/// A modifier on `ContentView`, not the editor's view, because the workspace view is torn down on
/// every tab switch, which is exactly when the flush matters; `ContentView` outlives it. And it
/// observes `EditorBuffer` itself, so a keystroke re-invokes only this `body(content:)`, not the
/// whole window and menu tree.
///
/// `.task(id:)` is the debounce: each keystroke restarts it, so a burst of typing writes once. The
/// key is the buffer's version counter, not the text, since comparing a large string every render
/// costs more than the write. The path is in the key too: two documents can sit at the same
/// version, and a pending write must not land on the previous file.
struct EditorAutosaveDriver: ViewModifier {
    /// Watched for the file's identity and whether it can be saved at all.
    @ObservedObject var document: EditorDocument
    /// Watched for the version counter the debounce is keyed on — see ``EditorBuffer``.
    @ObservedObject var buffer: EditorBuffer
    /// How long the typing must settle. Injected so a test does not have to wait two real seconds.
    var quiet: Duration = EditorAutosave.quietInterval
    let write: () -> Void

    func body(content: Content) -> some View {
        // The stamp too, so a write that commits with typing still unsaved starts the wait again;
        // see ``EditorAutosave/Key``.
        content.task(id: EditorAutosave.Key(version: buffer.textVersion, path: document.path,
                                            stamp: document.stamp)) {
            // Nothing to schedule for a document that can't be written (a read-only decode, a
            // refusal, nothing open). The flushes at every route out ask the same again.
            guard document.canSave else { return }
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            write()
        }
    }
}
