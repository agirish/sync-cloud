import SwiftUI
import Design
import Sync

/// The editor's file rail: the text-like files in the selected folder, and the way to add one.
///
/// **A rail rather than a tree.** Changing folder is the sidebar's job, and this list exists so
/// that opening a second file in the folder you are already in does not send you to another
/// workspace and back.
///
/// **Two tabs over one stack.** The files and the open document's outline used to be stacked here,
/// the second under a divider and capped at eight rows so the first would not vanish; they are now
/// the two halves of ``EditorRailTab``, each with the whole card. That doc has the argument.
struct EditorFileRailView: View {

    let folderName: String
    let entries: [EditorRailEntry]
    let selectedPath: String?
    let accent: Color
    /// The label colour on the accent fill, for the selected tab. See ``EditorRailTabBar/onAccent``.
    let onAccent: Color
    /// Which half of the rail is showing. A binding for the reason ``filter`` is one — and because
    /// ⌘N reaches in from outside to put it back on ``EditorRailTab/files``.
    @Binding var tab: EditorRailTab
    /// Whether the inline naming row is showing. A binding, because ⌘N opens it from outside this
    /// view — from another workspace, even.
    @Binding var isNaming: Bool
    /// **Held by the host, beside `isNaming`, and this pairing is the point.** `isNaming` was
    /// hoisted because the editor's view does not exist while another workspace is on screen; this
    /// is the one of the two that holds something the USER TYPED, and it was left behind as
    /// `@State`. Typing a name, switching to Browse and switching back left the row open with the
    /// field silently reset — and `onChange(initial: true)` then saw it empty and overwrote it with
    /// `Untitled.md`. The comment on ``cancelNaming()`` promises a row keeps its text; that promise
    /// held for a click elsewhere and not for a tab switch.
    @Binding var typedName: String
    /// Where the OPEN document stands, so its row in the list can say so too. `nil` when nothing
    /// is open. Only the open document can be unsaved, so this needs no path of its own — the row
    /// it belongs to is the selected one.
    var documentStatus: EditorSaveStatus?
    /// A counter the host bumps on every ⌘N.
    ///
    /// **A signal, not a value.** Pressing ⌘N while the row is already open writes `true` over
    /// `true`, which is not a change, so the `onChange` below never fires and focus stays wherever
    /// it was — the second press looked like it did nothing at all.
    var namingFocus: Int = 0
    /// The name the row is prefilled with when it opens. A closure, not a value: resolving it
    /// walks the folder looking for the first free `Untitled`, and as a plain argument that walk
    /// ran on every body pass — which is every keystroke in the editor — whether or not the row
    /// was open.
    let prefilledName: () -> String
    /// Why the typed name cannot be used, asked as the user types.
    let refusal: (String) -> String?
    /// What was typed into the rail's filter, and whether the field is showing.
    ///
    /// **Both held by the host, for the reason `typedName` is.** This view does not exist while
    /// another workspace is on screen, so as `@State` a filter would be silently forgotten by a
    /// trip to Browse and back — with the rail returning to a full list the user did not ask for.
    @Binding var filter: String
    @Binding var filterIsExpanded: Bool
    /// The open document's headings, or empty when it has none — a `.txt`, or Markdown that never
    /// uses one. Empty means the whole section is absent rather than present and blank.
    var outline: [MarkdownOutlineEntry] = []
    /// Which outline row the caret is inside, or `nil` when it is above the first heading.
    var currentOutlineIndex: Int?
    /// Where each document's outline was last scrolled to, keyed by path, as the source line of the
    /// top visible heading.
    ///
    /// **Held by the host for the reason the filter and the tab are** — this view is destroyed by a
    /// trip to Browse and back — and keyed by path rather than kept as one value because the point
    /// is per-document memory. It is not persisted across launches: it describes a reading session,
    /// the same call ``EditorRailTab`` and ``EditorMode`` make. Nothing evicts from it; an entry is
    /// a path and an integer, and a session would have to open tens of thousands of files before
    /// that is worth a rule.
    @Binding var outlineAnchors: [String: Int]
    /// Sends the reader to a heading's line.
    var onSelectHeading: (MarkdownOutlineEntry) -> Void = { _ in }
    let onOpen: (EditorRailEntry) -> Void
    /// Commits a name. Returns `false` when the file was not created after all — the caller can
    /// refuse (an unsaved document the user declined to settle), and the row reopens with the typed
    /// name still in it rather than vanishing with the work.
    let onCreate: (String) -> Bool

