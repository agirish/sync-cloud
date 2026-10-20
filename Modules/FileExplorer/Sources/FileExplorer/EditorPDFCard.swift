import AppKit
import PDFKit
import SwiftUI
import Design
import Sync

/// **The PDF header's file actions** — Find, Fill & Sign and Tools ▾, at the end of the name row
/// before the divider (Phase 6a, mockup C). Moving around the page — the page field, the zoom and
/// the layout — is the floating capsule's now (``EditorPDFCapsule``), so the header holds the file
/// and what acts on it, and nothing that moves on a page turn.
///
/// **One button style for the three** (``EditorPDFActionStyle``): a bezel, kept when the word goes,
/// so the actions read as one group however narrow the column. Expand and × after the divider stay
/// plain glyphs — they are about the window, not the file.
struct EditorPDFHeaderControls: View {
    let find: EditorPDFFind
    let fill: EditorPDFFillSign
    let tools: EditorPDFTools
    /// Find and Fill & Sign: an open PDF with pages to act on.
    var showsReaderActions: Bool
    /// Tools: open, or locked — Remove Password is the one tool a file locked to open can take.
    var showsTools: Bool
    let accent: Color
    let onAccent: Color
    /// How many words the actions draw — the header's row picks it (``EditorPDFHeader``).
    var rung: Rung = .worded

    /// **What sheds as the column narrows, in the order it goes** (decided 2026-10-19): Find and
    /// Tools lose their words first, then Fill & Sign, the longest word and the one with no
    /// magnifier or wrench everybody already reads — and only after all three does the name
    /// truncate, in the middle, on the last rung.
    ///
    /// The last rung is what the narrowest column gets, and `EditorPDFHeaderWidthTests` pins what
    /// it leaves the name in the column at the smallest window.
    enum Rung: CaseIterable {
        case worded
        case fillAndSignWorded
        case glyphs

        var wordsFindAndTools: Bool { self == .worded }
        var wordsFillAndSign: Bool { self != .glyphs }
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsReaderActions {
                EditorPDFFindButton(find: find, accent: accent, onAccent: onAccent, worded: rung.wordsFindAndTools)
                EditorPDFFillSignButton(fill: fill, accent: accent, onAccent: onAccent, worded: rung.wordsFillAndSign)
                    .chromeGlassClearance(.leading, rowSpacing: 6)
            }
            if showsTools {
                EditorPDFToolsMenu(tools: tools, accent: accent, onAccent: onAccent, worded: rung.wordsFindAndTools)
                    .chromeGlassClearance(showsReaderActions ? .leading : [], rowSpacing: 6)
            }
        }
    }
}

/// **A file action's label**: its glyph, its word while the rung keeps it, and Tools' chevron —
/// lit in the accent while what it opens is up.
struct EditorPDFActionLabel: View {
    let symbol: String
    var word: String?
    var chevron = false
    var isOn = false
    let accent: Color
    let onAccent: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .scaledFont(.system(size: 11, weight: .semibold))
            if let word {
                Text(word)
                    .scaledFont(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            if chevron {
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
        }
        .padding(.horizontal, word == nil ? 4 : 6)
        .frame(minWidth: 18)
        .frame(height: 18)
        .foregroundStyle(isOn ? AnyShapeStyle(onAccent) : AnyShapeStyle(.primary))
        .background(isOn ? accent : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
        .contentShape(RoundedRectangle(cornerRadius: Radius.chip))
    }
}

/// **The bezel the three file actions share** (decided 2026-10-19), on the button after its style,
/// as `ChromeGlass` asks: a rounded chip of the window's quaternary fill and a hairline at Solid,
/// and in Frosted and Clear the app's chrome glass in the same shape, grown to the header's other
/// buttons' height.
struct EditorPDFActionStyle: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .buttonStyle(.hoverAffordance(.segment, tint: accent, shape: .roundedRect(Radius.chip)))
            .background {
                ChromeGlassTodayGround {
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(.quaternary.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: Radius.chip)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                }
            }
            .chromeGlassGround(.roundedRect(Radius.chip), outset: ChromeGlass.smallGlyphOutset)
    }
}

/// Find — the PDF's own find card (⌘F), lit while it is up.
struct EditorPDFFindButton: View {
    @ObservedObject var find: EditorPDFFind
    let accent: Color
    let onAccent: Color
    var worded: Bool

    var body: some View {
        Button { find.show() } label: {
            EditorPDFActionLabel(symbol: "magnifyingglass", word: worded ? "Find" : nil, isOn: find.isShown,
                                 accent: accent, onAccent: onAccent)
        }
        .modifier(EditorPDFActionStyle(accent: accent))
        .accessibilityLabel("Find in this PDF")
        .help(ShortcutHint.tooltip("Find in this PDF", AppChord.findInPane.display))
    }
}

