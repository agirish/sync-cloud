import SwiftUI
import Design
import Sync

/// The editor's file rail: the text-like files and PDFs in the selected folder, and the way to add a
/// text file — and, while a PDF is open, its pages.
///
/// **A rail rather than a tree.** Changing folder is the sidebar's job, and this list exists so
/// that opening a second file in the folder you are already in does not send you to another
/// workspace and back.
///
/// **Tabs over one stack.** The files and the open document's outline used to be stacked here,
/// the second under a divider and capped at eight rows so the first would not vanish; they are now
/// tabs of ``EditorRailTab``, each with the whole card, and a PDF adds a third for its pages. That
/// doc has the argument.
struct EditorFileRailView: View {

    let folderName: String
    let entries: [EditorRailEntry]
    /// How many files the folder holds that the rail does not list, or `nil` when nothing counted
    /// them. Read only by ``fileEmptyCaption(folderName:anyEntries:filter:otherFiles:)``, which is
    /// the one place it can be seen. Defaulted, so the previews and the layout probe — which have
    /// no folder behind them — need not answer a question they have no way to.
    var otherFileCount: Int?
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
    /// `Untitled.md`. ``EditorNamingRow`` promises a row keeps its text on Esc alone; that promise
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
    /// Whether a Markdown note is open and read — what keeps the Outline tab on a text file
    /// (TE111, ``EditorRailTab/shown(pdfIsOpen:pdfHasOutline:markdownIsOpen:)``). Defaulted on, so
    /// the previews and probes that draw an outline need not say so; the workspace always says.
    var markdownIsOpen: Bool = true
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
    /// **The PDF open in Edit, or `nil`** — the workspace's own (``EditorWorkspaceView/pdf``),
    /// handed in only while one is open. It is what adds the Pages tab, and what the Outline tab
    /// lists instead of headings. Observed only by the two sections that draw it, so a page turn
    /// redraws those and not this rail.
    var pdf: EditorPDFDocument? = nil
    /// Sends the reader to a heading's line.
    var onSelectHeading: (MarkdownOutlineEntry) -> Void = { _ in }
    let onOpen: (EditorRailEntry) -> Void
    /// Commits a name. Returns `false` when the file was not created after all — the caller can
    /// refuse (an unsaved document the user declined to settle), and the row reopens with the typed
    /// name still in it rather than vanishing with the work.
    let onCreate: (String) -> Bool
    /// The ＋ — **the host's ⌘N closure**, as the header's ＋ is (see
    /// ``EditorWorkspaceView/onNewTextFile``). It used to set `isNaming` itself, which skipped what
    /// ⌘N does first: take a pane on a folder that is no place for a new file to Notes. `nil` greys
    /// it. No default, for the reason ``rowActions`` has none.
    let onNewTextFile: (() -> Void)?
    /// Where ⌘N will make its file when that is not the folder on the line above — see
    /// ``EditorWorkspaceView/newFileFolderName``.
    var newFileFolderName: String? = nil
    /// The folder line's menu: up to the top of the source and down into the folders inside — see
    /// ``EditorFolderTrail``. `nil` draws the plain line.
    let folderTrail: EditorFolderTrail?
    /// Sends the LEFT pane to a pane target the menu offers; the rail follows, since it lists the
    /// pane's folder. `nil` draws the plain line. No default, for the reason ``rowActions`` has none.
    let onGoToFolder: ((String) -> Void)?
    /// What each file row's context menu does — see ``EditorRailRowMenu``. Every act takes the
    /// ROW's path, which is not necessarily the open document's.
    ///
    /// **No default**, so every construction site says what its menu does: a defaulted `{ _ in }`
    /// is how a door ships drawn and wired to nothing, which the Open in Edit review found twice.
    let rowActions: EditorRailRowActions
    /// The fold button at the end of the line under the tabs (TE77): the list folds into the file
    /// pane's strip, where a button per tab brings it back. `nil` draws none — the previews and
    /// layout probes, which have no strip to fold into.
    ///
    /// **On that line, not beside the tabs**, where it first sat in the mockup: the tab bar spans
    /// the rail with 5pt to spare at the largest text size (`theRailTabsFitTheRailAtEveryTextSize`),
    /// and a button beside it would take its room from the words.
    var onFold: (() -> Void)? = nil

