import SwiftUI
import Design
import Sync

/// The editor's file rail: the text-like files and PDFs in the selected folder, the way to add a
/// text file, and, while a PDF is open, its pages.
///
/// A rail, not a tree: changing folder is the sidebar's job, and this list lets you open another
/// file in the same folder without leaving the workspace. The files and the outline are tabs of
/// ``EditorRailTab``, each with the whole card, and a PDF adds a third for its pages.
struct EditorFileRailView: View {

    let folderName: String
    let entries: [EditorRailEntry]
    /// How many files the folder holds that the rail doesn't list, or `nil` when nothing counted
    /// them. Read only by ``fileEmptyCaption(folderName:anyEntries:filter:otherFiles:)``. Defaulted
    /// for the previews and the layout probe, which have no folder behind them.
    var otherFileCount: Int?
    let selectedPath: String?
    let accent: Color
    /// What the selected tab fills with (``EditorWorkspaceView/accentFill``).
    let accentFill: Color
    /// The label colour on `accentFill`, for the selected tab (``EditorRailTabBar/onAccent``).
    let onAccent: Color
    /// Which half of the rail is showing. A binding, held by the host as ``filter`` is, and so ⌘N
    /// can put it back on ``EditorRailTab/files`` from outside.
    @Binding var tab: EditorRailTab
    /// Whether the inline naming row is showing. A binding, because ⌘N opens it from outside this
    /// view, even from another workspace.
    @Binding var isNaming: Bool
    /// The name being typed, held by the host beside `isNaming`: this view doesn't exist while
    /// another workspace is on screen, and as `@State` a trip to Browse would reset the field,
    /// which ``EditorNamingRow`` then refills with `Untitled.md`. The row keeps its text until Esc.
    @Binding var typedName: String
    /// Where the open document stands, so its row can say so too; `nil` when nothing is open. Only
    /// the open document can be unsaved, so the row it belongs to is the selected one.
    var documentStatus: EditorSaveStatus?
    /// A counter the host bumps on every ⌘N. A signal, not a value: ⌘N with the row already open
    /// writes `true` over `true`, which `onChange` never sees, so focus would stay put.
    var namingFocus: Int = 0
    /// The name the row is prefilled with when it opens. A closure, not a value: resolving it walks
    /// the folder for the first free `Untitled`, which as an argument would run on every keystroke.
    let prefilledName: () -> String
    /// Why the typed name cannot be used, asked as the user types.
    let refusal: (String) -> String?
    /// What was typed into the rail's filter, and whether the field is showing. Held by the host,
    /// as `typedName` is, so a trip to Browse and back doesn't forget the filter.
    @Binding var filter: String
    @Binding var filterIsExpanded: Bool
    /// The open document's headings, or empty when it has none (a `.txt`, or Markdown with no
    /// headings).
    var outline: [MarkdownOutlineEntry] = []
    /// Whether a Markdown note is open and read, which offers the Outline tab on a text file
    /// (``EditorRailTab/shown(pdfIsOpen:pdfHasOutline:markdownIsOpen:)``). Defaulted on for the
    /// previews and probes; the workspace always says.
    var markdownIsOpen: Bool = true
    /// Which outline row the caret is inside, or `nil` when it is above the first heading.
    var currentOutlineIndex: Int?
    /// Where each document's outline was last scrolled to, keyed by path, as the source line of the
    /// top visible heading. Held by the host, as the filter is, and keyed per document. Not
    /// persisted: it describes a reading session, like ``EditorRailTab`` and ``EditorMode``. Never
    /// evicted, since an entry is a path and an integer.
    @Binding var outlineAnchors: [String: Int]
    /// The PDF open in Edit (``EditorWorkspaceView/pdf``), or `nil`. It adds the Pages tab, and the
    /// Outline tab lists its bookmarks instead of headings. Observed only by the two sections that
    /// draw it, so a page turn redraws those and not this rail.
    var pdf: EditorPDFDocument? = nil
    /// Sends the reader to a heading's line.
    var onSelectHeading: (MarkdownOutlineEntry) -> Void = { _ in }
    /// Esc in the Files or Outline list: the keys back to the open document, its text or the PDF,
    /// as Esc leaves a list everywhere else. `nil` with nothing open.
    var onReturnKeys: (() -> Void)? = nil
    let onOpen: (EditorRailEntry) -> Void
    /// Commits a name. Returns `false` when the file was not created after all (the user declined
    /// to settle an unsaved document), and the row stays open with the typed name in it.
    let onCreate: (String) -> Bool
    /// The ＋: the host's ⌘N closure, as the header's ＋ is (``EditorWorkspaceView/onNewTextFile``),
    /// so it first moves a pane off a folder that is no place for a new file, as ⌘N does. `nil`
    /// greys it. No default, for the reason ``rowActions`` has none.
    let onNewTextFile: (() -> Void)?
    /// Where ⌘N will make its file when that is not the folder on the line above
    /// (``EditorWorkspaceView/newFileFolderName``).
    var newFileFolderName: String? = nil
    /// The folder line's menu: up to the top of the source and down into the folders inside
    /// (``EditorFolderTrail``). `nil` draws the plain line.
    let folderTrail: EditorFolderTrail?
    /// Sends the left pane to a target the menu offers; the rail follows, since it lists the pane's
    /// folder. `nil` draws the plain line. No default, for the reason ``rowActions`` has none.
    let onGoToFolder: ((String) -> Void)?
    /// Opens the file pane: the folder menu's Show All, past its first subfolders. `nil` lists
    /// only those.
    var onOpenFilePane: (() -> Void)? = nil
    /// What each file row's context menu does (``EditorRailRowMenu``). Every act takes the row's
    /// path, which is not necessarily the open document's. No default, so every construction site
    /// says what its menu does rather than shipping a menu wired to nothing.
    let rowActions: EditorRailRowActions
    /// The fold button at the end of the line under the tabs: the list folds into the file pane's
    /// strip, where a button per tab brings it back. `nil` draws none (previews and probes). On
    /// that line, not beside the tabs, which span the rail with 5pt to spare at the largest text
    /// size (`theRailTabsFitTheRailAtEveryTextSize`).
    var onFold: (() -> Void)? = nil
    /// Search inside files: the filter's Names | Contents switch and the Contents results
    /// (``EditorRailContentSearch``). `nil` draws the name filter alone.
    var contentSearch: EditorRailContentSearch? = nil

