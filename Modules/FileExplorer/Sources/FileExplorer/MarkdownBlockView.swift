import SwiftUI
import Design

/// One block of a rendered Markdown document — the unit the preview and the printed page are both
/// built out of.
///
/// **It exists so that "print what the preview shows" is one body of code rather than two.** These
/// arms were `MarkdownPreview`'s own private methods until printing arrived (roadmap RD9); a
/// second copy for paper would have started identical and drifted on the first heading-size change,
/// and the claim the File menu makes — that the PDF is the preview — would have quietly stopped
/// being true with nothing failing.
///
/// What differs between the two mediums is small, named, and lives in ``Medium``: a page cannot
/// scroll, and a page cannot wait for an image to load.
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

    /// Settings ▸ Text size. Read here rather than relied on ambiently because the `Text`
    /// concatenation in ``styled(_:)`` builds `Text` VALUES, which the `View`-level `.scaledFont`
    /// modifier cannot reach — those need the `Text` overload, and it takes the scale by hand.
    @Environment(\.appFontScale) private var fontScale

    /// What the block is being drawn onto, and therefore the two things it may not assume.
    ///
    /// **A page cannot scroll.** Wide code and wide tables sit inside `ScrollView(.horizontal)` on
    /// screen, which on paper is a container that draws its first page-width of content and silently
    /// loses the rest. On paper a code block wraps instead — a wrapped line is visibly a wrapped
    /// line, where a clipped one is indistinguishable from a short one — and a table is drawn at its
    /// natural width for ``DocumentPDF`` to scale down to the page.
    ///
    /// **A page cannot wait.** `MarkdownImageView` loads in a `.task`, which never runs during an
    /// offscreen render; on paper the image arrives already decoded through ``preloadedImages``.
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

        case .image(let source, let alt):
            // **The raw source, resolved inside the image view rather than here.** Resolving is
            // four filesystem calls — an existence check, a cloud-placeholder check, a symlink
            // resolve and a stat — and this is a `body`, so it ran once per visible image on every
            // render pass, which in preview or split is every keystroke. It happens once per image
            // in a task now. See ``MarkdownImageView``.
            // On paper the answer is already in hand — see ``preloadedImages`` and ``Medium``.
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
                // Sideways inside its own container, for the reason the table below scrolls:
                // wrapping a code line mid-token is a different line of code.
                //
                // **On paper it wraps instead**, because there is nothing to scroll and the
                // alternative is worse than a wrap: a `ScrollView` on a page draws its first
                // page-width and drops the rest, and a clipped code line is indistinguishable
                // from a short one. A wrapped one is visibly wrapped.
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
    ///
    /// **On paper there is no scroller**, so the grid is drawn at its natural width and
    /// ``DocumentPDF`` scales the block down to the page — which keeps every column rather than
    /// dropping the ones past the paper's edge. A table is the one block where wrapping is not an
    /// option: a cell that wraps is still in its column, but a column that falls off the page is
    /// gone.
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
        // **Clickable now, and the app still fetches nothing.** The comment here used to argue that
        // a preview which opened a browser would be "doing something the editor does not"; what it
        // actually does is hand a URL to the system, which is what every Markdown preview on the
        // platform does and what a reader clicking a link is asking for. Rendering the *contents*
        // of a remote thing is the line, and it is still not crossed — see `MarkdownImageView`.
        //
        // A `#fragment` is intercepted rather than opened: see `openLink`.
        if let link = run.link {
            piece.foregroundColor = accent
            if let url = URL(string: link) { piece.link = url }
        }
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
