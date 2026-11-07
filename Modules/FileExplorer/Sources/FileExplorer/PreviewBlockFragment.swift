import AppKit

/// What the editable Preview draws behind its text: a bar for every level of quote, a shaded band
/// behind a code or HTML block with a code block's language over it, and a table's grid (the header
/// row tinted, a rule under every row, a line at each column's edge where the projection's tab
/// stops put them, ``NSAttributedString/Key/previewTableColumns``). Text attributes can't draw
/// these: they sit in the indent or span the column, outside any glyph. Each is drawn from its
/// block's own indent, so none reaches out under a list's markers.
///
/// TextKit 2's own hook, so the view stays on TextKit 2: a layout-fragment subclass, chosen per
/// paragraph by ``PreviewFragmentDelegate`` from the projection's attributes
/// (``NSAttributedString/Key/previewBlock``, ``NSAttributedString/Key/previewQuoteBars``). Never
/// `layoutManager`: reading it drops the view to TextKit 1 for good.
final class PreviewBlockFragment: NSTextLayoutFragment {

    /// A code block's paragraph, or an HTML block's: both drawn on a band, as the read-only Preview
    /// draws them.
    var isCode = false
    /// A fenced block's language, on its first line: drawn in the room the projection left above it.
    var language: String?
    /// Where each quote bar is drawn, from the text's left edge: the projection's, which knows the
    /// list indent each quote opened at, and how deep it draws.
    var quoteBars: [CGFloat] = []
    var quoteDepth: Int { quoteBars.count }
    var scale: CGFloat = 1
    /// A table row's column edges from the text's left edge, the last being the table's right edge.
    var tableColumns: [CGFloat]?
    var isTableHeader = false
    /// Where the text starts, inside the fragment: a table's grid and a code band are measured from
    /// here, so neither reaches out under a list's markers.
    var lead: CGFloat = 0

    /// The quote bars sit left of the text, in the indent the projection left for them; a code band
    /// runs from the text to the column's edge. Both are outside the text's own bounds.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        let left = -layoutFragmentFrame.minX
        if let last = quoteBars.last {
            bounds = bounds.union(CGRect(x: left, y: 0, width: last + 3 * scale, height: layoutFragmentFrame.height))
        }
        if isCode, let width = textLayoutManager?.textContainer?.size.width {
            bounds = bounds.union(CGRect(x: left + lead, y: 0, width: max(1, width - lead), height: layoutFragmentFrame.height))
        }
        if let edges = tableColumns, let last = edges.last {
            bounds = bounds.union(CGRect(x: left + lead - 1, y: 0, width: last + 2, height: layoutFragmentFrame.height))
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let column = point.x - layoutFragmentFrame.minX
        let height = layoutFragmentFrame.height
        context.saveGState()
        if isCode, let width = textLayoutManager?.textContainer?.size.width {
            context.setFillColor(NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor)
            context.fill(CGRect(x: column + lead, y: point.y, width: max(0, width - lead), height: height))
        }
        // TextKit drops a document's first paragraph's spacing before, and with it the room: a
        // label drawn there anyway would sit on the code.
        if let language, (textLineFragments.first?.typographicBounds.minY ?? 0) >= 10 * scale {
            // Drawn, not laid out: the read-only Preview's label, small and tertiary, above the code.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            (language as NSString).draw(at: CGPoint(x: column + lead + 2 * scale, y: point.y + 2 * scale), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9 * scale, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            NSGraphicsContext.restoreGraphicsState()
        }
        if let edges = tableColumns, let right = edges.last {
            let x = column + lead
            let row = CGRect(x: x, y: point.y, width: right, height: height)
            if isTableHeader {
                context.setFillColor(NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor)
                context.fill(row)
            }
            context.setFillColor(NSColor.separatorColor.cgColor)
            context.fill(CGRect(x: x, y: point.y + height - 1, width: right, height: 1))
            if isTableHeader { context.fill(CGRect(x: x, y: point.y, width: right, height: 1)) }
            for edge in edges { context.fill(CGRect(x: x + edge - 0.5, y: point.y, width: 1, height: height)) }
        }
        if !quoteBars.isEmpty {
            context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            for bar in quoteBars {
                context.fill(CGRect(x: column + bar, y: point.y, width: 3 * scale, height: height))
            }
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// Picks ``PreviewBlockFragment`` for every paragraph and tells it what to draw.
final class PreviewFragmentDelegate: NSObject, NSTextLayoutManagerDelegate {

    var scale: CGFloat = 1

    func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in element: NSTextElement) -> NSTextLayoutFragment {
        let fragment = PreviewBlockFragment(textElement: element, range: element.elementRange)
        fragment.scale = scale
        if let paragraph = element as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let text = paragraph.attributedString
            let block = text.attribute(.previewBlock, at: 0, effectiveRange: nil) as? String
            fragment.isCode = block == "code" || block == "html"
            fragment.language = text.attribute(.previewCodeLanguage, at: 0, effectiveRange: nil) as? String
            fragment.quoteBars = text.attribute(.previewQuoteBars, at: 0, effectiveRange: nil) as? [CGFloat] ?? []
            fragment.tableColumns = text.attribute(.previewTableColumns, at: 0, effectiveRange: nil) as? [CGFloat]
            fragment.isTableHeader = text.attribute(.previewTableHeader, at: 0, effectiveRange: nil) as? Bool ?? false
            fragment.lead = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .headIndent ?? 0
        }
        return fragment
    }
}