    /// The rail row's one outline, used by both the hit shape and the hover wash. `roundedRect(7)`
    /// is the `.row` default; naming it lets the `.filled` arm, which defaults to a capsule, match.
    static let rowShape = HoverAffordanceShape.roundedRect(7)
    static var rowOutline: HoverAffordanceOutline { HoverAffordanceOutline(kind: rowShape) }

    /// The fold button's tooltip and VoiceOver label (``EditorRailTab/hideListTitle``).
    static let foldTitle = EditorRailTab.hideListTitle

    /// The rail's width: the side-column width the host's drag sets, at least
    /// ``EditorLayoutMetrics/railWidth``, the default for every site that doesn't drag.
    var width: CGFloat = EditorLayoutMetrics.railWidth

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Files list's keyboard focus, and the row its cursor is on (``EditorRailKeyboard``).
    /// `nil` puts the cursor on the open row until an arrow moves it.
    @FocusState private var filesFocused: Bool
    @State private var keyedPath: String?

    /// Grid or list for the Pages tab: one choice for every PDF, kept across launches.
    @AppStorage("editorPDFPagesLayout") private var pagesLayout: EditorPDFPagesLayout = .grid

    /// The tab drawn: the one chosen, unless it isn't offered (Pages with no PDF open, Outline on a
    /// PDF without contents or a non-Markdown text file).
    /// See ``EditorRailTab/resolved(_:pdfIsOpen:pdfHasOutline:markdownIsOpen:)``.
    var shownTab: EditorRailTab {
        EditorRailTab.resolved(tab, pdfIsOpen: pdf != nil, pdfHasOutline: pdfHasOutline,
                               markdownIsOpen: markdownIsOpen)
    }

    /// Whether the open PDF's bookmarks earn the Outline tab.
    private var pdfHasOutline: Bool { EditorRailTab.pdfOutlineIsWorthATab(pdf?.outline ?? []) }

