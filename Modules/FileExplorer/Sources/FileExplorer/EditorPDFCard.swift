import AppKit
import PDFKit
import SwiftUI
import Design
import Sync

/// The PDF header's own controls, at the end of the name row: Find, the page field, the zoom and
/// the layout (mockups 15 and 16).
///
/// **Its own view, observing the view state alone**, so a page turn re-renders this and the status
/// line and nothing else in the header — see ``EditorPDFDocument``'s split.
///
/// **Fit Page, Fit Width and Actual Size live in the zoom's menu**, where the Page / Width / Actual
/// capsule used to sit beside it: the room it gave back is where Fill & Sign goes (Phase 5b).
struct EditorPDFHeaderControls: View {
    @ObservedObject var state: EditorPDFViewState
    /// Not observed: the Find button only acts on it.
    let find: EditorPDFFind
    let pageCount: Int
    let accent: Color
    /// How many words the controls draw — the header's row picks it (``EditorPDFHeader``).
    var rung: Rung = .worded
    @State private var typedPage = ""
    @FocusState private var pageFieldFocused: Bool
    /// Where the zoom's and the layout's menus open from.
    private let zoomAnchor = EditorHeadingMenuAnchor()
    private let layoutAnchor = EditorHeadingMenuAnchor()

    /// **What the controls shed as the column narrows, in the order it goes** (decided
    /// 2026-10-17): "of 64" first — the status line says it too — then the zoom's label, which
    /// becomes a glyph with the fit or the percentage kept in its tooltip and on the status line,
    /// then − and +, leaving the zoom one glyph that opens its menu (Zoom In and Zoom Out are
    /// there, and on ⌘+ and ⌘−). Fill & Sign (Phase 5b) sheds its word too.
    ///
    /// The last rung is what the narrowest column gets, and `EditorPDFHeaderWidthTests` holds it
    /// to the column at the smallest window with room left for the name.
    enum Rung: CaseIterable {
        case worded
        case noPageCount
        case glyphZoom
        case zoomMenuOnly

        var showsPageCount: Bool { self == .worded }
        var wordsTheZoom: Bool { self == .worded || self == .noPageCount }
        var showsZoomSteps: Bool { self != .zoomMenuOnly }
    }

    var body: some View {
        HStack(spacing: 6) {
            if pageCount > 0 {
                findButton
                pageField
                zoom
                layoutButton
            }
        }
    }

