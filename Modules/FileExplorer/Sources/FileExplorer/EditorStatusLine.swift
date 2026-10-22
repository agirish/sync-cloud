import SwiftUI
import AppKit
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
    /// **An edit Preview could not make (TE67 §1.2)**, said in the line's leading slot for a few
    /// seconds instead of the counts — the "only minor edits work here" message, at the moment it
    /// matters rather than as a standing warning. The host clears it after ``EditorStatusHint/duration``.
    var hint: EditorStatusHint?
    /// **The selection's counts, while text is selected (TE60)** — "12 of 78 words · 64 characters
    /// selected" in the counts' place — or `nil` for a bare caret, when the line reads as it always did.
    var selection: EditorSelectionFacts?
    /// **"Line, Col" as a door to Go to Line (TE61)**, or `nil` where there is no going (Preview).
    var goToLine: EditorStatusGoToLine?
    /// Drops the selection's line count from a forced rung — the ladder's first concession, for the
    /// tests that measure it. Ignored when the rung is chosen by width.
    var forcedDropsSelectionLines = false
    /// **What a change from elsewhere just did (TE59)** — "Reloaded — changed elsewhere" — in the
    /// same leading slot for a few seconds. The hint outranks it: that one has a control in it.
    var notice: String?

    @Environment(\.appFontScale) private var scale
    /// The drawn caret button's bounds in the line, for Go to Line's arrow (TE61).
    @State private var caretBounds: CGRect = .zero

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
            && a.forcedRung == b.forcedRung && a.headings == b.headings && a.hint == b.hint
            && a.selection == b.selection && a.goToLine == b.goToLine
            && a.forcedDropsSelectionLines == b.forcedDropsSelectionLines
            && a.notice == b.notice
    }

    /// **The notice gives way while Go to Line's field is up.** Both want the leading slot, and the
    /// field is what the person has just asked for: under the notice there was no caret for it to
    /// hang from, so ⌃⌘L showed nothing, and a notice arriving mid-typing took the slot from under
    /// the field. A notice is news that times out on its own, so it waits — and is said again if
    /// its seconds are not up when the field closes.
    private var shownNotice: String? { goToLine?.isPresented.wrappedValue == true ? nil : notice }

    /// **Whether the selection's line count is drawn at all** — only for a selection across more than
    /// one line, where it says something the other two counts do not.
    private var hasSelectionLines: Bool { (selection?.lines ?? 0) > 1 }

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
    ///
    /// **A selection's line count goes before anything else (TE60)** — "3 lines" is the least of what
    /// the line says, so the two rungs carrying it lead the ladder and the heading still shortens
    /// before it goes. Without a multi-line selection those two rungs are not built at all: they
    /// would draw exactly what the rungs after them draw.
    var body: some View {
        Group {
            if let hint {
                hinted(hint)
            } else if let notice = shownNotice {
                Text(notice)
                    .truncationMode(.tail)
                    .accessibilityLabel(notice)
            } else if let headings {
                if let forcedRung {
                    rung(forcedRung, headings, fit: .floor, lines: !forcedDropsSelectionLines)
                } else {
                    ViewThatFits(in: .horizontal) {
                        if hasSelectionLines {
                            rung(.full, headings, fit: .whole, lines: true)
                            rung(.full, headings, fit: .floor, lines: true)
                        }
                        rung(.full, headings, fit: .whole)
                        rung(.full, headings, fit: .floor)
                        rung(.counts, headings, fit: .whole)
                        rung(.counts, headings, fit: .floor)
                        rung(.caret, headings, fit: .glyph)
                    }
                }
            } else if let forcedRung {
                counted(forcedRung, lines: !forcedDropsSelectionLines)
            } else {
                ViewThatFits(in: .horizontal) {
                    if hasSelectionLines { counted(.full, lines: true) }
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
        .coordinateSpace(.named(Self.lineSpace))
        // **Hung on the line once, never on a rung.** Every rung of both ladders draws its own
        // caret button, and a change of rung — a multi-line selection's count arriving, the column
        // narrowing, ⌘+ — is a different button: a popover hung on one went with it, and the field
        // shut under the person typing in it. Here it outlives every rung, and its arrow is aimed
        // at whichever caret is drawn by the bounds that caret reports (`caretBounds`).
        .popover(isPresented: goToLine?.isPresented ?? .constant(false),
                 attachmentAnchor: .rect(.rect(caretBounds)), arrowEdge: .top) {
            if let goToLine {
                EditorGoToLineField(lineCount: goToLine.lineCount, onGo: goToLine.onGo,
                                    onCancel: { goToLine.isPresented.wrappedValue = false })
            }
        }
    }

    /// The line's own coordinate space, which the caret reports its bounds in.
    private static let lineSpace = "EditorStatusLine"

    /// **Shed as the counts are**, so a narrow column at a large text size keeps the way to Source:
    /// the sentence, then its short form, then the link alone (`theHintFitsTheNarrowestColumnAtEveryTextSize`).
    @ViewBuilder
    private func hinted(_ hint: EditorStatusHint) -> some View {
        if let rung = hint.forcedRung {
            hintRow(rung, hint)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(EditorStatusHint.Rung.allCases, id: \.self) { hintRow($0, hint) }
            }
        }
    }

    private func hintRow(_ rung: EditorStatusHint.Rung, _ hint: EditorStatusHint) -> some View {
        HStack(spacing: 6) {
            if let sentence = hint.sentence(rung) { Text(sentence) }
            Button { hint.onShowInSource() } label: { Text(EditorStatusHint.showInSource) }
                .buttonStyle(.link)
                .accessibilityHint(EditorStatusHint.needsSource)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The counts, as one element for VoiceOver — the heading beside them is a control of its own.
    private func counted(_ rung: Rung, lines: Bool = false) -> some View {
        strip(rung, lines: lines)
            // Combined, the caret's button included: the one element then takes the button's
            // action, so VoiceOver's press is Go to Line wherever the mouse's click is (TE61).
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(facts: facts, caret: caret, fileSize: fileSize,
                                                        selection: selection))
            .accessibilityHint(goToLine == nil ? "" : "Goes to a line")
    }

    private func rung(_ rung: Rung, _ headings: EditorStatusHeadings, fit: HeadingFit,
                      lines: Bool = false) -> some View {
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
            counted(rung, lines: lines)
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

    private func strip(_ rung: Rung, lines: Bool) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(Self.countCaptions(facts: facts, selection: selection, rung: rung, lines: lines),
                    id: \.self) { Text($0) }
            caretSegment
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

    /// **What a rung says before the caret** — the document's counts, or while text is selected the
    /// selection's (TE60), each segment its own string so the strip spaces them as it always has.
    ///
    /// - `full`: `12 of 78 words` · `64 characters selected`, or with `lines` (a selection across
    ///   lines, and room for it) `12 of 78 words` · `64 characters` · `3 lines selected`.
    /// - `counts`: `12 of 78 words selected` — the word count says it on its own.
    /// - `caret`: nothing, selection or not.
    ///
    /// "selected" ends the run rather than starting it, so the numbers line up where the document's
    /// stood and the word that changed is the last one read.
    static func countCaptions(facts: EditorDocumentFacts, selection: EditorSelectionFacts?,
                              rung: Rung, lines: Bool) -> [String] {
        guard rung != .caret else { return [] }
        guard let selection else {
            return rung == .full ? [facts.wordsCaption, facts.charactersCaption] : [facts.wordsCaption]
        }
        let words = "\(selection.words.formatted(.number)) of \(EditorDocumentFacts.count(facts.words, "word"))"
        guard rung == .full else { return [words + " selected"] }
        let characters = EditorDocumentFacts.count(selection.characters, "character")
        guard lines, selection.lines > 1 else { return [words, characters + " selected"] }
        return [words, characters, EditorDocumentFacts.count(selection.lines, "line") + " selected"]
    }

    /// **"Line 48, Col 12" — a button where Go to Line is offered (TE61)**, drawn exactly as wide as
    /// the words: the hover wash's padding is taken back outside it, as the heading menu's is, so no
    /// rung measures differently for being clickable. Secondary like the counts — a wash on hover, not
    /// a colour at rest, says it can be pressed.
    @ViewBuilder
    private var caretSegment: some View {
        if let goToLine {
            Button { goToLine.isPresented.wrappedValue = true } label: {
                Text(Self.caretCaption(caret))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: goToLine.accent))
            // ⌥ shows Go to Line's ⌃⌘L (TE194), compact to the line's small type.
            .shortcutKeycap(AppChord.goToLine.display, compact: true)
            // Where the field's arrow points — the field itself hangs on the whole line (`body`).
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.lineSpace)) }) {
                caretBounds = $0
            }
            .padding(.horizontal, -4)
            .help(EditorStatusGoToLine.help)
        } else {
            Text(Self.caretCaption(caret))
        }
    }

    /// `Line 48, Col 12` — spelled out rather than abbreviated to `Ln`, because the strip has room
    /// for the words at every rung that draws them and the abbreviation saves four points.
    static func caretCaption(_ caret: EditorCaret) -> String {
        "Line \(caret.line), Col \(caret.column)"
    }

    /// One sentence for VoiceOver, because five separate labels in a row is five stops on the way
    /// to the text — and this strip is beside the thing a person came here to read. A selection is
    /// said whole, with its line count, whatever the rung on screen had room for.
    static func accessibilityLabel(facts: EditorDocumentFacts, caret: EditorCaret,
                                   fileSize: String? = nil, selection: EditorSelectionFacts? = nil) -> String {
        var parts = countCaptions(facts: facts, selection: selection, rung: .full, lines: true)
        parts.append(caretCaption(caret))
        if let fileSize { parts.append(fileSize) }
        if let encoding = facts.encoding { parts.append(encoding) }
        if let ending = facts.lineEnding { parts.append("\(ending.rawValue) line endings") }
        return parts.joined(separator: ", ")
    }
}

