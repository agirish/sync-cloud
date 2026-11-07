import SwiftUI
import Design

/// One block of a rendered Markdown document, the unit both the preview and the printed page are
/// built from. One body of code for both, so the File menu's promise that the PDF is the preview
/// stays true; a second copy for paper would drift. What differs lives in ``Medium``: a page
/// can't scroll, and can't wait for an image to load.
struct MarkdownBlockView: View {

    let block: MarkdownBlock
    let accent: Color
    /// The folder the open document lives in, which is what a relative image path is relative to.
    var documentFolder: String?
    /// Ticks or unticks the task on a source line, or `nil` where the document must not be edited.
    var onToggleTask: ((Int) -> Void)?
    /// Sends the reader to a heading in this same document, for a `#fragment` link.
    var onFollowAnchor: ((String) -> Void)?
    /// Screen or paper — see ``Medium``.
    var medium: Medium = .screen
    /// Images already resolved and decoded, keyed by the raw `![alt](source)` text they came from.
    /// Empty on screen, where each image loads itself in a task; filled on paper, where there is
    /// no later frame for a loaded image to arrive in. See ``MarkdownImageView/Preloaded``.
    var preloadedImages: [String: MarkdownImageView.Preloaded] = [:]

    /// Settings ▸ Text size, read here because ``styled(_:)`` builds an `AttributedString`, whose
    /// inline-code font the `View`-level `.scaledFont` modifier can't reach.
    @Environment(\.appFontScale) private var fontScale
    /// Which shade of the hue a link is drawn in — see ``linkInk(_:accent:)``.
    @Environment(\.colorScheme) private var colorScheme

    /// What the block is drawn onto, and so the two things it may not assume.
    ///
    /// A page can't scroll: a `ScrollView(.horizontal)` on paper draws its first page-width and
    /// silently loses the rest. So on paper a code block wraps (a clipped line looks like a short
    /// one) and a table is drawn at natural width for ``DocumentPDF`` to scale to the page.
    ///
    /// A page can't wait: `MarkdownImageView` loads in a `.task`, which never runs in an offscreen
    /// render, so on paper the image arrives decoded through ``preloadedImages``.
    enum Medium: Equatable { case screen, page }

