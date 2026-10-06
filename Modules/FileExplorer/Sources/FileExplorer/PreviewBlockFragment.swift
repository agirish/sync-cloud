import AppKit

/// **What the editable Preview draws behind its text** (TE67 §3.8): a bar for every level of quote,
/// and a shaded band behind a code block. Text attributes cannot draw either — a quote bar sits in
/// the indent, outside any glyph, and a code band spans the column, not the line's characters.
///
/// **TextKit 2's own hook, so the view stays on TextKit 2**: a layout-fragment subclass, chosen per
/// paragraph by ``PreviewFragmentDelegate`` from the attributes the projection put on it
/// (``NSAttributedString/Key/previewBlock``, ``NSAttributedString/Key/previewQuoteDepth``). Never
/// `layoutManager` — reading it drops the view to TextKit 1 for good.
///
/// And a table's grid (TE67.5): the header row tinted, a rule under every row, and a line at each
/// column's edge — where the projection's tab stops put them (``NSAttributedString/Key/previewTableColumns``).
final class PreviewBlockFragment: NSTextLayoutFragment {

    var isCode = false
    var quoteDepth = 0
    var scale: CGFloat = 1
    /// A table row's column edges from the text's left edge, the last being the table's right edge.
    var tableColumns: [CGFloat]?
    var isTableHeader = false
    /// Where the text starts, inside the fragment: a table's grid is measured from here.
    var lead: CGFloat = 0

    /// The quote bars sit left of the text, in the indent the projection left for them; a code band
    /// runs the column's width. Both are outside the text's own bounds.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        let left = -layoutFragmentFrame.minX
        if quoteDepth > 0 || isCode {
            bounds = bounds.union(CGRect(x: left, y: 0, width: 1, height: layoutFragmentFrame.height))
        }
        if isCode, let width = textLayoutManager?.textContainer?.size.width {
            bounds = bounds.union(CGRect(x: left, y: 0, width: width, height: layoutFragmentFrame.height))
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
            context.fill(CGRect(x: column, y: point.y, width: width, height: height))
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
        if quoteDepth > 0 {
            context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            for level in 0..<quoteDepth {
                context.fill(CGRect(x: column + (CGFloat(level) * 14 + 2) * scale, y: point.y,
                                    width: 3 * scale, height: height))
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
            fragment.isCode = text.attribute(.previewBlock, at: 0, effectiveRange: nil) as? String == "code"
            fragment.quoteDepth = text.attribute(.previewQuoteDepth, at: 0, effectiveRange: nil) as? Int ?? 0
            fragment.tableColumns = text.attribute(.previewTableColumns, at: 0, effectiveRange: nil) as? [CGFloat]
            fragment.isTableHeader = text.attribute(.previewTableHeader, at: 0, effectiveRange: nil) as? Bool ?? false
            fragment.lead = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .headIndent ?? 0
        }
        return fragment
    }
}