/// What the status line says when Preview refuses an edit: one sentence and the way to Source.
struct EditorStatusHint: Equatable {
    static let needsSource = "That change needs Source."
    static let needsSourceShort = "Needs Source."
    static let showInSource = "Show in Source"
    /// How long the host keeps it up, in seconds (§1.2).
    static let duration: Double = 4

    /// The hint's rungs, widest first.
    enum Rung: CaseIterable {
        case sentence, short, link
    }

    /// What the rung says before the link — `nil` for the link alone. **A Replace All that could
    /// not make every match says how many** (review V9, 2026-10-09): it changes none of them, and
    /// "That change needs Source." over a whole document's worth of matches does not say which
    /// change, or that the rest were not made either.
    func sentence(_ rung: Rung) -> String? {
        switch (rung, reason) {
        case (.link, _): return nil
        case (.sentence, .replaceAll(let failed, let of)?):
            return "\(failed) of \(of) matches need Source — none were replaced."
        case (.short, .replaceAll(let failed, let of)?): return "\(failed) of \(of) need Source."
        case (.sentence, _): return EditorStatusHint.needsSource
        case (.short, _): return EditorStatusHint.needsSourceShort
        }
    }

    /// Bumped per refusal, so a second refusal while the first is up restarts the host's timer.
    var token: Int
    /// Switches to Source with the caret at the refused edit.
    var onShowInSource: () -> Void
    /// Forces a rung, for the tests that measure each one. `nil` picks by width.
    var forcedRung: Rung? = nil
    /// Why the edit was refused, for the words — ``sentence(_:)``.
    var reason: PreviewRefusal? = nil