    var body: some View {
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

    /// The most nesting the preview draws, in levels. The document decides the depth but the column
    /// doesn't grow: a pasted mail thread can be fifteen `>` levels at 12pt each, in a column
    /// guaranteed only 260pt. Deeper levels share this inset, so the words stay readable.
    static let maxNestingDrawn = 6

    /// The nesting depth actually drawn for `level`.
    static func drawnDepth(_ level: Int) -> Int { min(max(level, 0), maxNestingDrawn) }

    /// The front matter, folded into one line that opens. Folded, not hidden: it is part of the
    /// file and tooling reads it, but expanded it puts lines of keys above the first sentence.
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
                // The count says how much is folded away, so nobody has to open it to find out.
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

        case .image(let source, let alt):
            // The raw source, resolved inside ``MarkdownImageView``, not here: resolving costs four
            // filesystem calls, and a `body` runs on every keystroke in preview or split. On paper
            // the answer is already in hand (``preloadedImages``).
            MarkdownImageView(source: source, folder: documentFolder, alt: alt, accent: accent,
                              preloaded: preloadedImages[source])

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
                // Scrolls sideways on screen: wrapping a code line mid-token makes a different line
                // of code. On paper it wraps, since a page's `ScrollView` would clip it, and a
                // clipped line looks like a short one (see ``Medium``).
                if medium == .page {
                    Text(code)
                        .scaledFont(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal) {
                        Text(code)
                            .scaledFont(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                // Nudged onto the first line's baseline; at the top of the line box it sits high.
                .padding(.top, 6)
        case .ordered(let number):
            Text("\(number).")
                .scaledFont(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .task(let done):
            // A button only with a line to rewrite and a document that accepts edits: a block
            // with no line can't be found in the buffer, and a read-only document must not gain
            // a writable control.
            if let line, let onToggleTask {
                Button { onToggleTask(line) } label: {
                    checkbox(done)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Done" : "Not done")
                .accessibilityAddTraits(done ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(done ? "Unticks this item in the document" : "Ticks this item in the document")
                .help(done ? "Untick this item" : "Tick this item")
            } else {
                checkbox(done)
                    .accessibilityLabel(done ? "Done" : "Not done")
            }
        }
    }

    /// The box, drawn the same whether or not it can be clicked: a different look on a read-only
    /// file would read as a rendering bug, not a permission.
    private func checkbox(_ done: Bool) -> some View {
        Image(systemName: done ? "checkmark.square.fill" : "square")
            .scaledFont(.system(size: 11))
            .foregroundStyle(done ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
            // A bigger hit target than the small glyph, without changing what is drawn.
            .contentShape(Rectangle().inset(by: -3))
    }

    /// A table, scrolling sideways in its own container rather than widening the document. A
    /// `Grid`, so columns agree across rows: independent `HStack` rows turn into a staircase after
    /// one long cell. On paper there is no scroller, so the grid is drawn at natural width and
    /// ``DocumentPDF`` scales it to the page, keeping every column on the paper.
    @ViewBuilder
    private func tableView(header: [MarkdownText], rows: [[MarkdownText]]) -> some View {
        let grid = Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            if !header.isEmpty {
                tableRow(header, isHeader: true)
                Divider()
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                tableRow(row, isHeader: false)
            }
        }
        if medium == .page {
            grid.padding(.vertical, 8)
        } else {
            ScrollView(.horizontal) { grid }
                .padding(.vertical, 8)
        }
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
    /// One `Text`, because only a single `Text` wraps as one paragraph; an `HStack` of runs would
    /// make each run an unbreakable unit. An `AttributedString`, not `Text + Text`, which is
    /// deprecated as of macOS 26. Emphasis is an intent, not a resolved font, so it composes with
    /// code and with the block's size: `` **`code`** `` is bold and monospaced.
    private func styled(_ line: MarkdownText) -> Text {
        var result = AttributedString()
        for run in line.runs {
            result.append(Self.attributed(run, accent: accent, scheme: colorScheme, fontScale: fontScale))
        }
        return Text(result)
    }

    /// A link is the window's hue in a shade that reads as text: the raw accent falls well short of
    /// the 4.5:1 body text needs. `ChromeInk.bodyText` deepens it in light and lifts it in dark,
    /// keeping the hue. `PreviewEditorView` uses the same rule, so toggling Edit in Preview leaves
    /// a link's colour alone.
    static func linkInk(_ scheme: ColorScheme, accent: Color) -> Color {
        ChromeInk.bodyText(scheme, accent)
    }

    static func attributed(_ run: MarkdownRun, accent: Color, scheme: ColorScheme,
                           fontScale: CGFloat) -> AttributedString {
        var piece = AttributedString(run.text)
        if run.isCode {
            // Scaled like everything around it; a bare `.font(.system(size:))` would stay at 12pt
            // inside paragraphs that grow with Settings ▸ Text size.
            piece.font = ScaledFont.system(size: 12, design: .monospaced).resolved(scale: fontScale)
        }
        var intents: InlinePresentationIntent = []
        if run.isBold { intents.insert(.stronglyEmphasized) }
        if run.isItalic { intents.insert(.emphasized) }
        if run.isStruck { intents.insert(.strikethrough) }
        if !intents.isEmpty { piece.inlinePresentationIntent = intents }
        // Clickable, and the app still fetches nothing: a click hands the URL to the system.
        // Rendering a remote thing's contents is the line not crossed (see `MarkdownImageView`).
        // A `#fragment` is intercepted rather than opened: see `openLink`.
        if let link = run.link {
            piece.foregroundColor = linkInk(scheme, accent: accent)
            if let url = URL(string: link) { piece.link = url }
        }
        return piece
    }

    /// The heading ramp: six levels in a range the app's type can carry. h1 is not enormous,
    /// because a document in a rail-width column is not a poster.
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
