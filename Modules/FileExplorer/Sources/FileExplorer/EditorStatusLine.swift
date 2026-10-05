import SwiftUI
import Design

/// The strip under the document: what is in the buffer, and where the caret is in it.
///
/// **The header answers "which file and is it saved"; this answers "what is in it".** They are two
/// questions and they were one line, which is why the meta line grew to `Markdown · 4.2 KB · saved`
/// and stopped there — a fourth and fifth segment would have pushed the file name out of a header
/// whose whole job is to name the file.
///
/// **It sheds segments as the column narrows**, the same bargain ``EditorModeBar`` strikes and in
/// the same shape — `ViewThatFits` over hand-named rungs, with a `forcedRung` so a test can ask for
/// one rather than trying to provoke it. The order it drops things in is the order they are worth:
/// the character count goes first (the word count says the same thing less precisely and is what
/// people actually read), then the counts entirely, leaving the caret — which is the only segment
/// that changes as you work and the only one you cannot get anywhere else.
struct EditorStatusLine: View, Equatable {

    let facts: EditorDocumentFacts
    let caret: EditorCaret
    /// The file's size on disk, already formatted, or `nil` when nothing has been read.
    ///
    /// **Moved down from the header**, where it was the one measurement living apart from the
    /// others. It belongs with the encoding and the line endings: all three describe the file as it
    /// sits on disk rather than the buffer being typed into, which is why they share this end of
    /// the row.
    var fileSize: String?
    /// Forces a rung, for the tests that measure each one. `nil` picks by width.
    var forcedRung: Rung?
    /// **The heading the caret is in, leading the line, as a menu of every heading (TE57)** — or
    /// `nil` when there is none to name: a plain-text file, or Markdown with no headings.
    var headings: EditorStatusHeadings?

    @Environment(\.appFontScale) private var scale

    /// The three rungs, named so a test can ask for one.
    enum Rung: CaseIterable { case full, counts, caret }

    /// How much of the heading a rung keeps: its whole name, its name truncated no further than
    /// ``headingFloor(scale:)``, or as little as the glyph — the last resort, so a long line number
    /// at the largest text size never pushes the line past its column.
    enum HeadingFit: CaseIterable { case whole, floor, glyph }

    /// **Compared on everything it DRAWS** — the heading's closures left out, as the format bar's
    /// is, so a keystroke that changes none of it does not rebuild and re-measure five rungs. The
    /// closures are written at the one call site over the host's `@State`, which does not move.
    nonisolated static func == (a: EditorStatusLine, b: EditorStatusLine) -> Bool {
        a.facts == b.facts && a.caret == b.caret && a.fileSize == b.fileSize
            && a.forcedRung == b.forcedRung && a.headings == b.headings
    }

