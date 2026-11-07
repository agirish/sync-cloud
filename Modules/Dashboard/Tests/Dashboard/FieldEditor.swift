import AppKit

/// The revealed search field's own text view, which is what a keystroke or submission has to come
/// from.
@MainActor
enum FieldEditor {
    static func find(in window: NSWindow) -> NSTextView? {
        var found: NSTextView?
        func walk(_ v: NSView) {
            if found == nil, let text = v as? NSTextView, text.isEditable { found = text }
            for sub in v.subviews where found == nil { walk(sub) }
        }
        walk(window.contentView!)
        return found
    }
}
