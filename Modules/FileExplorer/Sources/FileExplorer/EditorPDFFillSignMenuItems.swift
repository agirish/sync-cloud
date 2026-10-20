import SwiftUI

/// **File ▸ Fill & Sign and Save Filled Copy** — the header button and the save pill's save, in
/// the menu bar. The same acts (``EditorPDFFillSign/toggle()``, ``EditorPDFFillSign/save()``) under
/// the same rules: ticked while the palette is up, and Save live exactly where the pill's is.
///
/// **Greyed where the button would only explain**: a refused file gets the toggle greyed and the
/// reason as a line under it, as File ▸ PDF Tools says a locked file's — the button, pressed, puts
/// the same reason up as an alert. With no file it is greyed by ``EditorPDFFillSign/hasPages``.
public struct EditorPDFFillSignMenuItems: View {
    @ObservedObject var fill: EditorPDFFillSign
    @ObservedObject var tools: EditorPDFTools

    public init(fill: EditorPDFFillSign, tools: EditorPDFTools) {
        self.fill = fill
        self.tools = tools
    }

    /// Add Signature's sheet, or a PDF tool's.
    private var sheetIsUp: Bool { fill.addingSignature != nil || tools.sheet != nil }

    public var body: some View {
        Toggle("Fill & Sign", isOn: Binding(
            get: { fill.isOn },
            // The button's act either way: off with unsaved items asks first.
            set: { _ in fill.toggle() }
        ))
        // Greyed under a sheet too: the menu bar stays live over one, and the toggle's `clear()`
        // took the Add Signature sheet down with the strokes drawn in it.
        .disabled(!fill.hasPages || fill.refusal != nil || sheetIsUp || (fill.isOn && tools.running != nil))
        if let reason = fill.menuReason {
            Text(reason)
        }
        Button("Save Filled Copy") { Task { await fill.save() } }
            .disabled(!fill.canSave || tools.running != nil || sheetIsUp)
    }
}