/// **The header's Fill & Sign button** — between Find and Tools (mockup C). It turns Fill & Sign's
/// palette and save pill over the canvas on and off (Phase 6b), and is lit while it is on.
struct EditorPDFFillSignButton: View {
    @ObservedObject var fill: EditorPDFFillSign
    let accent: Color
    let onAccent: Color
    var worded: Bool

    var body: some View {
        Button { fill.toggle() } label: {
            EditorPDFActionLabel(symbol: "signature", word: worded ? "Fill & Sign" : nil, isOn: fill.isOn,
                                 accent: accent, onAccent: onAccent)
        }
        .modifier(EditorPDFActionStyle(accent: accent))
        .accessibilityLabel("Fill & Sign")
        .accessibilityValue(fill.isOn ? "On" : "Off")
        .help(fill.refusal == nil
              ? (fill.isOn ? "Put Fill & Sign away" : "Fill & Sign — place text, dates, marks and signatures, then save a filled copy")
              : "Fill & Sign isn’t available. \(Self.sentence(fill.menuReason ?? "")) Click for why.")
    }
}

extension EditorPDFFillSignButton {
    /// `text` as a sentence of its own, ending in one full stop — the menu lines end in one or none.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }
}

/// **The zoom's menu** (mockup 15) — built when the label is pressed, from the state as it stands,
/// as ``EditorHeadingMenu`` builds its own. The top of the capsule's view menu
/// (``EditorPDFViewMenu``), as it was before there was a layout submenu under it.
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
/// kept as it was for when two pages come back. The view menu's Page Layout submenu
/// (``EditorPDFViewMenu``) since the layout button went.
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
}

/// **The capsule's view menu** (Phase 6a, mockup E): today's zoom menu unchanged
/// (``EditorPDFZoomMenu``), then after a separator Page Layout ▸ — the layouts' menu
/// (``EditorPDFLayoutMenu``), everything the layout button used to open, which is why the button
/// went. Zoom is reached for all the time and stays on top; a layout is set once and remembered,
/// so it sits one level down, in the row nearest the capsule when the menu opens upwards.
@MainActor
enum EditorPDFViewMenu {
    static let layoutTitle = "Page Layout"

    static func menu(for state: EditorPDFViewState) -> NSMenu {
        let menu = EditorPDFZoomMenu.menu(for: state)
        menu.addItem(.separator())
        let layout = NSMenuItem(title: layoutTitle, action: nil, keyEquivalent: "")
        layout.submenu = EditorPDFLayoutMenu.menu(for: state)
        menu.addItem(layout)
        return menu
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
            EditorPDFReader(document: pdf.document, state: pdf.view, find: pdf.find, fill: pdf.fill,
                            tools: pdf.tools, pageCount: pdf.facts?.pageCount ?? 0, accent: accent)
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
                               title: reason, message: Self.nextStep(for: reason)) { EmptyView() }
        }
    }

    /// **What to do next, under a refusal that would otherwise say only what happened.**
    static func nextStep(for reason: String) -> String? {
        switch reason {
        case EditorPDFDocument.notDownloadedReason:
            return "Select it in a file pane and choose File ▸ Download, or Download on its right-click menu there, then open it again."
        case EditorPDFDocument.goneReason:
            return "Find it in Browse and open it again from there."
        default:
            return nil
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

/// **The header for a PDF** (Phase 6a, mockups C and D) — two rows at exactly a text file's header
/// height, so switching between a PDF and a Markdown file in one column moves nothing
/// (`thePDFHeaderIsTheTextHeadersHeight`).
///
/// - **Row 1:** the name, then the file actions — Find, Fill & Sign and Tools ▾, one bezelled style
///   (``EditorPDFHeaderControls``) — a divider, and Expand and ×, plain glyphs. No "PDF" tag beside
///   the name: the name ends in .pdf.
/// - **Row 2:** the file's facts (``EditorPDFFactsRow``), starting with "PDF" the way a text file's
///   row 2 starts with "Markdown". What the old status line under the pages said about the file
///   lives here now, and the status line is gone; its page, layout and zoom are the capsule's.
///
/// **No ＋, no format bar, no Go to Line, no save word**: nothing here writes. **The Tools menu does
/// not change what row 2 says**: every tool writes a NEW copy beside the file, so the file on screen
/// is as unwritten after a run as before it.
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
    /// which is the name at full length, so the actions keep a word only while the WHOLE name fits
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
        let showsTools = pdf.phase == .open || pdf.phase == .locked
        return HStack(spacing: 6) {
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
            EditorPDFHeaderControls(find: pdf.find, fill: pdf.fill, tools: pdf.tools,
                                    showsReaderActions: pdf.phase == .open && (pdf.facts?.pageCount ?? 0) > 0,
                                    showsTools: showsTools,
                                    accent: accent, onAccent: onAccent, rung: rung)
            // The file's actions on one side, the window's on the other (mockup C).
            if showsTools {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 16)
                    .accessibilityHidden(true)
            }
            trailing
            // **The row's height is the text header's**: a hidden mode capsule — the tallest thing
            // in a text file's name row, which a plain-text file reserves the same way — under the
            // ×, at no width. In a ZStack rather than in the row, so it adds no spacing either.
            ZStack {
                EditorModeBar(mode: .constant(.edit), accent: accent, onAccent: onAccent)
                    .environment(\.selectionLensAppearance, .today)
                    .hidden()
                    .frame(width: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .chromeGlassGlyphButton(tint: accent, outset: ChromeGlass.smallGlyphOutset)
                .accessibilityLabel(EditorWorkspaceView.closeTitle(name: pdf.name))
                .help("Close this document")
            }
            .chromeGlassClearance(.leading, rowSpacing: 6)
        }
    }

    /// **Row 2: the file's facts**, and the reservation that gives it a text file's row-2 height —
    /// the autosave switch's label and track, hidden at no width, the empty page's trick.
    private var metaRow: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: EditorWorkspaceView.dotColumnWidth, height: 1)
            ZStack(alignment: .leading) {
                HStack(spacing: 5) {
                    Text("Autosave")
                        .scaledFont(.system(size: 10, weight: .medium))
                    AutosaveSwitchTrack(isOn: false, accent: accent)
                }
                .fixedSize()
                .hidden()
                .frame(width: 0)
                EditorPDFFactsRow(state: pdf.view, facts: pdf.phase == .open ? pdf.facts : nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaledFont(.system(size: 10))
        .foregroundStyle(.secondary)
    }
}