    /// The rail row's one outline, stated once and used by both the hit shape and the hover wash.
    /// `roundedRect(7)` is what the `.row` variant defaults to; naming it here is what lets the
    /// `.filled` arm — which would otherwise default to a capsule — wear the same shape.
    static let rowShape = HoverAffordanceShape.roundedRect(7)
    static var rowOutline: HoverAffordanceOutline { HoverAffordanceOutline(kind: rowShape) }

    /// The fold button's tooltip and VoiceOver label.
    static let foldTitle = "Fold the list into the strip"

    /// The rail's width: the side-column width the host's drag sets, at least
    /// ``EditorLayoutMetrics/railWidth``, which is the default for every site that does not drag.
    var width: CGFloat = EditorLayoutMetrics.railWidth

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Files list's keyboard focus, and the row its cursor is on (TE110, see
    /// ``EditorRailKeyboard``). `nil` puts the cursor on the open row until an arrow moves it.
    @FocusState private var filesFocused: Bool
    @State private var keyedPath: String?

    /// Grid or list for the Pages tab — one choice for every PDF, kept across launches.
    @AppStorage("editorPDFPagesLayout") private var pagesLayout: EditorPDFPagesLayout = .grid

    /// The tab drawn: the one chosen, unless it is not offered — Pages with no PDF open, Outline
    /// on a PDF without a contents or a text file that is not Markdown. See
    /// ``EditorRailTab/resolved(_:pdfIsOpen:pdfHasOutline:markdownIsOpen:)``.
    var shownTab: EditorRailTab {
        EditorRailTab.resolved(tab, pdfIsOpen: pdf != nil, pdfHasOutline: pdfHasOutline,
                               markdownIsOpen: markdownIsOpen)
    }

    /// Whether the open PDF's bookmarks earn the Outline tab (asked 2026-10-17).
    private var pdfHasOutline: Bool { EditorRailTab.pdfOutlineIsWorthATab(pdf?.outline ?? []) }

    /// The tab bar's selection: it READS the drawn tab and WRITES the chosen one, so a click on
    /// Files while a remembered Pages is shown as Files is still a write — and the lens sits on what
    /// is drawn, not on a tab that is not there.
    var tabBarSelection: Binding<EditorRailTab> {
        Binding(get: { shownTab }, set: { tab = $0 })
    }