    /// **The heading joins the ladder by giving way FIRST.** Each rung of counts comes twice — with
    /// the heading's whole name, then with it truncated to ``headingFloor(scale:)`` — so a narrowing
    /// line shortens the name before the character count goes, and the count before both counts go.
    /// The whole-name rung comes first so a name SHORTER than the floor costs only its own width.
    /// The last rung lets the name go entirely, so nothing can push the caret past the column's
    /// edge (`theHeadingFitsBesideTheNarrowestRung`).
    ///
    /// **One caret rung, not three.** The strip is fixed at its own width, so beside the caret alone
    /// the name is drawn at whatever is left, up to its whole width, whichever fit is asked for — a
    /// whole-name and a floor rung there would draw exactly what this one draws.
    var body: some View {
        Group {
            if let headings {
                if let forcedRung {
                    rung(forcedRung, headings, fit: .floor)
                } else {
                    ViewThatFits(in: .horizontal) {
                        rung(.full, headings, fit: .whole)
                        rung(.full, headings, fit: .floor)
                        rung(.counts, headings, fit: .whole)
                        rung(.counts, headings, fit: .floor)
                        rung(.caret, headings, fit: .glyph)
                    }
                }
            } else if let forcedRung {
                counted(forcedRung)
            } else {
                ViewThatFits(in: .horizontal) {
                    counted(.full)
                    counted(.counts)
                    counted(.caret)
                }
            }
        }
        .scaledFont(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The counts, as one element for VoiceOver — the heading beside them is a control of its own.
    private func counted(_ rung: Rung) -> some View {
        strip(rung)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(facts: facts, caret: caret, fileSize: fileSize))
    }

    private func rung(_ rung: Rung, _ headings: EditorStatusHeadings, fit: HeadingFit) -> some View {
        HStack(spacing: Self.spacing) {
            switch fit {
            case .whole:
                EditorHeadingMenu(headings: headings).fixedSize()
            case .floor:
                EditorHeadingMenu(headings: headings)
                    .frame(minWidth: Self.headingFloor(scale: scale), idealWidth: Self.headingFloor(scale: scale),
                           alignment: .leading)
                    .layoutPriority(-1)
            case .glyph:
                EditorHeadingMenu(headings: headings)
                    .frame(minWidth: 0, idealWidth: 0, alignment: .leading)
                    .layoutPriority(-1)
            }
            counted(rung)
        }
    }

    /// The gap between segments — and between the heading and the first of them.
    static let spacing: CGFloat = 14

    /// **The narrowest the heading's name truncates to** before the counts start going: room for
    /// the glyph, "in", the first letters of a heading and the chevron. Scaled with the text, as the
    /// segments beside it are.
    ///
    /// Six type-widths: at the largest text size the caret rung is 163pt in a 260pt column
    /// (`EditorLayoutMetrics.minDocumentWidth`), which leaves 83pt beside it — measured 2026-10-04.
    /// A longer caret than that ("Line 1408, Col 1180") takes the last rung, ``HeadingFit/glyph``.
    static func headingFloor(scale: CGFloat) -> CGFloat {
        FontSize.scaledPointSize(10, scale: scale) * 6
    }

    private func strip(_ rung: Rung) -> some View {
        HStack(spacing: Self.spacing) {
            if rung != .caret {
                Text(facts.wordsCaption)
                if rung == .full { Text(facts.charactersCaption) }
            }
            Text(Self.caretCaption(caret))
            Spacer(minLength: 8)
            // The file's own facts, right-aligned and last: they are true of the file rather than
            // of what you are doing in it, and they change only when a different file is opened.
            if rung != .caret {
                if let fileSize { Text(fileSize) }
                if let encoding = facts.encoding { Text(encoding) }
                if let ending = facts.lineEnding { Text(ending.rawValue) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// `Line 48, Col 12` — spelled out rather than abbreviated to `Ln`, because the strip has room
    /// for the words at every rung that draws them and the abbreviation saves four points.
    static func caretCaption(_ caret: EditorCaret) -> String {
        "Line \(caret.line), Col \(caret.column)"
    }

    /// One sentence for VoiceOver, because five separate labels in a row is five stops on the way
    /// to the text — and this strip is beside the thing a person came here to read.
    static func accessibilityLabel(facts: EditorDocumentFacts, caret: EditorCaret,
                                   fileSize: String? = nil) -> String {
        var parts = [facts.wordsCaption, facts.charactersCaption, caretCaption(caret)]
        if let fileSize { parts.append(fileSize) }
        if let encoding = facts.encoding { parts.append(encoding) }
        if let ending = facts.lineEnding { parts.append("\(ending.rawValue) line endings") }
        return parts.joined(separator: ", ")
    }
}

/// What the status line's heading item knows: the outline, which heading holds the caret, and what
/// choosing does (TE57). **The rail's Outline tab, one click from anywhere** — same outline
/// (``MarkdownOutline``), same "which heading am I in" rule, same scroll request — for the two
/// layouts that hide the rail: the file pane open, and Expand.
struct EditorStatusHeadings: Equatable {
    var outline: [MarkdownOutlineEntry]
    /// The index in ``outline`` of the heading holding the caret — `nil` above the first one,
    /// which is in no section (``MarkdownOutline/currentEntry(forLine:in:)``).
    var current: Int?
    /// Whether the menu ends with "Show the Outline in the rail" — see
    /// ``offersRailOutline(showsRail:railTab:)``.
    var offersRailOutline: Bool
    var accent: Color
    var onSelect: (MarkdownOutlineEntry) -> Void
    var onShowRailOutline: () -> Void

    /// Compared on what the item draws; the two acts are left out — see ``EditorStatusLine/==``.
    nonisolated static func == (a: EditorStatusHeadings, b: EditorStatusHeadings) -> Bool {
        a.outline == b.outline && a.current == b.current && a.offersRailOutline == b.offersRailOutline
            && a.accent == b.accent
    }

    /// **Only while the rail is drawn, and not when it is already showing its Outline** — a menu
    /// item that switches the rail to the tab it is on would do nothing.
    static func offersRailOutline(showsRail: Bool, railTab: EditorRailTab) -> Bool {
        showsRail && railTab != .outline
    }

    /// The item for this document, or `nil` when there is nothing to name — a plain-text file, or a
    /// Markdown one with no headings yet.
    static func make(outline: [MarkdownOutlineEntry], caretLine: Int, isMarkdown: Bool,
                     offersRailOutline: Bool, accent: Color,
                     onSelect: @escaping (MarkdownOutlineEntry) -> Void,
                     onShowRailOutline: @escaping () -> Void) -> EditorStatusHeadings? {
        guard isMarkdown, !outline.isEmpty else { return nil }
        return EditorStatusHeadings(outline: outline,
                                    current: MarkdownOutline.currentEntry(forLine: caretLine, in: outline),
                                    offersRailOutline: offersRailOutline, accent: accent,
                                    onSelect: onSelect, onShowRailOutline: onShowRailOutline)
    }

    /// The heading holding the caret, when there is one.
    var currentEntry: MarkdownOutlineEntry? {
        current.flatMap { outline.indices.contains($0) ? outline[$0] : nil }
    }

    /// What the line says: "in Method", or "Headings" above the first one.
    var title: String { currentEntry.map { "in \(Self.name($0))" } ?? "Headings" }

    /// What VoiceOver says, from the same entry the line names — "Section", because "Heading" is
    /// what VoiceOver calls a heading itself, and this is a menu.
    var accessibilityName: String { currentEntry.map { "Section: \(Self.name($0))" } ?? "Headings" }

    /// The tooltip: about the heading the caret is in when there is one, about the menu when not.
    var help: String {
        currentEntry == nil ? "The document's headings — choose one to go to it"
            : "The heading the caret is in — choose another to go to it"
    }

    /// A heading's name — the rail's words for one written with none, and on ONE line: a setext
    /// heading's hard break is a line break in its text, and a menu item or the status line has one.
    static func name(_ entry: MarkdownOutlineEntry) -> String {
        let title = entry.title.components(separatedBy: .newlines).joined(separator: " ")
        return title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled heading" : title
    }

    /// An item's title in the menu: indented one em per level below the document's shallowest
    /// heading, as the rail indents its rows — so under a `#` title the `##` sections step in.
    static func menuTitle(_ entry: MarkdownOutlineEntry) -> String {
        String(repeating: "\u{2003}", count: entry.depth) + name(entry)
    }

    static let railOutlineTitle = "Show the Outline in the rail"

    /// **A menu item's tick, and what choosing it does** — on for the heading the caret is in, and
    /// set either way it goes to that heading: a click on the ticked one goes to it too.
    func choice(_ index: Int) -> Binding<Bool> {
        Binding(get: { index == current },
                set: { _ in if outline.indices.contains(index) { onSelect(outline[index]) } })
    }
}

/// **"in Method ▾"** — the heading the caret is in, and a menu of the document's headings with
/// that one ticked. Choosing one scrolls there, exactly as a click on the rail's outline does.
struct EditorHeadingMenu: View {
    let headings: EditorStatusHeadings

    var body: some View {
        Menu {
            ForEach(Array(headings.outline.enumerated()), id: \.element.id) { index, entry in
                Toggle(EditorStatusHeadings.menuTitle(entry), isOn: headings.choice(index))
            }
            if headings.offersRailOutline {
                Divider()
                Button(EditorStatusHeadings.railOutlineTitle) { headings.onShowRailOutline() }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: EditorRailTab.outline.symbol)
                    .scaledFont(.system(size: 8, weight: .semibold))
                // The one segment that truncates — see `EditorStatusLine.body`.
                Text(headings.title)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.hoverAffordance(.segment, tint: headings.accent))
        .menuIndicator(.hidden)
        // The wash's own padding taken back outside it, as the header's folded crumb does, so the
        // glyph starts on the line's 14pt edge and the counts keep their 14pt gap.
        .padding(.horizontal, -4)
        .help(headings.help)
        .accessibilityLabel(headings.accessibilityName)
        .accessibilityHint("Shows the document's headings")
    }
}