/// **Row 2 of the PDF header** (decided 2026-10-19): "PDF · Letter, 8.5 × 11 in · 42 KB · Text
/// selectable" — plain "PDF", as a text file's row starts "Markdown", then the paper of the page on
/// screen, the file's size, and whether there is text to select ("Image only" for a scan).
///
/// - **No version.** "PDF 1.4" is jargon that tells a reader almost nothing; it is in the tooltip
///   on "PDF", after the note that Edit never changes the file (``kindHelp(_:)``).
/// - **No "Read only" pill** — it read as a warning, and "read only" was not true of a file the
///   tools and Fill & Sign make changed copies of. The tooltip says what is.
/// - **No unsaved count.** Fill & Sign's "4 items not saved" is the save pill's, over the canvas
///   (Phase 6b), so row 2 says the same about the file whatever is placed on it.
/// - **It sheds whole segments**, never a word in half: "Text selectable" first, then the paper's
///   inches, then the paper's name, then the size — whatever is left of the row always reads.
///
/// Its own view, observing the view state for the page on screen — pages of one file can differ in
/// size.
struct EditorPDFFactsRow: View {
    @ObservedObject var state: EditorPDFViewState
    /// `nil` until the PDF is open — then the row says only "PDF".
    let facts: EditorPDFFacts?

    var body: some View {
        let rungs = facts.map { Self.rungs($0, page: state.visiblePages.lowerBound) } ?? [[]]
        HStack(spacing: 6) {
            Text(Self.kindWord)
                .lineLimit(1)
                .fixedSize()
                .help(Self.kindHelp(facts))
            ViewThatFits(in: .horizontal) {
                ForEach(Array(rungs.enumerated()), id: \.offset) { _, segments in
                    row(segments)
                }
            }
        }
    }

    /// One reading: each segment after a "·", none cut.
    private func row(_ segments: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Text("·").foregroundStyle(.tertiary)
                Text(segment)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    static let kindWord = "PDF"

    /// What the tooltip on "PDF" opens with.
    static let originalUntouchedNote = "Edit never changes this file. Tools and Fill & Sign save a new copy beside it."

    /// The tooltip on "PDF": that Edit never changes the file, then its version, "PDF version 1.4".
    static func kindHelp(_ facts: EditorPDFFacts?) -> String {
        guard let facts else { return originalUntouchedNote }
        return "\(originalUntouchedNote)\n\(facts.versionFact)"
    }

    /// **Row 2's readings, widest first** — every fact; then without "Text selectable" (or "Image
    /// only"); then the paper's name without its inches; then the size alone; then nothing after
    /// "PDF". A paper with no name has no reading without its inches, and its two readings are one
    /// rung. `page` is the first page on screen.
    static func rungs(_ facts: EditorPDFFacts, page: Int) -> [[String]] {
        let size = facts.fileSize.map { [$0] } ?? []
        let paper = facts.paperFact(page: page).map { [$0] } ?? []
        let named = facts.paperFact(page: page, inches: false).map { [$0] } ?? []
        let ladder = [paper + size + [facts.textCaption], paper + size, named + size, size, []]
        return ladder.reduce(into: [[String]]()) { out, rung in
            if out.last != rung { out.append(rung) }
        }
    }
}
