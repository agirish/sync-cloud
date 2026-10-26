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

    /// The buffer's counts, encoding and line endings — or `nil` while the ones counted are another
    /// file's (ED2): the counts and the file's facts are not drawn until this file's arrive — their
    /// room held by ``heldFacts`` — and the size, which is this file's already, stands alone. See
    /// ``shownFacts(_:countedFor:open:)``.
    let facts: EditorDocumentFacts?
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
    /// **An edit Preview could not make (TE67 §1.2)**, said for a few seconds in the line's free
    /// space — the "only minor edits work here" message, at the moment it matters rather than as a
    /// standing warning. The host clears it after ``EditorStatusHint/duration``. See
    /// ``HintPlace`` for where it stands and what gives way to it.
    var hint: EditorStatusHint?
    /// **The selection's counts, while text is selected (TE60)** — "12 of 78 words · 64 characters
    /// selected" in the counts' place — or `nil` for a bare caret, when the line reads as it always did.
    var selection: EditorSelectionFacts?
    /// **"Line, Col" as a door to Go to Line (TE61)**, or `nil` where there is no going (Preview).
    var goToLine: EditorStatusGoToLine?
    /// Drops the selection's line count from a forced rung — the ladder's first concession, for the
    /// tests that measure it. Ignored when the rung is chosen by width.
    var forcedDropsSelectionLines = false
    /// **What a change from elsewhere just did (TE59)** — "Reloaded — changed elsewhere" — for a
    /// few seconds, standing where the hint would (``HintPlace``), so Line/Col stays put under it as
    /// well. The hint outranks it: that one has a control in it.
    var notice: String?
    /// **The counts on hand while ``facts`` is `nil`** — the last file's, between a file switch and
    /// this file's first count (EP5). Laid out and never drawn, so the segments hold their room and
    /// the line does not shut and reopen on every switch; never read aloud either.
    var heldFacts: EditorDocumentFacts?
    /// **Whether ``caret`` is this file's** — `false` between a file switch and the caret's first
    /// derivation for it (EP4). "Line, Col" then holds its room undrawn, rather than the main actor
    /// walking up to the whole new text to fill it at once.
    var caretIsCurrent = true

    @Environment(\.appFontScale) private var scale
    /// The drawn caret's bounds in the line, for Go to Line's arrow (TE61) and for where the hint's
    /// free space starts (TE213).
    @State private var caretBounds: CGRect = .zero
    /// Where the caret ends in the line's own rungs — not ``hinted(_:)``'s, which draws it
    /// elsewhere and would answer the question of whether the hint fits beside the rungs with the
    /// wrong caret, and flip between the two each pass.
    @State private var ladderCaretEnd: CGFloat = 0
    /// The line's own width, for where the hint's free space ends.
    @State private var lineWidth: CGFloat = 0
    /// What each of the hint's rungs needs, measured off the line (``hintPlace``).
    @State private var hintWidths: [EditorStatusHint.Rung: CGFloat] = [:]
    /// The heading menu's bounds in the line's own rungs — the room the hint can take from it.
    @State private var headingBounds: CGRect = .zero

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
            && a.notice == b.notice && a.heldFacts == b.heldFacts && a.caretIsCurrent == b.caretIsCurrent
    }

    /// **The notice gives way while Go to Line's field is up.** Both want the leading slot, and the
    /// field is what the person has just asked for: under the notice there was no caret for it to
    /// hang from, so ⌃⌘L showed nothing, and a notice arriving mid-typing took the slot from under
    /// the field. A notice is news that times out on its own, so it waits — and is said again if
    /// its seconds are not up when the field closes.
    private var shownNotice: String? { goToLine?.isPresented.wrappedValue == true ? nil : notice }

    /// **What stands over the line now**: the hint, else the notice — one at a time, in one place.
    private var message: EditorStatusMessage? {
        if let hint { return .hint(hint) }
        return shownNotice.map(EditorStatusMessage.notice)
    }

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
        lineType(Group {
            if let message, message.forcedRung != nil || hintPlace == .aside {
                hinted(message)
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
        })
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { lineWidth = $0 }
        // The hint, or the notice, where ``hintPlace`` puts it — see ``HintPlace``.
        .overlay(alignment: .trailing) {
            if let message, case .free(let rung) = hintPlace {
                lineType(placedRow(rung, message, room: freeSpace, alignment: .trailing)).padding(.trailing, 14)
            }
        }
        .overlay(alignment: .leading) {
            if let message, case .heading(let rung) = hintPlace {
                lineType(placedRow(rung, message, room: headingBounds.width, alignment: .leading))
                    .offset(x: headingBounds.minX)
            }
        }
        // Each of its rungs, measured and never drawn — what decides where it goes.
        .background {
            if let message, message.forcedRung == nil {
                ZStack {
                    ForEach(EditorStatusHint.Rung.allCases, id: \.self) { rung in
                        lineType(messageRow(rung, message))
                            .hidden()
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { hintWidths[rung] = $0 }
                    }
                }
            }
        }
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

    /// **The line's type**, for its rungs and for the hint over them — an overlay is outside the
    /// rungs' environment, and a hint measured in body type was measured too wide for the line.
    private func lineType(_ content: some View) -> some View {
        content
            .scaledFont(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// The line's own coordinate space, which the caret reports its bounds in.
    private static let lineSpace = "EditorStatusLine"

    /// **Where the hint stands: somewhere nothing else is, so nothing moves** (TE213). It used to
    /// take the whole line for its four seconds, so Line/Col — Go to Line's door — and the heading
    /// menu went away under whoever was reaching for them, and came back under them when it ended.
    ///
    /// Now the line keeps the rung it has and everything where it was. The hint stands in the
    /// free space — from the caret's end to the line's, where the file's facts are, which go
    /// undrawn (size, encoding, line endings: true of the file, not of the edit). Where that is too
    /// tight for more than the link — a rung whose heading has taken all the room — and the
    /// heading's place has room for words too, it stands there, the heading undrawn: the heading
    /// gives way first, and Line/Col does not move for either. Only where neither has room for the
    /// link is the line redrawn around it (``hinted(_:)``).
    ///
    /// **The notice stands by the same rule** ("Reloaded — changed elsewhere"): it took the whole
    /// line for its seconds too, Line/Col with it, under a pointer already on the way to Go to Line.
    /// It has one form, so every rung of its is the same sentence.
    enum HintPlace: Equatable {
        /// Not measured yet: the line as it is, the hint not drawn for the one pass it takes.
        case pending
        case free(EditorStatusHint.Rung)
        case heading(EditorStatusHint.Rung)
        case aside
    }

    /// The rule, apart from the measuring: the rung's widths, and the room in each place.
    static func hintPlace(freeSpace: CGFloat, headingSlot: CGFloat?,
                          widths: [EditorStatusHint.Rung: CGFloat]) -> HintPlace {
        let rungs = EditorStatusHint.Rung.allCases
        guard rungs.allSatisfy({ widths[$0] != nil }) else { return .pending }
        func widest(in room: CGFloat) -> EditorStatusHint.Rung? { rungs.first { widths[$0]! <= room } }
        let free = widest(in: freeSpace)
        let heading = headingSlot.flatMap(widest(in:))
        switch (free, heading) {
        case let (free?, heading?):
            return free == .link && heading != .link ? .heading(heading) : .free(free)
        case let (free?, nil): return .free(free)
        case let (nil, heading?): return .heading(heading)
        case (nil, nil): return .aside
        }
    }

    /// This line's place for its hint or notice, or `nil` without one (or with a forced rung, drawn
    /// alone).
    private var hintPlace: HintPlace? {
        guard let message, message.forcedRung == nil else { return nil }
        let heading = headings == nil ? nil : headingBounds.width
        let place = Self.hintPlace(freeSpace: freeSpace, headingSlot: heading, widths: hintWidths)
        guard case .notice = message, place == .aside else { return place }
        return Self.noticeCut(freeSpace: freeSpace, headingSlot: heading, atLeast: Self.noticeFloor(scale: scale))
    }

    /// From the caret's end to the line's — where the file's facts are.
    private var freeSpace: CGFloat { lineWidth - 14 - ladderCaretEnd - Self.spacing }

    /// **A notice too long for either place is cut short in the roomier one** — the narrowest column
    /// has no room for "Reloaded — changed elsewhere" whole beside Line/Col — rather than taking the
    /// line from Line/Col, unless neither has room even for ``noticeFloor(scale:)``. Ties go to the
    /// free space, as the hint's do.
    static func noticeCut(freeSpace: CGFloat, headingSlot: CGFloat?, atLeast floor: CGFloat) -> HintPlace {
        let heading = headingSlot ?? 0
        guard max(freeSpace, heading) >= floor else { return .aside }
        return heading > freeSpace ? .heading(.sentence) : .free(.sentence)
    }

    /// The least a cut notice is drawn in: room for its first word and the ellipsis.
    static func noticeFloor(scale: CGFloat) -> CGFloat {
        FontSize.scaledPointSize(10, scale: scale) * 5
    }

    /// Whether the file's facts are undrawn, the hint standing over them.
    private var hintTakesFreeSpace: Bool {
        if case .free = hintPlace { return true }
        return false
    }

    /// Whether the heading is undrawn, the hint standing in its place.
    private var hintHidesHeading: Bool {
        if case .heading = hintPlace { return true }
        return false
    }

    /// **Where neither place has room even for the link** (the narrowest column at a large text
    /// size): the heading and the counts go and Line/Col stays, beside the hint shed as the counts
    /// are — the sentence, its short form, the link. Only where Line/Col and the link cannot share
    /// the line at all is the link alone (`theHintFitsTheNarrowestColumn`). A forced rung draws that
    /// rung alone, for the tests that measure each.
    /// A notice too long even for that is cut short at its tail, as it always was.
    @ViewBuilder
    private func hinted(_ message: EditorStatusMessage) -> some View {
        if let rung = message.forcedRung {
            messageRow(rung, message)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(EditorStatusHint.Rung.allCases, id: \.self) { rung in
                    HStack(spacing: Self.spacing) {
                        caretSegment(inLadder: false)
                        messageRow(rung, message)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                switch message {
                case .hint: messageRow(.link, message)
                case .notice(let notice): Text(notice).truncationMode(.tail)
                }
            }
        }
    }

    /// The message where it stands: the hint's row, or the notice cut short to `room` if it must be.
    @ViewBuilder
    private func placedRow(_ rung: EditorStatusHint.Rung, _ message: EditorStatusMessage, room: CGFloat,
                           alignment: Alignment) -> some View {
        switch message {
        case .hint: messageRow(rung, message)
        case .notice(let notice):
            Text(notice)
                .truncationMode(.tail)
                .accessibilityLabel(notice)
                .frame(maxWidth: max(room, 0), alignment: alignment)
        }
    }

    private func messageRow(_ rung: EditorStatusHint.Rung, _ message: EditorStatusMessage) -> some View {
        HStack(spacing: 6) {
            switch message {
            case .hint(let hint):
                if let sentence = hint.sentence(rung) { Text(sentence) }
                Button { hint.onShowInSource() } label: { Text(EditorStatusHint.showInSource) }
                    .buttonStyle(.link)
                    .accessibilityHint(EditorStatusHint.needsSource)
                    .help("Switch to Source, with the caret where the refused change was")
            case .notice(let notice):
                Text(notice).accessibilityLabel(notice)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The counts, as one element for VoiceOver — the heading beside them is a control of its own.
    private func counted(_ rung: Rung, lines: Bool = false) -> some View {
        strip(rung, lines: lines)
            // Combined, the caret's button included: the one element then takes the button's
            // action, so VoiceOver's press is Go to Line wherever the mouse's click is (TE61).
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(facts: facts, caret: caretIsCurrent ? caret : nil,
                                                        fileSize: fileSize, selection: selection))
            .accessibilityHint(goToLine == nil || !caretIsCurrent ? "" : "Goes to a line")
    }

    private func rung(_ rung: Rung, _ headings: EditorStatusHeadings, fit: HeadingFit,
                      lines: Bool = false) -> some View {
        HStack(spacing: Self.spacing) {
            Group {
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
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.lineSpace)) }) { headingBounds = $0 }
            // Undrawn, its room kept, while the hint stands there (``HintPlace``).
            .opacity(hintHidesHeading ? 0 : 1)
            .allowsHitTesting(!hintHidesHeading)
            .accessibilityHidden(hintHidesHeading)
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
        // This file's counts, or the last file's held undrawn in their place (EP5).
        let counts = facts ?? heldFacts
        let drawn: Double = facts == nil ? 0 : 1
        return HStack(spacing: Self.spacing) {
            ForEach(Self.countCaptions(facts: counts, selection: selection, rung: rung, lines: lines),
                    id: \.self) { Text($0).opacity(drawn) }
            caretSegment()
            Spacer(minLength: 8)
            // The file's own facts, right-aligned and last: they are true of the file rather than
            // of what you are doing in it, and they change only when a different file is opened.
            //
            // Undrawn under a hint, which stands over them (``HintPlace``); their room is
            // kept, so the line keeps its rung.
            if rung != .caret {
                let shown: Double = hintTakesFreeSpace ? 0 : 1
                if let fileSize { Text(fileSize).opacity(shown) }
                if let encoding = counts?.encoding { Text(encoding).opacity(drawn * shown) }
                if let ending = counts?.lineEnding { Text(ending.statusCaption).opacity(drawn * shown) }
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
    static func countCaptions(facts: EditorDocumentFacts?, selection: EditorSelectionFacts?,
                              rung: Rung, lines: Bool) -> [String] {
        guard rung != .caret, let facts else { return [] }
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
    private func caretSegment(inLadder: Bool = true) -> some View {
        if let goToLine {
            Button { goToLine.isPresented.wrappedValue = true } label: {
                Text(Self.caretCaption(caret))
                    .opacity(caretIsCurrent ? 1 : 0)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: goToLine.accent))
            // ⌥ shows Go to Line's ⌃⌘L (TE194), compact to the line's small type.
            .shortcutKeycap(AppChord.goToLine.display, compact: true, shown: caretIsCurrent)
            // Where the field's arrow points — the field itself hangs on the whole line (`body`).
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.lineSpace)) }) {
                caretBounds = $0
                if inLadder { ladderCaretEnd = $0.maxX }
            }
            .padding(.horizontal, -4)
            .help(EditorStatusGoToLine.help)
            // **Undrawn is not there** (F-E8): a caret held undrawn for a file just opened kept its
            // hover wash, its tooltip and its press over blank room. VoiceOver's combined line leaves
            // it out too, rather than taking its press as the line's own.
            .allowsHitTesting(caretIsCurrent)
            .accessibilityHidden(!caretIsCurrent)
        } else {
            Text(Self.caretCaption(caret))
                .opacity(caretIsCurrent ? 1 : 0)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.lineSpace)) }) {
                    caretBounds = $0
                    if inLadder { ladderCaretEnd = $0.maxX }
                }
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
    /// A `nil` caret is one not yet derived for this file, and is left out (EP4).
    static func accessibilityLabel(facts: EditorDocumentFacts?, caret: EditorCaret?,
                                   fileSize: String? = nil, selection: EditorSelectionFacts? = nil) -> String {
        var parts = countCaptions(facts: facts, selection: selection, rung: .full, lines: true)
        if let caret { parts.append(caretCaption(caret)) }
        if let fileSize { parts.append(fileSize) }
        if let encoding = facts?.encoding { parts.append(encoding) }
        if let ending = facts?.lineEnding { parts.append("\(ending.rawValue) line endings") }
        return parts.joined(separator: ", ")
    }

    /// **The counts the line may show for the open file: the ones counted for it, else none (ED2).**
    /// The count is taken 150 ms after the text settles, so a rail click left the last file's words,
    /// encoding and line endings beside the new file's size until it landed. Keyed on the PATH and
    /// not the text's version: a version gate would blank the counts on every keystroke, where the
    /// ones on screen are this file's, a keystroke old — the debounce's ordinary bargain.
    static func shownFacts(_ facts: EditorDocumentFacts, countedFor counted: String?,
                           open: String?) -> EditorDocumentFacts? {
        counted != nil && counted == open ? facts : nil
    }

    /// **The caret's line for the open file: the one derived for it, else none** (F-E1) — the same
    /// rule as ``shownFacts(_:countedFor:open:)``, for what names a heading by the caret. The rail's
    /// outline and the line's "in …" read the last file's line against this file's headings until
    /// this file's caret landed.
    static func shownCaretLine(_ caret: EditorCaret, derivedFor derived: String?, open: String?) -> Int? {
        derived != nil && derived == open ? caret.line : nil
    }

    /// **Whether a change of path keeps the counts and the caret: when the text is the one they were
    /// taken from** (EP5). A rename, or a move made elsewhere, changes the path over the same buffer
    /// (`EditorDocument.retarget`), and hiding this file's own counts until a recount landed shut and
    /// reopened the line for nothing. Opening a file always writes the buffer, which moves its version.
    static func keepsCounts(countedAt version: Int?, textVersion: Int) -> Bool {
        version == textVersion
    }
}