    /// Find — the text header's magnifying glass, for the PDF's own find bar (⌘F).
    private var findButton: some View {
        Button { find.show() } label: {
            Image(systemName: "magnifyingglass")
                .scaledFont(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .accessibilityLabel("Find in this PDF")
        .help(ShortcutHint.tooltip("Find in this PDF", AppChord.findInPane.display))
    }

    /// "2 of 3", the number a field: type a page and Return. In a two-page layout it shows the
    /// spread, "6–7 of 64", and a page typed there goes to the spread that holds it.
    private var pageField: some View {
        HStack(spacing: 4) {
            TextField("", text: $typedPage)
                .textFieldStyle(.roundedBorder)
                // Small, so the field is no taller than the zoom track beside it.
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: EditorPDFHeaderControls.fieldWidth(pageCount: pageCount, twoUp: state.layout.isTwoUp))
                .focused($pageFieldFocused)
                .onSubmit { go() }
                .accessibilityLabel(state.layout.isTwoUp ? "Pages" : "Page")
            if rung.showsPageCount {
                Text("of \(pageCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .scaledFont(.system(size: 10))
        .onAppear { typedPage = Self.pageText(state.visiblePages) }
        .onChange(of: state.visiblePages) { _, pages in
            if !pageFieldFocused { typedPage = Self.pageText(pages) }
        }
        .onChange(of: pageFieldFocused) { _, focused in
            if !focused { typedPage = Self.pageText(state.visiblePages) }
        }
        // Text ▸ Go to Page… ⌃⌘L puts the caret in this field.
        .onChange(of: state.pageFieldRequest) { _, _ in pageFieldFocused = true }
    }

    /// What the field says: "7", or "6–7" for a spread — one-based, as the reader counts.
    static func pageText(_ pages: ClosedRange<Int>) -> String {
        pages.count == 1 ? String(pages.lowerBound + 1) : "\(pages.lowerBound + 1)–\(pages.upperBound + 1)"
    }

    /// Wide enough for the longest number this document has — or two of them and a dash, in a
    /// two-page layout — and no wider.
    static func fieldWidth(pageCount: Int, twoUp: Bool = false) -> CGFloat {
        let digits = max(String(pageCount).count, 2)
        return CGFloat(twoUp ? 2 * digits + 1 : digits) * 8 + 14
    }

    private func go() {
        guard let page = EditorPDFHeaderControls.page(typed: typedPage, pageCount: pageCount) else {
            typedPage = Self.pageText(state.visiblePages)
            return
        }
        state.requestPage(page)
        pageFieldFocused = false
    }

    /// The zero-based page a typed number names, clamped into the document; `nil` for no number.
    /// The FIRST number counts, so a spread's own "6–7" sent back unchanged goes to 6 — the spread
    /// it already is.
    static func page(typed: String, pageCount: Int) -> Int? {
        let digits = typed.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard pageCount > 0, let number = Int(digits) else { return nil }
        return min(max(number, 1), pageCount) - 1
    }

    /// − and + step the ladder; the label between them opens the zoom menu (mockup 15).
    private var zoom: some View {
        HStack(spacing: 2) {
            if rung.showsZoomSteps {
                glyphButton("minus", label: "Zoom out") { state.zoom(in: false) }
                    .disabled(!state.canZoom(in: false))
            }
            Button { Self.present(EditorPDFZoomMenu.menu(for: state), from: zoomAnchor.view) } label: {
                HStack(spacing: 3) {
                    if rung.wordsTheZoom {
                        Text(EditorPDFZoom.label(fit: state.fit, scale: state.scale))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    Image(systemName: "chevron.down")
                        .scaledFont(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .scaledFont(.system(size: 10, weight: .medium))
                .padding(.horizontal, 4)
                .frame(minWidth: rung.wordsTheZoom ? 40 : nil, minHeight: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: accent))
            .background(EditorHeadingMenuAnchor.Probe(anchor: zoomAnchor))
            .accessibilityLabel("Zoom")
            .accessibilityValue(EditorPDFZoom.label(fit: state.fit, scale: state.scale))
            .help("Zoom: \(EditorPDFZoom.label(fit: state.fit, scale: state.scale)) — Fit Page, Fit Width, Actual Size and the presets")
            if rung.showsZoomSteps {
                glyphButton("plus", label: "Zoom in") { state.zoom(in: true) }
                    .disabled(!state.canZoom(in: true))
            }
        }
        .padding(.horizontal, 2)
        .chromeGlassTrack()
    }

    /// The layouts' menu (mockup 16), its glyph the layout in use.
    private var layoutButton: some View {
        Button { Self.present(EditorPDFLayoutMenu.menu(for: state), from: layoutAnchor.view) } label: {
            Image(systemName: EditorPDFLayoutMenu.symbol(state.layout))
                .scaledFont(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .background(EditorHeadingMenuAnchor.Probe(anchor: layoutAnchor))
        .accessibilityLabel("Page layout")
        .accessibilityValue(state.layout.caption(coverSeparately: state.coverSeparately))
        .help("Page layout — \(state.layout.caption(coverSeparately: state.coverSeparately))")
    }

    /// Opens `menu` under `view`, as a pull-down would — AppKit moves it up at the foot of the screen.
    private static func present(_ menu: NSMenu, from view: NSView?) {
        guard let view else { return }
        let below = view.isFlipped ? NSPoint(x: 0, y: view.bounds.maxY + 2) : NSPoint(x: 0, y: -2)
        menu.popUp(positioning: nil, at: below, in: view)
    }

    private func glyphButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .accessibilityLabel(label)
        .help(label)
    }
}

/// **The zoom's menu** (mockup 15) — built when the label is pressed, from the state as it stands,
/// as ``EditorHeadingMenu`` builds its own.
///
/// **An `NSMenu` rather than a SwiftUI `Menu`, for the shortcuts.** Zoom In, Zoom Out and Actual
/// Size show ⌘+, ⌘− and ⌘0 here, and a SwiftUI `Menu` can only show a shortcut by registering it
/// — which would put a second ⌘+ in the window, answered before the menu bar's, whatever had the
/// keyboard. This menu exists only while it is open, so its key equivalents are labels. The keys
/// themselves are the menu bar's: View ▸ Text Size routes them to the PDF while the pages have
/// the keyboard.
@MainActor
enum EditorPDFZoomMenu {
    static func menu(for state: EditorPDFViewState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ chord: AppChord? = nil, on: Bool = false, enabled: Bool = true,
                  _ act: @escaping () -> Void) {
            let item = EditorClosureMenuItem(title: title, act: act)
            if let chord {
                item.keyEquivalent = String(chord.key.character)
                item.keyEquivalentModifierMask = .command
            }
            item.state = on ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }
        item("Zoom In", AppChord.textBigger, enabled: state.canZoom(in: true)) { state.zoom(in: true) }
        item("Zoom Out", AppChord.textSmaller, enabled: state.canZoom(in: false)) { state.zoom(in: false) }
        item(EditorPDFFit.actual.title, AppChord.textDefaultSize) { state.fit = .actual }
        menu.addItem(.separator())
        for fit in [EditorPDFFit.page, .width] {
            item(fit.title, on: state.fit == fit) { state.fit = fit }
        }
        menu.addItem(.separator())
        let ticked = EditorPDFZoom.tickedPreset(fit: state.fit, scale: state.scale)
        for preset in EditorPDFZoom.presets {
            item(EditorPDFZoom.percent(preset), on: preset == ticked) { state.zoom(to: preset) }
        }
        return menu
    }
}

/// **The layouts' menu** (mockup 16): the four layouts, the one in use ticked, and Cover Page
/// Separately — greyed in the single-page layouts, where there is no spread for it to change, and
/// kept as it was for when two pages come back.
@MainActor
enum EditorPDFLayoutMenu {
    static let coverTitle = "Cover Page Separately"

    static func menu(for state: EditorPDFViewState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for layout in EditorPDFLayout.allCases {
            let item = EditorClosureMenuItem(title: layout.title) { state.layout = layout }
            item.state = state.layout == layout ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let cover = EditorClosureMenuItem(title: coverTitle) { state.coverSeparately.toggle() }
        cover.state = state.coverSeparately ? .on : .off
        cover.isEnabled = state.layout.isTwoUp
        menu.addItem(cover)
        return menu
    }

    /// The button's glyph: the layout in use, drawn.
    static func symbol(_ layout: EditorPDFLayout) -> String {
        switch layout {
        case .singlePage: return "rectangle.portrait"
        case .continuous: return "rectangle.grid.1x2"
        case .twoPages: return "rectangle.split.2x1"
        case .twoPagesContinuous: return "rectangle.grid.2x2"
        }
    }
}

/// Under the PDF header: the pages, or the state that stands in for them (mockup 5).
struct EditorPDFBody: View {
    @ObservedObject var pdf: EditorPDFDocument
    let accent: Color
    /// The one Quick Look panel every other surface shares — the host's.
    let quickLook: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorPDFToolBannerView(tools: pdf.tools, accent: accent)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pdf.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .open:
            EditorPDFReader(document: pdf.document, state: pdf.view, find: pdf.find)
        case .locked:
            EditorPDFUnlockView(pdf: pdf, accent: accent)
        case .refused(let reason):
            refused(reason)
        }
    }

    @ViewBuilder
    private func refused(_ reason: String) -> some View {
        if reason == EditorPDFDocument.unreadableReason, let path = pdf.path {
            EditorPDFStateCard(symbol: "exclamationmark.triangle", title: reason,
                               message: "“\(pdf.name)” may be damaged or not really a PDF. Quick Look or Preview may still open it.") {
                HStack(spacing: 8) {
                    Button { quickLook(path) } label: { Label("Quick Look", systemImage: "eye") }
                    Button("Open in Preview") { EditorPDFBody.openInPreview(path) }
                }
                .controlSize(.small)
            }
        } else {
            EditorPDFStateCard(symbol: reason == EditorPDFDocument.notDownloadedReason ? "icloud" : "doc",
                               title: reason, message: nil) { EmptyView() }
        }
    }

    /// Hands the file to Preview, the app that reads more PDFs than PDFKit alone admits to.
    static func openInPreview(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// A state that fills the document card: a symbol, a sentence, and what can be done about it.
struct EditorPDFStateCard<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .scaledFont(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .scaledFont(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .frame(maxWidth: 280)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// **The password field for a locked PDF.** What is typed is handed to `unlock(password:)` and
/// cleared from the field whichever way the attempt goes — it is never stored or logged.
struct EditorPDFUnlockView: View {
    @ObservedObject var pdf: EditorPDFDocument
    let accent: Color
    @State private var password = ""
    @State private var rejected = false
    @State private var isTrying = false
    @FocusState private var focused: Bool

    var body: some View {
        EditorPDFStateCard(symbol: "lock", title: "This PDF needs a password",
                           message: rejected ? "That password didn't open it. Try again."
                                             : "SyncCloud uses it only to open the file and doesn't save it.") {
            HStack(spacing: 6) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .focused($focused)
                    .onSubmit(attempt)
                // No `.keyboardShortcut(.defaultAction)`: a bare Return registered on an always-mounted
                // surface takes it from every sheet (`BareKeyEquivalentScanTests`). The field's
                // `onSubmit` is Return here.
                Button("Unlock", action: attempt)
                    .disabled(password.isEmpty || isTrying)
            }
            .controlSize(.small)
        }
        .onAppear { focused = true }
    }

    private func attempt() {
        guard !password.isEmpty, !isTrying else { return }
        let typed = password
        password = ""
        isTrying = true
        Task {
            let opened = await pdf.unlock(password: typed)
            isTrying = false
            rejected = !opened
        }
    }
}

/// **The status line for a PDF** — page, paper, size, version, and whether there is text to select.
/// Its own view rather than ``EditorStatusLine`` bent to fit: that one's fields are counts, a caret
/// and an encoding, none of which a PDF has.
struct EditorPDFStatusLine: View {
    @ObservedObject var state: EditorPDFViewState
    let facts: EditorPDFFacts

    var body: some View {
        let segments = EditorPDFStatusLine.segments(facts: facts, pages: state.visiblePages,
                                                    layout: state.layout, coverSeparately: state.coverSeparately,
                                                    zoom: EditorPDFZoom.label(fit: state.fit, scale: state.scale))
        ViewThatFits(in: .horizontal) {
            row(segments)
            row(Array(segments.prefix(2)))
            row(Array(segments.prefix(1)))
        }
        .scaledFont(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func row(_ segments: [String]) -> some View {
        HStack(spacing: 14) {
            ForEach(segments, id: \.self) { Text($0) }
            Spacer(minLength: 0)
        }
    }

    /// The line's segments, most worth keeping first — the order a narrow column drops them in:
    /// where the reader is ("Pages 6–7 of 64" in a spread), the layout, the zoom (mockup 15 — and
    /// where it is still said once the header's zoom has shed its word), then the paper of the
    /// first page on screen and the file's facts.
    static func segments(facts: EditorPDFFacts, pages: ClosedRange<Int>, layout: EditorPDFLayout = .continuous,
                         coverSeparately: Bool = false, zoom: String? = nil) -> [String] {
        let last = max(facts.pageCount - 1, 0)
        let first = min(pages.lowerBound, last), through = min(pages.upperBound, last)
        var out = [first == through ? "Page \(first + 1) of \(facts.pageCount)"
                                    : "Pages \(first + 1)–\(through + 1) of \(facts.pageCount)"]
        out.append(layout.caption(coverSeparately: coverSeparately))
        if let zoom { out.append(zoom) }
        if let paper = facts.paperCaption(page: first) { out.append(paper) }
        if let size = facts.fileSize { out.append(size) }
        out.append(facts.versionCaption)
        out.append(facts.textCaption)
        return out
    }
}

/// **The header for a PDF** — mockup 4: the same two rows in the same places as a text file's, with
/// "PDF" and a Read only tag where the kind and the Autosave switch sit, and the page controls
/// where the mode capsule sits. **No ＋, no format bar, no Go to Line, no save word**: nothing here
/// writes. Find opens the PDF's own find bar (``EditorPDFFindBar``), not the text one.
///
/// **The Tools menu does not change "Read only"**: every tool writes a NEW copy beside the file, so
/// the file on screen is as unwritten after a run as before it.
///
/// The Expand button is the workspace's own view, handed in. The × is drawn here with the text
/// header's modifiers and its accessibility label, calling the same host close.
///
/// **No location line** — the text header's "in Finance" or "iCloud › Documents › …" crumbs are
/// not drawn here (asked 2026-10-17: "it doesn't make sense"). A PDF's second row says only what
/// it is; the name's right-click Reveal in Browse is the way to where it lives.
struct EditorPDFHeader<Trailing: View>: View {
    @ObservedObject var pdf: EditorPDFDocument
    let accent: Color
    let onAccent: Color
    let onRevealInBrowse: (String) -> Void
    let onClose: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            nameRow
            metaRow
        }
    }

    /// **The name row, and which words it draws: the name decides** — the text header's rule
    /// (``EditorWorkspaceView``'s `nameRow`). `ViewThatFits` asks each rung for its IDEAL width,
    /// which is the name at full length, so the controls keep a word only while the WHOLE name fits
    /// beside it; the last rung is laid out in the width there is, and the name truncates there if
    /// it still must.
    private var nameRow: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(EditorPDFHeaderControls.Rung.allCases, id: \.self) { rung in
                nameRow(rung)
            }
        }
    }

    func nameRow(_ rung: EditorPDFHeaderControls.Rung) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: EditorWorkspaceView.dotColumnWidth, height: 1)
            Text(pdf.name)
                .scaledFont(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .contextMenu {
                    if let path = pdf.path {
                        Button(action: { onRevealInBrowse(path) }) {
                            Label("Reveal in Browse", systemImage: "folder")
                        }
                    }
                }
            Spacer(minLength: 0)
            if pdf.phase == .open {
                EditorPDFHeaderControls(state: pdf.view, find: pdf.find, pageCount: pdf.facts?.pageCount ?? 0,
                                        accent: accent, rung: rung)
            }
            // Locked too: Remove Password is the one tool a file locked to open can take.
            if pdf.phase == .open || pdf.phase == .locked {
                EditorPDFToolsMenu(tools: pdf.tools, accent: accent)
            }
            trailing
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .chromeGlassGlyphButton(tint: accent, outset: ChromeGlass.smallGlyphOutset)
            .chromeGlassClearance(.leading, rowSpacing: 6)
            .accessibilityLabel(EditorWorkspaceView.closeTitle(name: pdf.name))
            .help("Close this document")
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: EditorWorkspaceView.dotColumnWidth, height: 1)
            Text("PDF").layoutPriority(1).lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Text(EditorPDFHeader.readOnlyTag)
                .scaledFont(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(.tertiary))
                .fixedSize()
                .help("PDFs open read-only in Edit — nothing here writes to the file")
            Spacer(minLength: 8)
        }
        .scaledFont(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    static var readOnlyTag: String { "Read only" }
}
