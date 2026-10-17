import AppKit
import PDFKit
import SwiftUI
import Design
import Sync

/// The PDF header's own controls, at the end of the name row: the page field, the zoom, and Page /
/// Width / Actual where Source / Preview / Split sit for Markdown.
///
/// **Its own view, observing the view state alone**, so a page turn re-renders this and the status
/// line and nothing else in the header — see ``EditorPDFDocument``'s split.
struct EditorPDFHeaderControls: View {
    @ObservedObject var state: EditorPDFViewState
    let pageCount: Int
    let accent: Color
    let onAccent: Color
    @State private var typedPage = ""
    @FocusState private var pageFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if pageCount > 0 {
                pageField
                zoom
            }
            EditorPDFFitBar(fit: $state.fit, accent: accent, onAccent: onAccent)
        }
    }

    /// "2 of 3", the number a field: type a page and Return.
    private var pageField: some View {
        HStack(spacing: 4) {
            TextField("", text: $typedPage)
                .textFieldStyle(.roundedBorder)
                // Small, so the field is no taller than the mode capsule it stands in for.
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: EditorPDFHeaderControls.fieldWidth(pageCount: pageCount))
                .focused($pageFieldFocused)
                .onSubmit { go() }
                .accessibilityLabel("Page")
            Text("of \(pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .scaledFont(.system(size: 10))
        .onAppear { typedPage = String(state.currentPage + 1) }
        .onChange(of: state.currentPage) { _, page in
            if !pageFieldFocused { typedPage = String(page + 1) }
        }
        .onChange(of: pageFieldFocused) { _, focused in
            if !focused { typedPage = String(state.currentPage + 1) }
        }
    }

    /// Wide enough for the longest number this document has, and no wider.
    static func fieldWidth(pageCount: Int) -> CGFloat {
        CGFloat(max(String(pageCount).count, 2)) * 8 + 14
    }

    private func go() {
        guard let page = EditorPDFHeaderControls.page(typed: typedPage, pageCount: pageCount) else {
            typedPage = String(state.currentPage + 1)
            return
        }
        state.requestPage(page)
        pageFieldFocused = false
    }

    /// The zero-based page a typed number names, clamped into the document; `nil` for no number.
    static func page(typed: String, pageCount: Int) -> Int? {
        guard pageCount > 0, let number = Int(typed.trimmingCharacters(in: .whitespaces)) else { return nil }
        return min(max(number, 1), pageCount) - 1
    }

    private var zoom: some View {
        HStack(spacing: 2) {
            glyphButton("minus", label: "Zoom out") { state.zoom(in: false) }
            Text(EditorPDFHeaderControls.percent(state.scale))
                .scaledFont(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 34)
            glyphButton("plus", label: "Zoom in") { state.zoom(in: true) }
        }
        .padding(.horizontal, 2)
        .chromeGlassTrack()
    }

    static func percent(_ scale: CGFloat) -> String { "\(Int((scale * 100).rounded()))%" }

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

/// Page / Width / Actual — ``EditorModeBar``'s capsule, over ``EditorPDFFit``. None is lit while the
/// reader has zoomed by hand.
struct EditorPDFFitBar: View {
    @Binding var fit: EditorPDFFit?
    let accent: Color
    let onAccent: Color

    static let lensChannel = SelectionLensChannel("editor.pdf-fit")

    var body: some View {
        HStack(spacing: 3) {
            ForEach(EditorPDFFit.allCases, id: \.self) { candidate in
                segment(candidate)
            }
        }
        .selectionLensHost(Self.lensChannel, selected: fit, style: .fill(.capsule, color: accent))
        .padding(2)
        .chromeGlassTrack()
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page fit")
    }

    private func segment(_ candidate: EditorPDFFit) -> some View {
        let isSelected = fit == candidate
        return Button {
            fit = candidate
        } label: {
            Text(candidate.title)
                .scaledFont(.system(size: 10, weight: .semibold))
                .selectionLensLabelInk(isSelected: isSelected, onFill: onAccent, unselected: Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    if isSelected { SelectionLensTodayMarker { Capsule().fill(accent) } }
                }
                .selectionLensStop(Self.lensChannel, id: candidate)
                .contentShape(Capsule())
        }
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: accent)
        .help(candidate.title)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Under the PDF header: the pages, or the state that stands in for them (mockup 5).
struct EditorPDFBody: View {
    @ObservedObject var pdf: EditorPDFDocument
    let accent: Color
    /// The one Quick Look panel every other surface shares — the host's.
    let quickLook: (String) -> Void

    var body: some View {
        switch pdf.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .open:
            EditorPDFPageView(document: pdf.document, state: pdf.view)
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
        ViewThatFits(in: .horizontal) {
            row(EditorPDFStatusLine.segments(facts: facts, page: state.currentPage))
            row(Array(EditorPDFStatusLine.segments(facts: facts, page: state.currentPage).prefix(2)))
            row(Array(EditorPDFStatusLine.segments(facts: facts, page: state.currentPage).prefix(1)))
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

    /// The line's segments, most worth keeping first — the order a narrow column drops them in.
    static func segments(facts: EditorPDFFacts, page: Int) -> [String] {
        var out = ["Page \(min(page, max(facts.pageCount - 1, 0)) + 1) of \(facts.pageCount)"]
        if let paper = facts.paperCaption(page: page) { out.append(paper) }
        if let size = facts.fileSize { out.append(size) }
        out.append(facts.versionCaption)
        out.append(facts.textCaption)
        return out
    }
}

/// **The header for a PDF** — mockup 4: the same two rows in the same places as a text file's, with
/// "PDF" and a Read only tag where the kind and the Autosave switch sit, and the page controls
/// where the mode capsule sits. **No ＋ / Find capsule, no format bar, no Go to Line, no save word**:
/// nothing here writes, and PDF find is a later phase.
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
                    EditorPDFHeaderControls(state: pdf.view, pageCount: pdf.facts?.pageCount ?? 0,
                                            accent: accent, onAccent: onAccent)
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
    }

    static var readOnlyTag: String { "Read only" }
}
