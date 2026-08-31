import SwiftUI
import Design

/// The rendered Markdown, in the app's own type ramp.
///
/// **SwiftUI text, not a web view**, which is the whole design of this surface: a `WKWebView` would
/// bring its own fonts, its own selection behaviour and its own scroll physics into a window that
/// has spent a lot of effort on all three — and would render the document at a size unrelated to
/// Settings ▸ Text size.
///
/// Read-only by construction: this draws from the document's text and has no way to write back, so
/// the buffer stays the single source of truth and toggling modes cannot lose an edit.
struct MarkdownPreview: View {

    let blocks: [MarkdownBlock]
    let accent: Color

    /// Settings ▸ Text size. Read here rather than relied on ambiently because the `Text`
    /// concatenation in ``styled(_:)`` builds `Text` VALUES, which the `View`-level `.scaledFont`
    /// modifier cannot reach — those need the `Text` overload, and it takes the scale by hand.
    @Environment(\.appFontScale) private var fontScale

    var body: some View {
        ScrollView {
            // **Lazy, because the read cap is 4 MiB.** A plain `VStack` materialises every block
            // on the main actor in one pass — moving the *parse* off it says nothing about the
            // render, and a large document is tens of thousands of blocks.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            // The measure a reader's eye can hold. Wider than this and long paragraphs become hard
            // to track back to the start of the next line.
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    /// One block, wrapped in whatever the document nested it inside.
    ///
    /// **The quote bars and the indent are applied HERE, once, rather than inside each kind.**
    /// They used to be drawn only by the `.quote` case and only for paragraphs, so a bulleted list
    /// inside a `>` read as ordinary body text and a fenced block under a bullet sat flush left,
    /// detached from the item it belongs to.
    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        let content = kindView(block.kind)
        let indent = CGFloat(Self.drawnDepth(block.indent)) * Self.indentStep
        if block.quoteDepth > 0 {
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<Self.drawnDepth(block.quoteDepth), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(accent.opacity(0.45))
                        .frame(width: 2)
                }
                content
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, indent)
        } else {
            content
                .padding(.leading, indent)
        }
    }

    /// How far each level of list nesting indents.
    static let indentStep: CGFloat = 18

    /// The most nesting the preview will draw in, in levels.
    ///
    /// **A ceiling, because the document decides the depth and the column does not grow.** A
    /// forwarded mail thread pasted into a note is routinely eight to fifteen `>` levels, and each
    /// one costs a 2pt bar plus 10pt of spacing; a deep list costs `indentStep` each. At twelve
    /// levels the bars alone take 144pt out of a column guaranteed only 260, and past twenty the
    /// text is squeezed to one word a line. Clamping renders the deep levels at the same inset
    /// instead — the nesting stops being legible either way, and this way the words stay readable.
    static let maxNestingDrawn = 6

    /// The nesting depth actually drawn for `level`.
    static func drawnDepth(_ level: Int) -> Int { min(max(level, 0), maxNestingDrawn) }

    @ViewBuilder
    private func kindView(_ kind: MarkdownBlock.Kind) -> some View {
        switch kind {
        case .heading(let level, let text):
            styled(text)
                .scaledFont(.system(size: Self.headingSize(level), weight: .semibold))
                .padding(.top, level == 1 ? 4 : 14)
                .padding(.bottom, 4)
                .textSelection(.enabled)

        case .paragraph(let text):
            styled(text)
                .scaledFont(.system(size: 13))
                .lineSpacing(3)
                .padding(.vertical, 4)
                .textSelection(.enabled)

        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                markerView(marker)
                styled(text)
                    .scaledFont(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language)
                        .scaledFont(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                // Sideways inside its own container, for the reason the table below scrolls:
                // wrapping a code line mid-token is a different line of code.
                ScrollView(.horizontal) {
                    Text(code)
                        .scaledFont(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Radius.well).fill(.quaternary.opacity(0.35)))
            .padding(.vertical, 6)

        case .table(let header, let rows):
            tableView(header: header, rows: rows)

        case .thematicBreak:
            Divider().padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func markerView(_ marker: MarkdownListMarker) -> some View {
        switch marker {
        case .bullet:
            Circle()
                .fill(.tertiary)
                .frame(width: 4, height: 4)
                // Nudged onto the first line's baseline — a dot aligned to the top of the line box
                // sits noticeably above the text it belongs to.
                .padding(.top, 6)
        case .ordered(let number):
            Text("\(number).")
                .scaledFont(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .scaledFont(.system(size: 11))
                .foregroundStyle(done ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(done ? "Done" : "Not done")
        }
    }

    /// A table, scrolling sideways inside its own container rather than widening the document.
    ///
    /// **A `Grid`, because columns have to agree across rows.** Rows built as independent `HStack`s
    /// line up only while every cell is narrower than its `minWidth` — one long cell and the table
    /// below it renders as a staircase. `Grid` measures the columns once and shares the answer,
    /// which is the whole reason it exists.
    private func tableView(header: [MarkdownText], rows: [[MarkdownText]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !header.isEmpty {
                    tableRow(header, isHeader: true)
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, isHeader: false)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func tableRow(_ cells: [MarkdownText], isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                styled(cell)
                    .scaledFont(.system(size: 12, weight: isHeader ? .semibold : .regular))
                    .textSelection(.enabled)
                    .frame(minWidth: 60, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
    }

    /// One line of styled text: a single `AttributedString`, one run at a time.
    ///
    /// **One `Text`, not a stack of them.** Only a single `Text` wraps as one paragraph; an
    /// `HStack` of runs would lay each out as its own unbreakable unit and a bold word mid-sentence
    /// would stop the line wrapping where it should.
    ///
    /// **An `AttributedString` rather than `Text + Text`**, which is the same single-`Text` result
    /// by the route the platform still supports — the `+` operator is deprecated as of macOS 26 and
    /// was the branch's one deprecation warning. It also fixes a defect the concatenation carried:
    /// the styling arms below used to be exclusive, so `` **`code`** `` rendered monospaced and not
    /// bold. Emphasis is expressed as an *intent* rather than a resolved font, so it composes with
    /// whatever size the block around it sets — which is what let the two be exclusive in the first
    /// place, since a resolved font could only be one or the other.
    private func styled(_ line: MarkdownText) -> Text {
        var result = AttributedString()
        for run in line.runs { result.append(attributed(run)) }
        return Text(result)
    }

    private func attributed(_ run: MarkdownRun) -> AttributedString {
        var piece = AttributedString(run.text)
        if run.isCode {
            // Scaled like everything around it. A bare `.font(.system(size:))` here left inline
            // code at a fixed 12pt inside paragraphs that grow with Settings ▸ Text size, visibly
            // wrong at the sizes people choose deliberately.
            piece.font = ScaledFont.system(size: 12, design: .monospaced).resolved(scale: fontScale)
        }
        var intents: InlinePresentationIntent = []
        if run.isBold { intents.insert(.stronglyEmphasized) }
        if run.isItalic { intents.insert(.emphasized) }
        if run.isStruck { intents.insert(.strikethrough) }
        if !intents.isEmpty { piece.inlinePresentationIntent = intents }
        // A link is coloured rather than clickable: this preview renders a file on disk, and a
        // preview that opened a browser on a stray click would be doing something the editor does
        // not offer to undo.
        if run.link != nil { piece.foregroundColor = accent }
        return piece
    }

    /// The heading ramp. Six levels compressed into a range the app's own type can carry — h1 is
    /// deliberately not enormous, because a document opened in a rail-width column is not a poster.
    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 15.5
        case 4: return 14
        case 5: return 13
        default: return 12.5
        }
    }
}