    nonisolated static func == (a: EditorStatusHint, b: EditorStatusHint) -> Bool { a.token == b.token }
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
    /// Whether the menu ends with "Show Outline in File List" — see
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

    /// **Everywhere but where the list already shows its Outline** (TE180) — a menu item that
    /// switches the list to the tab it is on would do nothing. It used to be offered only while
    /// the list was drawn, so it went away in the three layouts where the list is not — folded
    /// (the default), the file pane open, and Expand — which are the ones it is the way back from.
    /// There it opens the list on its Outline, as the strip's Outline button does.
    static func offersRailOutline(showsRail: Bool, railTab: EditorRailTab) -> Bool {
        !(showsRail && railTab == .outline)
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
        currentEntry == nil ? "The document’s headings — choose one to go to it"
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

    static let railOutlineTitle = "Show Outline in File List"

    /// **A menu item's tick, and what choosing it does** — on for the heading the caret is in, and
    /// set either way it goes to that heading: a click on the ticked one goes to it too.
    func choice(_ index: Int) -> Binding<Bool> {
        Binding(get: { index == current },
                set: { _ in if outline.indices.contains(index) { onSelect(outline[index]) } })
    }
}

/// **"in Method ▾"** — the heading the caret is in, and a menu of the document's headings with
/// that one ticked. Choosing one scrolls there, exactly as a click on the rail's outline does.
///
/// **A button that builds its menu when it is pressed** (CHR-7). It was a SwiftUI `Menu` holding a
/// `Toggle` per heading, and the status line draws this item in up to seven rungs for
/// `ViewThatFits` to choose among — so every move of the caret into another section re-evaluated
/// every heading seven times over: about 28 ms a move at 2,000 headings in a debug build, against
/// 1–3 ms for a move that stayed in its section. Now the line carries the label alone, and
/// ``menu(for:)`` builds the items from the outline as it stands at the press.
struct EditorHeadingMenu: View {
    let headings: EditorStatusHeadings
    /// Where the menu opens from: the label's own view, recorded by the probe behind it. Made with
    /// the item rather than kept as state, so the press and the probe always share one.
    private let anchor = EditorHeadingMenuAnchor()

