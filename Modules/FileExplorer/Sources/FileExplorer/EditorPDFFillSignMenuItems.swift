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
        EditorPDFFillToolMenu(fill: fill, store: fill.store, live: fill.isOn && !sheetIsUp)
        Button("Save Filled Copy") { Task { await fill.save() } }
            .disabled(!fill.canSave || tools.running != nil || sheetIsUp)
    }
}

/// **File ▸ Fill & Sign Tool** (decision AZ, 2026-10-20): the palette's tools in the menu bar, where
/// the keyboard reaches them — ⌃F2, or Help's search — and VoiceOver reads them. The palette's
/// buttons take no key unless the Mac's Keyboard navigation setting is on, and Tab on the pages
/// walks the form. Each line does what its tool does and is ticked as the tool is lit; with a tool
/// chosen, Return on the pages places its item. No chords, as for the rest of Fill & Sign.
struct EditorPDFFillToolMenu: View {
    @ObservedObject var fill: EditorPDFFillSign
    /// Observed for the Signature and Initials lists.
    @ObservedObject var store: EditorPDFSignatureStore
    /// Fill & Sign up and no sheet over it. **Each line greys on its own**: a disabled `Menu` in the
    /// menu bar leaves its lines live.
    let live: Bool

    static let title = "Fill & Sign Tool"

    var body: some View {
        Menu(Self.title) {
            if fill.form.hasFields {
                tool("Form Fields", .formFields)
                    .disabled(!live || !fill.offersFormFields)
            }
            Toggle("Select", isOn: Self.choice(fill.armed == nil) { fill.armed = nil })
                .disabled(!live)
            let places = live && fill.offersPlacing
            tool("Text", .text).disabled(!places)
            tool("Replace", .replace).disabled(!live || fill.replaceRefusal != nil)
            tool("Date", .date).disabled(!places)
            Divider()
            // The Marks flyout's own lines.
            ForEach(EditorPDFFillMark.allCases, id: \.self) { mark in
                tool("\(mark.rawValue)  \(mark.title)", .mark(mark)).disabled(!places)
            }
            Divider()
            signatures(.signature, live: places)
            signatures(.initials, live: places)
            Divider()
            Menu("Ink") {
                ForEach(EditorPDFFillColor.allCases, id: \.self) { ink in
                    Toggle(ink.title, isOn: Self.choice(fill.color == ink) { fill.setColor(ink) })
                        .disabled(!live)
                }
            }
            Menu("Text Size") {
                Button(EditorPDFFillFlyouts.smallerTitle) { fill.stepFontSize(bigger: false) }
                    .disabled(!live || !fill.canStepFontSize(bigger: false))
                Button(EditorPDFFillFlyouts.biggerTitle) { fill.stepFontSize(bigger: true) }
                    .disabled(!live || !fill.canStepFontSize(bigger: true))
                Divider()
                ForEach(EditorPDFFillSign.fontSizes, id: \.self) { size in
                    Toggle("\(Int(size)) pt", isOn: Self.choice(abs(size - fill.currentFontSize) < 0.01) { fill.setFontSize(size) })
                        .disabled(!live)
                }
            }
        }
    }

    /// A ticked line that only ever chooses: picked again, it stays chosen.
    static func choice(_ isOn: Bool, _ choose: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: { _ in choose() })
    }

    private func tool(_ title: String, _ tool: EditorPDFFillTool) -> some View {
        Toggle(title, isOn: Self.choice(fill.armed == tool) { fill.armed = tool })
    }

    /// **Signature ▸ and Initials ▸** — the palette's flyouts: the saved ones, Add…, and Delete a
    /// Saved one, which asks first (decision BE). A drawn one is named for VoiceOver by its number
    /// and pen (decision BD) and shown as its picture.
    private func signatures(_ kind: EditorPDFSignature.Kind, live: Bool) -> some View {
        let saved = store.saved(kind)
        return Menu(kind.title) {
            Text(saved.isEmpty ? "No saved \(kind.title.lowercased()) yet" : "Saved on this Mac")
            ForEach(saved) { signature in
                Toggle(isOn: Self.choice(fill.armed == .signature(signature)) { fill.armed = .signature(signature) }) {
                    label(signature, among: saved)
                }
                .disabled(!live)
            }
            Divider()
            Button("Add \(kind.title)…") { fill.addingSignature = kind }
                .disabled(!live)
            if !saved.isEmpty {
                Menu("Delete a Saved \(kind.title)") {
                    ForEach(saved) { signature in
                        Button { fill.deleteSaved(signature) } label: { label(signature, among: saved) }
                            .disabled(!live)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func label(_ signature: EditorPDFSignature, among saved: [EditorPDFSignature]) -> some View {
        let name = signature.spokenName(among: saved)
        if let picture = EditorPDFSignatureMenu.image(signature, height: 18) {
            Label { Text(name) } icon: { Image(nsImage: picture) }
        } else {
            Text(name)
        }
    }
}