    /// The tab bar's selection: it reads the drawn tab and writes the chosen one, so a click on the
    /// tab drawn in place of a remembered one is still a write, and the lens sits on what is drawn.
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
                             accentFill: accentFill, onAccent: onAccent)
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
        // `initial: true` is the whole ⌘N-from-another-workspace path: ⌘N sets `isNaming` before
        // this view exists. Only the tab is handled here; the prefill and focus travel with
        // ``EditorNamingRow``, which the document column also draws.
        .onChange(of: isNaming, initial: true) { _, naming in
            guard naming else { return }
            // The naming row is drawn on the Files tab, so ⌘N with Outline showing switches to it.
            tab = .files
        }
        .onChange(of: namingFocus) { _, _ in
            guard isNaming else { return }
            tab = .files
        }
    }

    /// The line under the tabs: which folder these files are in, or which document this outline
    /// belongs to. The tab names the kind of thing and this line names the thing, with the whole
    /// width to itself. Present on every tab, so switching tabs never moves the list under it.
    private var contextRow: some View {
        HStack(spacing: 5) {
            if shownTab == .files {
                // The folder's name is also the way out of it: a menu up the tree and down into
                // the folders inside, which moves the pane (``EditorFolderTrail``).
                EditorRailFolderMenu(name: contextName, trail: folderTrail, accent: accent,
                                     onGoTo: onGoToFolder, onShowAll: onOpenFilePane)
            } else {
                // The tooltip is on the name, not the row: on Files the row's buttons have their
                // own, and a row-wide one would show the ＋'s sentence over the folder's name.
                HStack(spacing: 5) {
                    Image(systemName: pdf == nil ? "doc.text" : "doc.richtext")
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(contextName)
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(contextHelp)
            }
            Spacer(minLength: 0)
            if shownTab == .files {
                // Frosted and Clear: Filter and ＋ share one glass capsule, as Finder groups related
                // buttons (`ChromeGlass`). The row's own 5pt, so Solid's layout is untouched.
                HStack(spacing: 5) {
                    // Revealed, not always shown, like every search in this app: a permanent
                    // field would spend a row of the narrow rail on a control most sessions skip.
                    Button {
                        // `withDesignAnimation`, not a bare `withAnimation`: the reveal is a width
                        // change, which Reduce Motion turns off. A Design scan enforces this.
                        withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) {
                            filterIsExpanded.toggle()
                        }
                        if !filterIsExpanded { filter = "" }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .scaledFont(.system(size: 11, weight: .semibold))
                            // Greyed when disabled, as the header ＋ is: `.disabled` alone leaves a
                            // `.glyph` button drawn at full strength, looking pressable.
                            .foregroundStyle(filterIsOffered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.hoverAffordance(filterIsExpanded ? .filled : .glyph, tint: accent))
                    .accessibilityLabel("Filter files")
                    .help(contentSearch == nil ? "Filter this list by name"
                                               : "Filter this list by name, or search inside the files")
                    .disabled(!filterIsOffered)
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
        // A floor, not a height: the tabs put 18pt buttons or an 11pt line here, and without it
        // the list would step on every tab click. A floor so the row still grows with text size.
        .frame(minHeight: 18)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// The Pages and Outline tabs' name-line tooltip: what the tab lists. Files has none: its
    /// folder name is a menu with its own tooltip, and the ＋ names where it makes a file.
    private var contextHelp: String {
        switch shownTab {
        case .files: return ""
        case .pages: return "The pages of the open PDF"
        case .outline: return pdf == nil ? "The headings in the open document" : "The bookmarks in the open PDF"
        }
    }

    /// What the context line names: the folder, or the open file. The "nothing here yet" cases
    /// say so rather than go blank, which is what a first run sees.
    private var contextName: String {
        switch shownTab {
        case .files:
            return folderName.isEmpty ? "No folder selected" : folderName
        case .pages, .outline:
            guard let selectedPath, !selectedPath.isEmpty else { return "No file open" }
            return (selectedPath as NSString).lastPathComponent
        }
    }

    /// Whether the filter can be opened: there are rows to filter, or, where it can search inside
    /// files, subfolders to search. A folder of only folders lists no rows but is worth searching.
    var filterIsOffered: Bool {
        Self.filterIsOffered(hasEntries: !entries.isEmpty, searchesContents: contentSearch != nil,
                             hasSubfolders: !(folderTrail?.subfolders.isEmpty ?? true))
    }

    static func filterIsOffered(hasEntries: Bool, searchesContents: Bool, hasSubfolders: Bool) -> Bool {
        hasEntries || (searchesContents && hasSubfolders)
    }

    /// Where ＋ would put a new file, in the tooltip's words, since it writes to a folder the user
    /// may not be looking at. The header's ＋ says the same sentence: one act, one name.
    private var newFileDestination: String {
        EditorWorkspaceView.newTextFileTitle(folderName: newFileFolderName ?? folderName)
    }

    /// The folder's files: the naming row, the filter field, and the list, a Text Files section and
    /// a PDFs section, each left out when empty (``EditorRail/sections(_:)``).
    ///
    /// The naming row sits above the sections, so ⌘N in a folder of only PDFs still opens one, and
    /// outside the scroll view, so a row being typed into can't scroll away.
    @ViewBuilder
    private var filesSection: some View {
        if isNaming {
            EditorNamingRow(isNaming: $isNaming, typedName: $typedName, namingFocus: namingFocus,
                            accent: accent, prefilledName: prefilledName, refusal: refusal,
                            // Named only when it is not the folder on the line above.
                            onCreate: onCreate, folderName: newFileFolderName)
        }
        if filterIsExpanded {
            Group {
                if let contentSearch {
                    // With the Names | Contents switch under the field. ↩ on Names is the rail's
                    // own, below.
                    EditorRailFilterField(model: contentSearch.model, search: contentSearch,
                                          filter: $filter, isExpanded: $filterIsExpanded,
                                          accentFill: accentFill, onAccent: onAccent,
                                          onSubmitNames: openFirstMatch)
                } else {
                    ExpandingSearchField(text: $filter, isExpanded: $filterIsExpanded,
                                         placeholder: EditorRailFilterScope.names.placeholder)
                        .onSubmit(openFirstMatch)
                }
            }
            .scaledFont(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        // The switch decides only while the field shows: a folded filter is no filter, and the
        // list is the folder's again.
        if let contentSearch, filterIsExpanded {
            EditorRailContentSwitch(model: contentSearch.model, search: contentSearch, folderName: folderName,
                                    query: filter, accent: accent, selectedPath: selectedPath,
                                    rowActions: rowActions) {
                namesList
            }
        } else {
            namesList
        }
    }

    /// ↩ in the filter opens the first match, and hands the keys to the list so ↓ goes on from
    /// there.
    private func openFirstMatch() {
        guard let first = Self.firstMatch(entries, filter: filter) else { return }
        keyedPath = first.path
        filesFocused = true
        onOpen(first)
    }

    /// The folder's rows, filtered by name, or the caption standing where they would be.
    @ViewBuilder
    private var namesList: some View {
        let shown = EditorRail.filtered(entries, matching: filter)
        // In drawn order, section by section, which is the order the arrows walk.
        let order = EditorRail.sections(shown).flatMap(\.rows)
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
                // Space: Quick Look on the cursor's row, as in Browse; again on that row closes it.
                .onKeyPress(keys: [.space], phases: .down) { press in
                    guard press.isPlainKeystroke, let path = keyedPath ?? selectedPath,
                          order.contains(where: { $0.path == path }) else { return .ignored }
                    rowActions.quickLook(path)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard let onReturnKeys else { return .ignored }
                    onReturnKeys()
                    return .handled
                }
            }
        }
    }

    /// The row ↩ in the filter opens: the first one drawn, or `nil` when nothing matches.
    static func firstMatch(_ entries: [EditorRailEntry], filter: String) -> EditorRailEntry? {
        EditorRail.sections(EditorRail.filtered(entries, matching: filter)).first?.rows.first
    }

    /// A section's heading (Text Files, PDFs) in the sidebar's section-heading style.
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
    /// Its own tab, with the whole card, rather than a capped section under the files with a
    /// scroller inside a scroller. Note and PDF outlines share one list design, with the same scroll
    /// memory and current-row mark: a PDF's bookmarks arrive as the same row type
    /// (``EditorPDFOutline/rows(_:)``).
    @ViewBuilder
    private var outlineSection: some View {
        if let pdf {
            EditorPDFRailOutline(pdf: pdf, view: pdf.view, outlineAnchors: $outlineAnchors, accent: accent)
        } else {
            EditorRailOutlineList(rows: outline, currentIndex: currentOutlineIndex, path: selectedPath,
                                  emptyCaption: Self.outlineEmptyCaption,
                                  outlineAnchors: $outlineAnchors, accent: accent,
                                  onSelect: onSelectHeading, onEscape: onReturnKeys)
                // One list per document (`EditorRailOutlineList`'s `topRow`).
                .id(selectedPath)
        }
    }

    /// What the outline says when it has no rows. The tab is offered only while a Markdown note is
    /// open, so an empty list is always a note with no headings yet, and the caption says how to
    /// make one.
    static let outlineEmptyCaption = "No headings in this document. A line starting with # makes one."

    /// The step each outline level is indented by. Half the preview's, because the rail is narrow
    /// and the words are what matter here.
    static let outlineIndentStep: CGFloat = 10

    /// One outline row, for the test that measures a drawn row against the height estimate. A seam,
    /// not a replica, so the test measures this builder rather than its own copy.
    static func outlineRowProbe(_ entry: MarkdownOutlineEntry, isCurrent: Bool) -> some View {
        EditorRailOutlineList.probe.row(entry, isCurrent: isCurrent)
    }

    /// What the rail says when it lists nothing, as a function so the cases are testable, like
    /// `PaneColumnsView.emptyCaption`: no folder chosen, a filter that matched nothing, an empty
    /// folder, and a folder full of files Edit doesn't open. The last must not read like an empty
    /// folder, so it says the files are there, then that the + button makes a text file.
    ///
    /// - Parameter otherFiles: how many files the folder holds that the rail won't list, or `nil`
    ///   when nothing counted them. `nil` and `0` are treated alike on purpose
    ///   (``EditorRail/Survey/otherFileCount``).
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
        // Two sentences, not one pluralised template, which would say "None of the 1 file"; a
        // folder holding one file is ordinary.
        if otherFiles == 1 {
            return "The one file in this folder isn’t one Edit opens. "
                + "The + button makes a text file."
        }
        return "None of the \(otherFiles.formatted()) files in this folder are ones Edit opens. "
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

    /// The colour of a row's leading dot, or `nil` for no dot. Only the open row can have one: the
    /// status is document-wide, and resolving it per row would mark the whole folder unsaved. A
    /// function so that is testable; a one-file folder's screenshot can't show it.
    static func dotColour(rowPath: String, selectedPath: String?,
                          status: EditorSaveStatus?, accent: Color) -> Color? {
        guard rowPath == selectedPath, let status, status.showsDot else { return nil }
        return status.isWarning ? .orange : accent
    }

    /// The width the dot's column always occupies, dot or no dot. Reserved, not inserted, because
    /// the dot comes and goes as you type, and would shove every name sideways (as BBEdit avoids).
    ///
    /// **The reservation is the unconditional `Circle` below, not this number:** a clear fill still
    /// takes part in layout, and an `if let` around the shape would not. No test can catch that
    /// tidy-up, since the rail's frame and the row's height hide it.
    static let dotColumnWidth: CGFloat = 9

    private func row(_ entry: EditorRailEntry) -> some View {
        let isSelected = entry.path == selectedPath
        let isKeyed = filesFocused && entry.path == (keyedPath ?? selectedPath)
        let dot = Self.dotColour(rowPath: entry.path, selectedPath: selectedPath,
                                 status: documentStatus, accent: accent)
        return Button {
            // A click opens and leaves the keys where they were: taking them to the list would make
            // typing beep and ⌘Z undo a file operation (`EditorUndoRouting`). The cursor still moves,
            // for Tab or ↩ in the filter, which do hand the list the keys.
            keyedPath = entry.path
            onOpen(entry)
        } label: {
            HStack(spacing: 6) {
                // The unsaved marker, before the icon as in BBEdit, so it reads as a column rather
                // than punctuation inside the names.
                Circle()
                    .fill(dot ?? .clear)
                    .frame(width: 5, height: 5)
                    .frame(width: Self.dotColumnWidth, alignment: .leading)
                    .accessibilityHidden(dot == nil)
                    .accessibilityLabel(documentStatus?.dotName ?? "")
                Image(systemName: Self.rowSymbol(entry.kind))
                    .scaledFont(.system(size: 11))
                Text(entry.name)
                    .scaledFont(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                // Formatted when the rows were listed, off the main actor
                // (``EditorRailEntry/sizeCaption``).
                Text(entry.sizeCaption)
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            // A dim row keeps full opacity when selected: a row that answered a click with a
            // caption shouldn't also be hard to read.
            .opacity(entry.isDimmed && !isSelected ? 0.5 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Self.rowOutline)
            .background { EditorRailKeyedRowMark(isOn: isKeyed && !isSelected, accent: accent) }
        }
        // `.row`, the variant for a full-width list row, with a quieter wash. Not `.inline`, which
        // is for a dismiss glyph: it washes in ink and its default circle would draw a grey disc
        // mid-row. The shape is passed to both arms, since `.filled` defaults to a capsule; one
        // value for the style and `contentShape` (`HoverAffordanceOutline`).
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .row,
                                      tint: accent, shape: Self.rowShape))
        .help(entry.dimmedReason ?? entry.name)
        // On every row, dim ones included: a file the editor refuses is the one most worth
        // revealing or inspecting (``EditorRailRowMenu``). The path is the row's, never
        // `selectedPath`.
        .contextMenu { EditorRailRowMenu(path: entry.path, isCloudOnly: entry.isCloudOnly, actions: rowActions) }
    }
}
