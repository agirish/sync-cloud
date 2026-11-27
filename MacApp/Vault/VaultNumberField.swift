import AppKit
import Design
import SwiftUI

/// The editor's number field (the third review). A SwiftUI `TextField` edits in the window's
/// shared field editor, whose right-click Copy, Services, Share and text drag all reach the
/// number plainly: on the clipboard unconcealed and never cleared, or in another app. This field
/// edits in a field editor of its own, which copies and cuts only through the Vault's concealed,
/// cleared copy (``VaultPasteboard/copyConcealed(_:on:after:)``), offers no Services or Share, and
/// drags no text out. It looks as the editor's other rounded fields do.
struct VaultNumberField: NSViewRepresentable {
    @Binding var text: String
    /// Mirrors the field's focus both ways, as `.focused` does for a SwiftUI field.
    @Binding var isFocused: Bool
    var placeholder: String
    var help: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The body size, monospaced, at Settings ▸ Text size, as the SwiftUI field it replaced.
    static func font(scale: CGFloat) -> NSFont { ScaledFont.system(.body, design: .monospaced).nsFont(scale: scale) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.cell = VaultNumberFieldCell(textCell: text)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.placeholderString = placeholder
        field.font = Self.font(scale: context.environment.appFontScale)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.toolTip = help.isEmpty ? nil : help
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil { field.stringValue = text }
        field.placeholderString = placeholder
        field.toolTip = help.isEmpty ? nil : help
        let font = Self.font(scale: context.environment.appFontScale)
        if field.font != font { field.font = font }
        // Asked to take the focus (Correct the ID…): the field editor of its own comes with it.
        if isFocused, field.currentEditor() == nil, let window = field.window {
            DispatchQueue.main.async { window.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: VaultNumberField
        init(_ parent: VaultNumberField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ note: Notification) {
            VaultPasteboard.editingNumber = true
            if !parent.isFocused { parent.isFocused = true }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            VaultPasteboard.editingNumber = false
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

/// Hands its field the field editor of its own.
final class VaultNumberFieldCell: NSTextFieldCell {
    private lazy var editor: VaultNumberFieldEditor = {
        let editor = VaultNumberFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

/// A field editor that never lets the number out but the Vault's way.
final class VaultNumberFieldEditor: NSTextView {
    override func copy(_ sender: Any?) {
        guard VaultPasteboard.copyOrCut(self, cut: false, always: true) else { return }
    }

    override func cut(_ sender: Any?) {
        guard VaultPasteboard.copyOrCut(self, cut: true, always: true) else { return }
    }

    /// No Services: they hand the selected text to another app.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        sendType == nil ? super.validRequestor(forSendType: sendType, returnType: returnType) : nil
    }

    /// The right-click menu: editing alone, with no Services, Share, Look Up or Writing Tools.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    /// No text dragged out of the field: a drag is a pasteboard of its own.
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }
}