    /// The rail row's one outline, stated once and used by both the hit shape and the hover wash.
    /// `roundedRect(7)` is what the `.row` variant defaults to; naming it here is what lets the
    /// `.filled` arm — which would otherwise default to a capsule — wear the same shape.
    static let rowShape = HoverAffordanceShape.roundedRect(7)
    static var rowOutline: HoverAffordanceOutline { HoverAffordanceOutline(kind: rowShape) }

    /// The rail's width. See ``EditorLayoutMetrics/railWidth``.
    static var width: CGFloat { EditorLayoutMetrics.railWidth }

    @FocusState private var nameFieldFocused: Bool
    /// The outline's top row, as `.scrollPosition(id:)` reports and accepts it.
    @State private var outlineTopRow: Int?
    /// The outline section's height, as the scroll view reports it — the one input that decides how
    /// many rows are on screen, and so whether the caret's heading would be past the fold.
    ///
    /// **`onGeometryChange` on the scroll view, not a `GeometryReader` around it.** A reader is a
    /// container with no intrinsic size of its own, and one wrapped around this rail collapsed it to
    /// 10pt for anything asking its ideal height — the trap `EditorLayoutTests` caught when the
    /// outline was first built. A modifier reads the same number and takes part in no layout.
    @State private var outlineHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read again for the outline's row-height arithmetic — how many rows fit is a question about
    /// the app's text size as much as about the section's height.
    @Environment(\.appFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditorRailTabBar(tab: $tab, accent: accent, onAccent: onAccent)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            contextRow
            switch tab {
            case .files: filesSection
            case .outline: outlineSection
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        // **`initial: true`, and that is the whole ⌘N-from-another-workspace path.** The editor's
        // view does not exist while another workspace is on screen, so ⌘N sets `isNaming` and
        // *then* this view is constructed — already open. Without `initial:` the change never
        // happened as far as this modifier is concerned, and the row appeared with an empty field,
        // no focus, and a "Type a name for the file." hint under it.
        .onChange(of: isNaming, initial: true) { _, naming in
            // Prefilled at the moment it opens, not held between openings: the first free
            // `Untitled` can change while the row is closed, and a stale prefill would land the
            // user on a name that now collides.
            guard naming else { return }
            // **The tab goes with it.** The naming row is drawn in the files half, and ⌘N is
            // reachable from anywhere — including from this rail with Outline showing, where
            // opening a row nobody can see would take the keystroke and answer with nothing.
            tab = .files
            if typedName.isEmpty { typedName = prefilledName() }
            nameFieldFocused = true
        }
        .onChange(of: namingFocus) { _, _ in
            guard isNaming else { return }
            tab = .files
            nameFieldFocused = true
        }
    }

    /// The line under the tabs: which folder these files are in, or which document this outline
    /// belongs to.
    ///
    /// **The sentence the old header used to be, split in two.** That header read "Text files in
    /// Downloads" — a phrase that truncated in the middle on any folder with a real name, in a
    /// 232pt rail, at the one text size where it mattered most. The kind of thing is now the tab
    /// and the name of the thing is here, with the whole width to itself.
    ///
    /// **Present on both tabs, and that is a layout decision as much as an informational one.**
    /// The files half carries two buttons and the outline half carries none, so a row that appeared
    /// only over the files would move the list under it by its own height every time the tabs were
    /// clicked. It says something worth saying on both sides, so it says it on both sides.
    private var contextRow: some View {
        HStack(spacing: 5) {
            Image(systemName: tab == .files ? "folder" : "doc.text")
                .scaledFont(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(contextName)
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if tab == .files {
                // **Revealed rather than always shown**, the bargain every other search in this app
                // strikes: the rail is 232pt wide and a permanent field would spend a row of it on
                // a control most sessions never touch.
                Button {
                    // `withDesignAnimation`, not a bare `withAnimation` — the reveal is a width
                    // change under the pointer, which is exactly what Reduce Motion turns off. A
                    // repo-wide scan in the Design package holds every site in the app to this.
                    withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) {
                        filterIsExpanded.toggle()
                    }
                    if !filterIsExpanded { filter = "" }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.hoverAffordance(filterIsExpanded ? .filled : .glyph, tint: accent))
                .accessibilityLabel("Filter text files")
                .help("Filter this list by name")
                .disabled(entries.isEmpty)
                Button {
                    isNaming = true
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: accent))
                .accessibilityLabel("New text file")
                .shortcutKeycap(AppChord.newTextFile.display)
                .help(ShortcutHint.tooltip(newFileDestination, AppChord.newTextFile.display))
                .disabled(folderName.isEmpty)
            }
        }
        // **A floor, not a height.** The two tabs put different things in this row — 18pt buttons
        // on one side, an 11pt line on the other — and without it the list below would step up and
        // down by the difference on every tab click. A floor rather than a fixed height so the row
        // can still grow with Settings ▸ Text size, where the line outgrows the buttons.
        .frame(minHeight: 18)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .help(tab == .files ? newFileDestination : "The headings in the open document")
    }

