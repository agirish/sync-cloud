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

    /// The width a rule at `location` has to span: the column, less the indent its paragraph starts
    /// at — a rule in a list item ran past the column's edge by the item's indent (review, 2026-10-09).
    static func column(_ columnWidth: CGFloat, at location: Int, in text: NSAttributedString) -> CGFloat {
        let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        return columnWidth - (style?.headIndent ?? 0)
    }

    /// Gives every attachment in `text` an image and bounds. `columnWidth` is the text column, which
    /// a rule spans from its indent.
    static func dress(_ text: NSMutableAttributedString, scale: CGFloat, columnWidth: CGFloat) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.previewAttachment, in: whole) { value, range, _ in
            guard let raw = value as? String, let kind = Kind(rawValue: raw),
                  let attachment = text.attribute(.attachment, at: range.location, effectiveRange: nil)
                    as? NSTextAttachment else { return }
            dress(attachment, as: kind, scale: scale, columnWidth: column(columnWidth, at: range.location, in: text))
            // A task's box keeps a gap before its words (reported 2026-10-05: "☐boil water") — as
            // kerning, since widening the bounds would stretch the box.
            if kind == .task || kind == .taskDone {
                text.addAttribute(.kern, value: 6 * scale, range: range)
            }
        }
    }

    /// `reason` is why an image cannot be drawn, for its placeholder to say after its alt text.
    static func dress(_ attachment: NSTextAttachment, as kind: Kind, scale: CGFloat, columnWidth: CGFloat,
                      reason: String? = nil) {
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
            // an image inside a sentence, and for front matter, which stays folded. **The alt text
            // leads**, as in the read-only Preview: it is what the author wrote to stand for the
            // picture, so it is the more useful half when the picture is missing.
            let name = (attachment as? PreviewImageAttachment)?.label ?? accessibilityLabel(for: kind)
            let label = reason.map { "\(name) — \($0)" } ?? name
            let font = placeholderFont(scale: scale)
            let box = placeholderSize(label, scale: scale)
            attachment.image = NSImage(size: box, flipped: false) { rect in
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                (label as NSString).draw(at: NSPoint(x: 8 * scale, y: 3 * scale),
                                         withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                return true
            }
            attachment.bounds = placeholderBounds(label, scale: scale)
            attachment.image?.accessibilityDescription = label
            return
        }
        attachment.image?.accessibilityDescription = accessibilityLabel(for: kind)
    }

    private nonisolated static func placeholderFont(scale: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: 11 * scale)
    }

    /// A placeholder's box: `label` in its type, with room around it.
    nonisolated static func placeholderSize(_ label: String, scale: CGFloat) -> NSSize {
        let size = (label as NSString).size(withAttributes: [.font: placeholderFont(scale: scale)])
        return NSSize(width: size.width + 16 * scale, height: size.height + 6 * scale)
    }

    /// Where a placeholder sits on its line — what the projection gives an image before the view
    /// dresses it, so a table holding one is measured with it (review, 2026-10-09: measured with an
    /// empty attachment, the column was the picture's placeholder too narrow).
    nonisolated static func placeholderBounds(_ label: String, scale: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: 0, y: -3 * scale), size: placeholderSize(label, scale: scale))
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

/// **An image's U+FFFC, holding the alt text its picture stands for** (review, 2026-10-09).
///
/// The read-only Preview read the alt to VoiceOver and led its placeholder with it; the editable one
/// read "Image" for every picture, and a missing one said only "Image — reason". The projection
/// makes one of these for every image it leaves, and whatever is drawn in it — the placeholder, or
/// the picture once it loads — is described by the alt. The alt is also on the character as
/// ``NSAttributedString/Key/previewImageAlt``, so a changed alt differs in the rendering and the
/// view takes the new attachment.
final class PreviewImageAttachment: NSTextAttachment {

    var alt = ""

    /// What VoiceOver reads for the picture: its alt text, or "Image" where it has none.
    var label: String { alt.isEmpty ? "Image" : alt }

    /// Each picture set here is a copy described by this alt: one decoded picture is shared by every
    /// attachment showing its source, and each may have alt text of its own.
    override var image: NSImage? {
        get { super.image }
        set {
            // The same picture again, under the same alt — each decoration of the paragraph around
            // it sets it — keeps the copy it has: a copy per keystroke (round 2, 2026-10-10).
            if let newValue, newValue === original, super.image?.accessibilityDescription == label { return }
            original = newValue
            let copy = newValue?.copy() as? NSImage
            copy?.accessibilityDescription = label
            super.image = copy
        }
    }

    /// The picture last set, which ``image`` holds a copy of.
    private weak var original: NSImage?
}