/// **Which derivation of a file skips the debounce: its first, and only its first** (EP6).
///
/// A file just opened has nothing of its own on the status line, and nobody is typing in it, so its
/// first count starts at once. Every one after waits out the debounce — even while that first one
/// has not landed: a keystroke in the meantime restarts the task, and the count it started runs on
/// detached (a detached task does not cancel), so a count per keystroke piled up on a large file.
///
/// Held by the workspace as `@State` and **not observed**: asking it is a write, and a write the
/// view watched would re-render it from inside its own task.
@MainActor
final class EditorFirstCountGate {
    /// The file the undebounced derivation was last started for.
    private var startedFor: String?

    /// Whether this derivation, for `open`, may skip the debounce — the first started for it since
    /// another file's, while what is on hand was taken for some other file (`countedFor`). Recorded
    /// as it is asked, so the next one waits.
    func skipsDebounce(open: String?, countedFor: String?) -> Bool {
        guard let open, open != countedFor, open != startedFor else { return false }
        startedFor = open
        return true
    }

    /// **The debounce, asked of the gate only by a task still running** — `false` when the task was
    /// cancelled, before or during the wait. A file's arrival writes the caret it was left at, which
    /// restarts the caret's task before that task has run: asked first, the restarted task used up
    /// the file's skip, and the one that replaced it waited out the debounce after all (F-E1).
    func settle(open: String?, countedFor: String?, debounce: Duration) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !skipsDebounce(open: open, countedFor: countedFor) { try? await Task.sleep(for: debounce) }
        return !Task.isCancelled
    }
}