    /// What the context line names — the folder, or the open file.
    ///
    /// The two "nothing here yet" cases say what to do about it rather than going blank: an empty
    /// rail with an unexplained blank line above it is the state a first-run session actually sees.
    private var contextName: String {
        switch tab {
        case .files:
            return folderName.isEmpty ? "No folder selected" : folderName
        case .outline:
            guard let selectedPath, !selectedPath.isEmpty else { return "No file open" }
            return (selectedPath as NSString).lastPathComponent
        }
    }

    /// Where ＋ would put a new file, in the words the tooltip needs. **Answers the question the
    /// folder line is there to answer**: the rail is not the sidebar, and "new file" with no
    /// destination in sight is the one act here that writes to a folder the user has not looked at.
    private var newFileDestination: String {
        folderName.isEmpty
            ? "Pick a folder in the sidebar first"
            : "New files are created in \(folderName)"
    }

    /// The folder's text files: the naming row, the filter field, and the list itself.
    @ViewBuilder
    private var filesSection: some View {
        if isNaming { namingRow }
        if filterIsExpanded {
            ExpandingSearchField(text: $filter, isExpanded: $filterIsExpanded,
                                 placeholder: "Filter by name")
                .scaledFont(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
        let shown = EditorRail.filtered(entries, matching: filter)
        if shown.isEmpty && !isNaming {
            emptyCaption(anyEntries: !entries.isEmpty)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { entry in row(entry) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    /// The inline naming row — the same bargain New Folder strikes: the field opens, and nothing
    /// exists on disk until Return.
    private var namingRow: some View {
        let hint = refusal(typedName)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Name", text: $typedName)
                    .textFieldStyle(.plain)
                    .scaledFont(.system(size: 12))
                    .focused($nameFieldFocused)
                    .onSubmit {
                        // **`refusal(typedName)` again, not the captured `hint`.** That value was
                        // computed when this body was built; the field has been typed into since,
                        // and a Return that validates one string while creating another is how a
                        // name gets past a check that was looking at the previous keystroke.
                        guard refusal(typedName) == nil else { return }
                        // **The row closes only once the file exists.** It used to close first and
                        // create second, so a prompt raised in between — "save your changes to the
                        // document you are leaving?" — could be cancelled, and the effect of
                        // answering Cancel to a question about one file was that the name typed for
                        // another was gone, with nothing on screen to say so.
                        if onCreate(typedName) {
                            typedName = ""
                            isNaming = false
                        }
                    }
                    .onExitCommand { cancelNaming() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Radius.control)
                .fill(accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: Radius.control)
                .stroke(accent.opacity(0.5), lineWidth: 1))
            if let hint {
                Text(hint)
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    /// Shuts the naming row and forgets what was typed. Esc, and nothing else — a row abandoned by
    /// clicking elsewhere keeps its text, because the next ⌘N is more likely to be a return to it
    /// than a fresh start.
    private func cancelNaming() {
        typedName = ""
        isNaming = false
    }

    /// The open document's headings.
    ///
    /// **Its own tab rather than a capped section under the files.** The stacked arrangement was
    /// argued for on the grounds that "which file" and "where in it" are one question — true, and
    /// it still cost the outline a hard eight-row ceiling and a scroller inside a scroller for
    /// anything longer. A tab answers the second question with the whole card; the first is one
    /// click away, and ⌘N brings it back on its own.
    ///
    /// **The two empty states are different questions**, the same distinction ``emptyCaption(anyEntries:)``
    /// draws for the files: nothing is open, or something is open and has no headings in it. A
    /// `.txt` and a note that never types a `#` land in the second, which is why it says what makes
    /// a heading rather than only that there are none.
    @ViewBuilder
    private var outlineSection: some View {
        if outline.isEmpty {
            Text(Self.outlineEmptyCaption(hasDocument: selectedPath != nil))
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(outline.enumerated()), id: \.element.id) { index, entry in
                        outlineRow(entry, isCurrent: index == currentOutlineIndex)
                            .id(entry.id)
                    }
                }
                // The rows are the scroll targets, which is what lets the view below report which
                // of them are on screen.
                .scrollTargetLayout()
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            // **Both directions of one binding.** It accepts the row to open at, below, and it
            // reports the top row as the reader scrolls, which is what the recording reads.
            .scrollPosition(id: $outlineTopRow)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { outlineHeight = $0 }
            // **`initial: true` on the outline, not on the path.** The outline is CLEARED the
            // instant the path changes and refilled 150ms later by a parse that runs off the main
            // actor, so a restore hung on the path change would scroll a list with no rows in it and
            // do nothing at all. This fires on the arrival, which is the first moment there is
            // anything to scroll to — and on the tab coming back, where the rows are already there.
            .onChange(of: outline, initial: true) { _, rows in
                guard !rows.isEmpty else { return }
                let fits = EditorOutlineScroll.rowsThatFit(height: outlineHeight, scale: fontScale)
                if let target = EditorOutlineScroll.openingTarget(remembered: rememberedAnchor,
                                                                  current: currentOutlineRow,
                                                                  outline: rows,
                                                                  rowsThatFit: fits) {
                    outlineTopRow = target
                }
            }
            // **Recording is the binding reporting, not a second observation.** Every way the top
            // row can change ends up here — the reader scrolling, and the opening scroll above —
            // and both are worth remembering: the list is where it is either way.
            .onChange(of: outlineTopRow) { _, top in
                guard EditorOutlineScroll.recordsAnchor(path: selectedPath,
                                                        outlineIsEmpty: outline.isEmpty,
                                                        top: top),
                      let path = selectedPath, let top else { return }
                outlineAnchors[path] = top
            }
        }
    }

    /// The row this document was left on, or `nil` for one nobody has scrolled yet.
    private var rememberedAnchor: Int? {
        selectedPath.flatMap { outlineAnchors[$0] }
    }

    /// The caret's heading as a row id rather than an index into the array — which is what the
    /// scroll view speaks, and what makes "is it visible" a set membership test.
    private var currentOutlineRow: Int? {
        guard let currentOutlineIndex, outline.indices.contains(currentOutlineIndex) else {
            return nil
        }
        return outline[currentOutlineIndex].id
    }

    /// What the outline says when it has no rows — **two different questions, asked as a function
    /// so the distinction is testable.** Nothing is open, or something is open and has no headings
    /// in it; a `.txt` and a note that never types a `#` land in the second, and "there are none"
    /// is unhelpful there in the way "The + button makes one" is unhelpful to a filter that matched
    /// nothing. Same shape as ``emptyCaption(anyEntries:)``, one level up.
    static func outlineEmptyCaption(hasDocument: Bool) -> String {
        hasDocument
            ? "No headings in this document. A line starting with # makes one."
            : "Open a text file to see its headings."
    }

    /// The step each outline level is drawn in by. Half the preview's, because the rail is 232pt
    /// wide and the words are what matter here.
    static let outlineIndentStep: CGFloat = 10

    /// One outline row, for the test that measures a drawn row against the height estimate the
    /// fold arithmetic runs on. **A seam rather than a replica**: the number that matters is what
    /// this builder lays out, and a test that rebuilt the row would be measuring its own copy.
    static func outlineRowProbe(_ entry: MarkdownOutlineEntry, isCurrent: Bool) -> some View {
        EditorFileRailView.probe.outlineRow(entry, isCurrent: isCurrent)
    }

    /// A rail with nothing in it, built only to reach ``outlineRow(_:isCurrent:)`` from the probe.
    private static var probe: EditorFileRailView {
        EditorFileRailView(folderName: "", entries: [], selectedPath: nil, accent: .blue,
                           onAccent: .white, tab: .constant(.outline), isNaming: .constant(false),
                           typedName: .constant(""), prefilledName: { "" }, refusal: { _ in nil },
                           filter: .constant(""), filterIsExpanded: .constant(false),
                           outlineAnchors: .constant([:]), onOpen: { _ in }, onCreate: { _ in true })
    }

    private func outlineRow(_ entry: MarkdownOutlineEntry, isCurrent: Bool) -> some View {
        Button {
            onSelectHeading(entry)
        } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: CGFloat(entry.depth) * Self.outlineIndentStep, height: 1)
                // **An empty heading keeps its row.** `##` on its own is legal and it is somewhere
                // in the document you can go; a row with nothing in it would be unclickable-looking,
                // so it says what it is instead of pretending it is not there.
                Text(entry.title.isEmpty ? "Untitled heading" : entry.title)
                    .scaledFont(.system(size: 11,
                                        weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(entry.title.isEmpty ? AnyShapeStyle(.tertiary)
                                                         : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Self.rowOutline)
        }
        .buttonStyle(.hoverAffordance(isCurrent ? .filled : .row,
                                      tint: accent, shape: Self.rowShape))
        .help(entry.title.isEmpty ? "Untitled heading" : entry.title)
        .accessibilityLabel("Heading level \(entry.level), \(entry.title)")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// - Parameter anyEntries: whether the folder has text files at all. **The two empties are
    ///   different questions** — a folder with nothing in it, and a filter that matched nothing —
    ///   and "The + button makes one" is unhelpful advice for the second.
    private func emptyCaption(anyEntries: Bool) -> some View {
        Text(folderName.isEmpty
             ? "Pick a folder in the sidebar to see the text files in it."
             : anyEntries
               ? "No text files here match “\(filter.trimmingCharacters(in: .whitespaces))”."
               : "No text files in this folder. The + button makes one.")
            .scaledFont(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, 4)
    }

    /// The colour of a row's leading dot, or `nil` for no dot.
    ///
    /// **Only the open row can have one**, which is the whole rule: a rail lists many files and
    /// exactly one of them is the document, so a dot resolved per row from a document-wide status
    /// would mark every file in the folder as unsaved. Asked as a function rather than inline so
    /// that claim is testable — the mistake it guards is invisible in a screenshot of a
    /// one-file folder.
    static func dotColour(rowPath: String, selectedPath: String?,
                          status: EditorSaveStatus?, accent: Color) -> Color? {
        guard rowPath == selectedPath, let status, status.showsDot else { return nil }
        return status.isWarning ? .orange : accent
    }

    /// The width the dot's column always occupies, dot or no dot.
    ///
    /// **Reserved rather than inserted**, because this appears and disappears as you type: a dot
    /// that took its own space would shove every file name in the list sideways on the first
    /// keystroke and back again two seconds later. BBEdit reserves the same column, which is why
    /// its list is still while you type into a document.
    ///
    /// **The reservation is the UNCONDITIONAL `Circle` below, not this number** — a clear fill
    /// still takes part in layout, where an `if let` around the whole shape would not. Worth
    /// stating because the tempting tidy-up is exactly the one that breaks it, and no test here
    /// can catch it: the rail is hard-framed so its width cannot move, and a 5pt dot is shorter
    /// than the 12pt name beside it so the row's height does not move either. Measured — both
    /// mutations were run against a rendered test and neither changed a pixel of the rail's size,
    /// which is why that test was deleted rather than kept as reassurance.
    static let dotColumnWidth: CGFloat = 9

    private func row(_ entry: EditorRailEntry) -> some View {
        let isSelected = entry.path == selectedPath
        let dot = Self.dotColour(rowPath: entry.path, selectedPath: selectedPath,
                                 status: documentStatus, accent: accent)
        return Button {
            onOpen(entry)
        } label: {
            HStack(spacing: 6) {
                // The unsaved marker, before the icon — where BBEdit puts it, and where a column of
                // them reads as a column rather than as punctuation inside the names.
                Circle()
                    .fill(dot ?? .clear)
                    .frame(width: 5, height: 5)
                    .frame(width: Self.dotColumnWidth, alignment: .leading)
                    .accessibilityHidden(dot == nil)
                    .accessibilityLabel("Unsaved")
                Image(systemName: "doc.text")
                    .scaledFont(.system(size: 11))
                Text(entry.name)
                    .scaledFont(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(FileSyncManager.formatBytes(entry.size))
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            // Dim rows keep their full opacity on the SELECTED row: a row you have clicked and
            // that has answered with a caption should not also be hard to read.
            .opacity(entry.isDimmed && !isSelected ? 0.5 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Self.rowOutline)
        }
        // **`.row`, and the shape passed explicitly to BOTH arms.**
        //
        // This shipped as `isSelected ? .filled : .inline`, and `.inline` is the wrong variant
        // twice over. It is documented for "a small dismiss glyph riding inside a field or chip",
        // so it washes in ink rather than the accent — and its default shape is a CIRCLE. A circle
        // in a full-width row collapses to the row's height and centres itself, which is what put a
        // grey disc in the middle of the row under the pointer instead of a wash across it. `.row`
        // is the variant written for this exact control: a full-width list row whose whole area is
        // the target, with a quieter wash because it covers so many more pixels than a glyph.
        //
        // The shape is passed rather than left to default because BOTH arms need it: `.filled`
        // defaults to a capsule, so the selected row's hairline ring traced a pill around a rounded
        // rectangle — the mis-shaped-when-selected half of the same defect, which `HoverAffordanceShape`
        // warns about in so many words. One value, used by the style and by `contentShape` above,
        // which is what `HoverAffordanceOutline` exists for.
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .row,
                                      tint: accent, shape: Self.rowShape))
        .help(entry.dimmedReason ?? entry.name)
    }
}