    var body: some View {
        Button { Self.present(headings, from: anchor.view) } label: {
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
        .buttonStyle(.hoverAffordance(.segment, tint: headings.accent))
        .background(EditorHeadingMenuAnchor.Probe(anchor: anchor))
        // The wash's own padding taken back outside it, as the header's folded crumb does, so the
        // glyph starts on the line's 14pt edge and the counts keep their 14pt gap.
        .padding(.horizontal, -4)
        .help(headings.help)
        .accessibilityLabel(headings.accessibilityName)
        .accessibilityHint("Shows the document’s headings")
    }

    /// **The menu, built from the outline as it stands**: every heading, lower levels stepped in
    /// (``EditorStatusHeadings/menuTitle(_:)``), the one the caret is in ticked, and choosing any —
    /// the ticked one too — going to it (``EditorStatusHeadings/choice(_:)``). While the rail shows its
    /// Text Files, a last item switches it to the Outline.
    static func menu(for headings: EditorStatusHeadings) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, entry) in headings.outline.enumerated() {
            let item = EditorClosureMenuItem(title: EditorStatusHeadings.menuTitle(entry)) {
                headings.choice(index).wrappedValue = true
            }
            item.state = index == headings.current ? .on : .off
            menu.addItem(item)
        }
        if headings.offersRailOutline {
            menu.addItem(.separator())
            menu.addItem(EditorClosureMenuItem(title: EditorStatusHeadings.railOutlineTitle) {
                headings.onShowRailOutline()
            })
        }
        return menu
    }

    /// Opens ``menu(for:)`` under the label, as the pull-down it replaces did — AppKit moves it up when
    /// the line is at the foot of the screen.
    private static func present(_ headings: EditorStatusHeadings, from view: NSView?) {
        guard let view else { return }
        let below = view.isFlipped ? NSPoint(x: 0, y: view.bounds.maxY + 2) : NSPoint(x: 0, y: -2)
        menu(for: headings).popUp(positioning: nil, at: below, in: view)
    }
}

/// The view a heading menu opens from — an empty one behind the label, so it shares its frame.
final class EditorHeadingMenuAnchor {
    weak var view: NSView?

    struct Probe: NSViewRepresentable {
        let anchor: EditorHeadingMenuAnchor
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
    }
}

/// A menu item that runs a closure. Its own target, which the menu it is in keeps alive.
final class EditorClosureMenuItem: NSMenuItem {
    private let act: () -> Void

    init(title: String, act: @escaping () -> Void) {
        self.act = act
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("EditorClosureMenuItem is built in code") }

    @objc private func fire() { act() }
}