/// **What stands over the status line for a few seconds** — the hint or the notice, placed by one
/// rule (``EditorStatusLine/HintPlace``).
enum EditorStatusMessage {
    case hint(EditorStatusHint)
    case notice(String)

    /// The hint's forced rung, for the tests that measure each; a notice is always placed by width.
    var forcedRung: EditorStatusHint.Rung? {
        if case .hint(let hint) = self { return hint.forcedRung }
        return nil
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
            return "\(failed.formatted()) of \(of.formatted()) \(of == 1 ? "match" : "matches") "
                + "\(failed == 1 ? "needs" : "need") Source — none \(of == 1 ? "was" : "were") replaced."
        case (.short, .replaceAll(let failed, let of)?):
            return "\(failed.formatted()) of \(of.formatted()) \(failed == 1 ? "needs" : "need") Source."
        case (.sentence, _): return EditorStatusHint.needsSource
        case (.short, _): return EditorStatusHint.needsSourceShort
        }
    }

    /// Bumped per refusal, so a second refusal while the first is up restarts the host's timer.
    var token: Int
    /// Switches to Source with the caret at the refused edit.
    var onShowInSource: () -> Void
    /// Forces a rung, drawn alone, for the tests that measure each one. `nil` picks by width, in
    /// the line (``EditorStatusLine/HintPlace``).
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
    /// Markdown one with no headings yet. A `nil` caret line is one not yet derived for this file,
    /// and names no heading (F-E1).
    static func make(outline: [MarkdownOutlineEntry], caretLine: Int?, isMarkdown: Bool,
                     offersRailOutline: Bool, accent: Color,
                     onSelect: @escaping (MarkdownOutlineEntry) -> Void,
                     onShowRailOutline: @escaping () -> Void) -> EditorStatusHeadings? {
        guard isMarkdown, !outline.isEmpty else { return nil }
        return EditorStatusHeadings(outline: outline,
                                    current: caretLine.flatMap { MarkdownOutline.currentEntry(forLine: $0, in: outline) },
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
