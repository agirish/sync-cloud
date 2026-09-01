import SwiftUI
import Design

/// The rendered Markdown, in the app's own type ramp.
///
/// **SwiftUI text, not a web view**, which is the whole design of this surface: a `WKWebView` would
/// bring its own fonts, its own selection behaviour and its own scroll physics into a window that
/// has spent a lot of effort on all three — and would render the document at a size unrelated to
/// Settings ▸ Text size.
///
/// **Read-only except for one thing: a task item's checkbox.** Everything else here draws from the
/// document's text and cannot write back, so the buffer stays the single source of truth and
/// toggling modes cannot lose an edit. The checkbox is the exception because a checklist you can
/// read and not tick is a checklist you have to switch modes to use — and it is a safe one: the
/// click leaves through ``onToggleTask``, which rewrites exactly three characters of exactly one
/// line through ``MarkdownEdits/toggleTask(onLine:in:)``, and it is withheld entirely on a document
/// that cannot be saved.
struct MarkdownPreview: View {

    let blocks: [MarkdownBlock]
    let accent: Color
    /// Which source line the preview should bring into view, or `nil` to leave it where it is.
    ///
    /// Carries a token for the reason ``PlainTextEditor/scrollRequest`` does — and in split mode it
    /// changes constantly, once per line scrolled past on the other side.
    var scrollRequest: EditorScrollRequest?
    /// Ticks or unticks the task on a source line, or `nil` when this document must not be edited —
    /// which is what makes the checkbox a picture rather than a control on a read-only file.
    var onToggleTask: ((Int) -> Void)?

    /// Settings ▸ Text size. Read here rather than relied on ambiently because the `Text`
    /// concatenation in ``styled(_:)`` builds `Text` VALUES, which the `View`-level `.scaledFont`
    /// modifier cannot reach — those need the `Text` overload, and it takes the scale by hand.
    @Environment(\.appFontScale) private var fontScale

    var body: some View {
        ScrollViewReader { proxy in
            scroller
                // **`initial: false`.** A request that arrives with the view — opening a file from
                // an outline row — is answered by the `.task` below instead, once the blocks it
                // names actually exist; scrolling to an id in a `LazyVStack` that has not built a
                // single row yet is a no-op that looks like the feature being broken every other
                // time.
                .onChange(of: scrollRequest) { _, request in scroll(to: request, with: proxy) }
                .task(id: EditorPreviewScrollKey(request: scrollRequest, count: blocks.count)) {
                    // One turn, so the rows named below have been built.
                    await Task.yield()
                    scroll(to: scrollRequest, with: proxy)
                }
        }
    }

    /// Where a scroll lands, or nothing when the request names a document this preview has not
    /// rendered yet.
    private func scroll(to request: EditorScrollRequest?, with proxy: ScrollViewProxy) {
        guard let request,
              let index = MarkdownOutline.blockIndex(forLine: request.line, in: blocks) else {
            return
        }
        // **No animation.** In split this fires on every line scrolled past on the other side, and
        // an animated scroll chasing a scroll wheel lags behind it and then overshoots.
        proxy.scrollTo(index, anchor: .top)
    }

    /// What a preview scroll depends on: the request, and whether the blocks it names exist yet.
    private struct EditorPreviewScrollKey: Equatable {
        var request: EditorScrollRequest?
        var count: Int
    }

    private var scroller: some View {
        ScrollView {
            // **Lazy, because the read cap is 4 MiB.** A plain `VStack` materialises every block
            // on the main actor in one pass — moving the *parse* off it says nothing about the
            // render, and a large document is tens of thousands of blocks.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    view(for: block)
                        // The scroll target. The index rather than the source line, because a
                        // block does not have to have one — see ``MarkdownBlock/line``.
                        .id(index)
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
        let content = kindView(block.kind, line: block.line)
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

    /// The front matter, folded into one line that opens.
    ///
    /// **Folded rather than hidden.** It is part of the file and it is what a lot of tooling reads,
    /// so a preview that dropped it would be describing a document the file is not — but expanded
    /// by default it puts six lines of machine-readable keys above the first sentence, every time.
    @ViewBuilder
    private func frontMatterChip(_ matter: String) -> some View {
        let keys = MarkdownFrontMatter.keyCount(in: matter)
        DisclosureGroup {
            Text(matter)
                .scaledFont(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Front matter")
                    .scaledFont(.system(size: 10, weight: .semibold))
                // The count is what makes the closed chip worth reading: it says how much is folded
                // away, so nobody has to open it to find out whether it matters.
                Text(keys == 1 ? "1 key" : "\(keys) keys")
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.well).fill(.quaternary.opacity(0.3)))
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func kindView(_ kind: MarkdownBlock.Kind, line: Int?) -> some View {
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

        case .frontMatter(let matter):
            frontMatterChip(matter)

        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                markerView(marker, line: line)
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
    private func markerView(_ marker: MarkdownListMarker, line: Int?) -> some View {
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
            // **A button only when there is a line to rewrite and a document that accepts it.**
            // Both halves are real: a block the parser gave no range to cannot be found in the
            // buffer, and a read-only document must not gain a writable control in the one mode
            // that was never supposed to have any.
            if let line, let onToggleTask {
                Button { onToggleTask(line) } label: {
                    checkbox(done)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Done" : "Not done")
                .accessibilityAddTraits(done ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint("Ticks this item in the document")
                .help(done ? "Untick this item" : "Tick this item")
            } else {
                checkbox(done)
                    .accessibilityLabel(done ? "Done" : "Not done")
            }
        }
    }

    /// The box itself, drawn the same whether or not it can be clicked — a checklist that looked
    /// different on a read-only file would read as a rendering bug rather than as a permission.
    private func checkbox(_ done: Bool) -> some View {
        Image(systemName: done ? "checkmark.square.fill" : "square")
            .scaledFont(.system(size: 11))
            .foregroundStyle(done ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
            // A 4pt glyph is a hard target for a pointer; the shape gives it a real one without
            // changing what is drawn.
            .contentShape(Rectangle().inset(by: -3))
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
