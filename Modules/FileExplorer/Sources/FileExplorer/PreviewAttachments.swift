import AppKit

/// **What the editable Preview draws for each U+FFFC the projection leaves** (TE67 §3.8): a task's
/// box, a rule, an image, front matter. The projection marks each with ``NSAttributedString/Key/previewAttachment``
/// and leaves the attachment empty; this gives it something to draw and a size.
///
/// Each is atomic — one character the caret steps over and an edit cannot enter (the translator
/// refuses ``PreviewRefusal/notText``). A task box is the one that does something when clicked:
/// ``PreviewTextView`` sends the click as ``RenderedEdit/Action/tickTask``.
@MainActor
enum PreviewAttachments {

    /// What a `previewAttachment` value stands for.
    enum Kind: String {
        case task, taskDone, image, inlineImage, rule, frontMatter
    }

    /// Gives every attachment in `text` an image and bounds. `columnWidth` is the text column, which
    /// a rule spans.
    static func dress(_ text: NSMutableAttributedString, scale: CGFloat, columnWidth: CGFloat) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.previewAttachment, in: whole) { value, range, _ in
            guard let raw = value as? String, let kind = Kind(rawValue: raw),
                  let attachment = text.attribute(.attachment, at: range.location, effectiveRange: nil)
                    as? NSTextAttachment else { return }
            dress(attachment, as: kind, scale: scale, columnWidth: columnWidth)
            attachment.image?.accessibilityDescription = accessibilityLabel(for: kind)
            // A task's box keeps a gap before its words (reported 2026-10-05: "☐boil water") — as
            // kerning, since widening the bounds would stretch the box.
            if kind == .task || kind == .taskDone {
                text.addAttribute(.kern, value: 6 * scale, range: range)
            }
        }
    }

    static func dress(_ attachment: NSTextAttachment, as kind: Kind, scale: CGFloat, columnWidth: CGFloat,
                      label custom: String? = nil) {
        switch kind {
        case .task, .taskDone:
            let side = 14 * scale
            let symbol = kind == .task ? "square" : "checkmark.square.fill"
            attachment.image = symbolImage(symbol, side: side)
            attachment.bounds = CGRect(x: 0, y: -2 * scale, width: side, height: side)
        case .rule:
            let width = max(40, columnWidth - 4)
            attachment.image = NSImage(size: NSSize(width: width, height: 9 * scale), flipped: false) { rect in
                NSColor.separatorColor.setFill()
                NSRect(x: 0, y: rect.midY - 0.5, width: rect.width, height: 1).fill()
                return true
            }
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: 9 * scale)
        case .image, .inlineImage, .frontMatter:
            // A labelled placeholder: while an image loads, where it cannot be drawn (with why), for
            // an image inside a sentence, and for front matter, which stays folded.
            let label = custom ?? (kind == .frontMatter ? "Front matter" : "Image")
            let font = NSFont.systemFont(ofSize: 11 * scale)
            let size = (label as NSString).size(withAttributes: [.font: font])
            let box = NSSize(width: size.width + 16 * scale, height: size.height + 6 * scale)
            attachment.image = NSImage(size: box, flipped: false) { rect in
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                (label as NSString).draw(at: NSPoint(x: 8 * scale, y: 3 * scale),
                                         withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                return true
            }
            attachment.bounds = CGRect(origin: CGPoint(x: 0, y: -3 * scale), size: box)
        }
    }

    /// One image per symbol and size, made once: a document's every box was a new SF Symbol image
    /// on every keystroke.
    private static var symbols: [String: NSImage] = [:]

    private static func symbolImage(_ name: String, side: CGFloat) -> NSImage? {
        let key = "\(name)@\(side)"
        if let image = symbols[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side, weight: .regular))
        symbols[key] = image
        return image
    }

    static func accessibilityLabel(for kind: Kind) -> String {
        switch kind {
        case .task: return "Task, not done"
        case .taskDone: return "Task, done"
        case .image, .inlineImage: return "Image"
        case .rule: return "Divider"
        case .frontMatter: return "Front matter"
        }
    }
}