    /// A file row's glyph, by what opens it.
    static func rowSymbol(_ kind: EditorRailEntry.Kind) -> String {
        kind == .pdf ? "doc.richtext" : "doc.text"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditorRailTabBar(tab: tabBarSelection,
                             tabs: EditorRailTab.shown(pdfIsOpen: pdf != nil, pdfHasOutline: pdfHasOutline,
                                                       markdownIsOpen: markdownIsOpen),
                             accent: accent, onAccent: onAccent)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            contextRow
            switch shownTab {
            case .files: filesSection
            case .pages:
                if let pdf {
                    EditorPDFRailPages(pdf: pdf, view: pdf.view, thumbnails: pdf.thumbnails, tools: pdf.tools, accent: accent,
                                       layout: pagesLayout, railWidth: width)
                }
            case .outline: outlineSection
            }
            Spacer(minLength: 0)
        }
        .frame(width: width)
        // **`initial: true`, and that is the whole ⌘N-from-another-workspace path.** The editor's
        // view does not exist while another workspace is on screen, so ⌘N sets `isNaming` and
        // *then* this view is constructed — already open. Without `initial:` the change never
        // happened as far as this modifier is concerned, and the row appeared with an empty field,
        // no focus, and a "Type a name for the file." hint under it.
        //
        // **Only the tab is handled here.** The prefill and the focus travel with the row itself
        // (``EditorNamingRow``), which is also drawn in the document column when this rail is not
        // on screen; what stays behind is the one thing that is about the rail rather than the row.
        .onChange(of: isNaming, initial: true) { _, naming in
            guard naming else { return }
            // **The tab goes with it.** The naming row is drawn in the files half, and ⌘N is
            // reachable from anywhere — including from this rail with Outline showing, where
            // opening a row nobody can see would take the keystroke and answer with nothing.
            tab = .files
        }
        .onChange(of: namingFocus) { _, _ in
            guard isNaming else { return }
            tab = .files
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
            if shownTab == .files {
                // The folder's name is also the way out of it: a menu up the tree and down into
                // the folders inside, which moves the pane — see ``EditorFolderTrail``.
                EditorRailFolderMenu(name: contextName, trail: folderTrail, accent: accent,
                                     onGoTo: onGoToFolder)
            } else {
                Image(systemName: pdf == nil ? "doc.text" : "doc.richtext")
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(contextName)
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if shownTab == .files {
                // Frosted and Clear: Filter and ＋ share one glass capsule, as Finder groups related
                // buttons (`ChromeGlass`). The row's own 5pt, so Solid's layout is untouched.
                HStack(spacing: 5) {
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
                            // **Greyed where it shows** (TE138), the header ＋'s rule: `.disabled`
                            // alone leaves a `.glyph` button drawn at full strength, so an empty
                            // folder's filter looked pressable and did nothing.
                            .foregroundStyle(entries.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.hoverAffordance(filterIsExpanded ? .filled : .glyph, tint: accent))
                    .accessibilityLabel("Filter files")
                    .help("Filter this list by name")
                    .disabled(entries.isEmpty)
                    Button {
                        onNewTextFile?()
                    } label: {
                        Image(systemName: "plus")
                            .scaledFont(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.hoverAffordance(.glyph, tint: accent))
                    .accessibilityLabel("New text file")
                    .shortcutKeycap(AppChord.newTextFile.display)
                    .help(ShortcutHint.tooltip(newFileDestination, AppChord.newTextFile.display))
                    .disabled(onNewTextFile == nil)
                }
                .chromeGlassGroup(.capsule, outset: ChromeGlass.smallGlyphOutset)
            }
            if shownTab == .pages, pdf != nil {
                // Grid and List, one glass capsule as Filter and ＋ are on Files, the one in use lit.
                HStack(spacing: 5) {
                    ForEach(EditorPDFPagesLayout.allCases, id: \.self) { layout in
                        Button {
                            pagesLayout = layout
                        } label: {
                            Image(systemName: layout.symbol)
                                .scaledFont(.system(size: 11, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.hoverAffordance(pagesLayout == layout ? .filled : .glyph, tint: accent))
                        .accessibilityLabel(layout.title)
                        .accessibilityAddTraits(pagesLayout == layout ? .isSelected : [])
                        .help(layout.help)
                    }
                }
                .chromeGlassGroup(.capsule, outset: ChromeGlass.smallGlyphOutset)
            }
            // On both tabs, at the same end of the line, so it does not move when the tab does.
            if let onFold {
                Button(action: onFold) {
                    Image(systemName: "chevron.left")
                        .scaledFont(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: accent))
                .accessibilityLabel(Self.foldTitle)
                .shortcutKeycap(AppChord.editorTextFiles.display)
                .help(ShortcutHint.tooltip(Self.foldTitle, AppChord.editorTextFiles.display))
                .chromeGlassClearance(.leading, rowSpacing: 5)
            }
        }
        // **A floor, not a height.** The two tabs put different things in this row — 18pt buttons
        // on one side, an 11pt line on the other — and without it the list below would step up and
        // down by the difference on every tab click. A floor rather than a fixed height so the row
        // can still grow with Settings ▸ Text size, where the line outgrows the buttons.
        .frame(minHeight: 18)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .help(contextHelp)
    }

    /// The context line's tooltip: where ＋ makes a file, or what the tab is listing.
    private var contextHelp: String {
        switch shownTab {
        case .files: return newFileDestination
        case .pages: return "The pages of the open PDF"
        case .outline: return pdf == nil ? "The headings in the open document" : "The bookmarks in the open PDF"
        }
    }

    /// What the context line names — the folder, or the open file.
    ///
    /// The two "nothing here yet" cases say what to do about it rather than going blank: an empty
    /// rail with an unexplained blank line above it is the state a first-run session actually sees.
    private var contextName: String {
        switch shownTab {
        case .files:
            return folderName.isEmpty ? "No folder selected" : folderName
        case .pages, .outline:
            guard let selectedPath, !selectedPath.isEmpty else { return "No file open" }
            return (selectedPath as NSString).lastPathComponent
        }
    }

    /// Where ＋ would put a new file, in the words the tooltip needs. **Answers the question the
    /// folder line is there to answer**: the rail is not the sidebar, and "new file" with no
    /// destination in sight is the one act here that writes to a folder the user has not looked at.
    private var newFileDestination: String {
        let destination = newFileFolderName ?? folderName
        return destination.isEmpty
            ? "Pick a folder in the sidebar first"
            : "New files are created in \(destination)"
    }

    /// The folder's files: the naming row, the filter field, and the list — a Text Files section and
    /// a PDFs section, each left out when it has no rows (``EditorRail/sections(_:)``).
    ///
    /// **The naming row is above the sections, not a row inside Text Files**, and that is what keeps
    /// it out of reach of the rule that hides an empty section: ⌘N in a folder of nothing but PDFs
    /// still opens a row to name the new text file, over the PDFs. It is also why it is outside the
    /// scroll view, as it always was — a row being typed into must not scroll away.
    @ViewBuilder
    private var filesSection: some View {
        if isNaming {
            EditorNamingRow(isNaming: $isNaming, typedName: $typedName, namingFocus: namingFocus,
                            accent: accent, prefilledName: prefilledName, refusal: refusal,
                            // Named only when it is not the folder on the line above.
                            onCreate: onCreate, folderName: newFileFolderName)
        }
        let shown = EditorRail.filtered(entries, matching: filter)
        // In drawn order — section by section — which is the order the arrows walk.
        let order = EditorRail.sections(shown).flatMap(\.rows)
        if filterIsExpanded {
            ExpandingSearchField(text: $filter, isExpanded: $filterIsExpanded,
                                 placeholder: "Filter by name")
                .scaledFont(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                // ↩ in the filter opens the first match (TE110), and hands the keys to the list so
                // ↓ goes on from there.
                .onSubmit {
                    guard let first = Self.firstMatch(entries, filter: filter) else { return }
                    keyedPath = first.path
                    filesFocused = true
                    onOpen(first)
                }
        }
        if shown.isEmpty && !isNaming {
            emptyCaption(anyEntries: !entries.isEmpty)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(EditorRail.sections(shown)) { section in
                            sectionHeading(section.title)
                            ForEach(section.rows) { entry in row(entry).id(entry.path) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($filesFocused)
                .overlay { EditorRailFocusRing(isOn: filesFocused, accent: accent) }
                .onKeyPress(keys: EditorRailKeyboard.arrows, phases: [.down, .repeat]) { press in
                    guard press.isPlainKeystroke else { return .ignored }
                    keyedPath = EditorRailKeyboard.step(from: keyedPath ?? selectedPath, in: order.map(\.path),
                                                        by: EditorRailKeyboard.delta(for: press.key))
                    if let keyedPath { proxy.scrollTo(keyedPath) }
                    return .handled
                }
                .onKeyPress(keys: EditorRailKeyboard.commit, phases: .down) { press in
                    guard press.isPlainKeystroke,
                          let entry = order.first(where: { $0.path == (keyedPath ?? selectedPath) })
                    else { return .ignored }
                    onOpen(entry)
                    return .handled
                }
            }
        }
    }

    /// The row ↩ in the filter opens: the first one drawn, or `nil` when nothing matches.
    static func firstMatch(_ entries: [EditorRailEntry], filter: String) -> EditorRailEntry? {
        EditorRail.sections(EditorRail.filtered(entries, matching: filter)).first?.rows.first
    }

    /// A section's heading — Text Files, PDFs — in the sidebar's section-heading style.
    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .scaledFont(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    /// The open document's outline: a Markdown file's headings, or a PDF's bookmarks.
    ///
    /// **Its own tab rather than a capped section under the files.** The stacked arrangement was
    /// argued for on the grounds that "which file" and "where in it" are one question — true, and
    /// it still cost the outline a hard eight-row ceiling and a scroller inside a scroller for
    /// anything longer. A tab answers the second question with the whole card; the first is one
    /// click away, and ⌘N brings it back on its own.
    ///
    /// **One list for both kinds** (``EditorRailOutlineList``), so the scroll memory, the opening
    /// scroll and the current row's mark are the same code for a PDF as for a note — a PDF's
    /// bookmarks arrive as rows of the same type (``EditorPDFOutline/rows(_:)``).
    @ViewBuilder
    private var outlineSection: some View {
        if let pdf {
            EditorPDFRailOutline(pdf: pdf, view: pdf.view, outlineAnchors: $outlineAnchors, accent: accent)
        } else {
            EditorRailOutlineList(rows: outline, currentIndex: currentOutlineIndex, path: selectedPath,
                                  emptyCaption: Self.outlineEmptyCaption,
                                  outlineAnchors: $outlineAnchors, accent: accent,
                                  onSelect: onSelectHeading)
                // One list per document — see `EditorRailOutlineList`'s `topRow`.
                .id(selectedPath)
        }
    }

    /// What the outline says when it has no rows. **One case now** (TE111): the tab is offered only
    /// while a Markdown note is open, so the empty list is always a note with no headings yet, and
    /// "there are none" is unhelpful there in the way "The + button makes one" is unhelpful to a
    /// filter that matched nothing. The other empty it used to tell apart — nothing open — no longer
    /// draws the tab at all, and neither does a `.txt`, where the `#` advice was wrong.
    static let outlineEmptyCaption = "No headings in this document. A line starting with # makes one."

    /// The step each outline level is drawn in by. Half the preview's, because the rail is 232pt
    /// wide and the words are what matter here.
    static let outlineIndentStep: CGFloat = 10

    /// One outline row, for the test that measures a drawn row against the height estimate the
    /// fold arithmetic runs on. **A seam rather than a replica**: the number that matters is what
    /// this builder lays out, and a test that rebuilt the row would be measuring its own copy.
    static func outlineRowProbe(_ entry: MarkdownOutlineEntry, isCurrent: Bool) -> some View {
        EditorRailOutlineList.probe.row(entry, isCurrent: isCurrent)
    }

    /// What the rail says when it is listing nothing — **four different questions, asked as a
    /// function so the distinctions are testable**, the shape `PaneColumnsView.emptyCaption` takes.
    ///
    /// No folder chosen; a filter that matched nothing; a folder that really is empty; and a folder
    /// that is **full of files this editor does not open**. The last is the one that was missing,
    /// and it is the ordinary case on a real disk: the rail lists only text files and PDFs, so a
    /// folder of photos or Word documents drew "No text files in this folder" — true, and
    /// indistinguishable from what an empty folder drew. Standing in a folder he had just filled,
    /// the app appeared to have lost it.
    ///
    /// "The + button makes a text file" survives into the new arm because the advice still applies:
    /// there is nothing here Edit opens and he can have a note. What it must not do any more is
    /// arrive alone, implying there is nothing else here either.
    ///
    /// - Parameter otherFiles: how many files the folder holds that the rail will not list, or
    ///   `nil` when nothing counted them. `nil` and `0` are treated alike on purpose — see
    ///   ``EditorRail/Survey/otherFileCount``, where the difference is real and where it stops.
    nonisolated static func fileEmptyCaption(folderName: String, anyEntries: Bool,
                                             filter: String, otherFiles: Int?) -> String {
        guard !folderName.isEmpty else {
            return "Pick a folder in the sidebar to see its text files and PDFs."
        }
        if anyEntries {
            return "No files here match “\(filter.trimmingCharacters(in: .whitespaces))”."
        }
        guard let otherFiles, otherFiles > 0 else {
            return "No text files or PDFs in this folder. The + button makes a text file."
        }
        // Two sentences rather than one pluralised template: "None of the 1 file" is what a shared
        // template produces, and the singular is not a corner — one PDF in a folder of its own is
        // an ordinary thing to be standing in.
        if otherFiles == 1 {
            return "The one file in this folder isn’t one the editor opens. "
                + "The + button makes a text file."
        }
        return "None of the \(otherFiles) files in this folder are ones the editor opens. "
            + "The + button makes a text file."
    }

    private func emptyCaption(anyEntries: Bool) -> some View {
        Text(Self.fileEmptyCaption(folderName: folderName, anyEntries: anyEntries,
                                   filter: filter, otherFiles: otherFileCount))
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
        let isKeyed = filesFocused && entry.path == (keyedPath ?? selectedPath)
        let dot = Self.dotColour(rowPath: entry.path, selectedPath: selectedPath,
                                 status: documentStatus, accent: accent)
        return Button {
            // A click puts the keys here too (TE110), as a click on a page does in the Pages tab.
            keyedPath = entry.path
            filesFocused = true
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
                Image(systemName: Self.rowSymbol(entry.kind))
                    .scaledFont(.system(size: 11))
                Text(entry.name)
                    .scaledFont(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                // Formatted when the rows were listed, off the main actor — see
                // ``EditorRailEntry/sizeCaption``.
                Text(entry.sizeCaption)
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            // Dim rows keep their full opacity on the SELECTED row: a row you have clicked and
            // that has answered with a caption should not also be hard to read.
            .opacity(entry.isDimmed && !isSelected ? 0.5 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Self.rowOutline)
            .background { EditorRailKeyedRowMark(isOn: isKeyed && !isSelected, accent: accent) }
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
        // **On every row, dim ones included, and not gated on anything about the row.** A file
        // the editor refuses is the one most worth revealing or inspecting — see
        // ``EditorRailRowMenu``. The path is the ROW's, never `selectedPath`.
        .contextMenu { EditorRailRowMenu(path: entry.path, isCloudOnly: entry.isCloudOnly, actions: rowActions) }
    }
}
