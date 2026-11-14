import Design
import FileExplorer
import SwiftUI
import Sync

/// What a PDF card needs from the app: its run, its doors, and what the window
/// knows that the card can't — whether Claude is answering, whether something else holds the tool.
struct AskClaudePDFBridge {
    /// The card's options changed on the card — a strength, the pages typed, a row moved.
    var setOptions: @MainActor (_ item: UUID, _ options: AskClaudePDFCard.Options) -> Void = { _, _ in }
    var moveRow: @MainActor (_ item: UUID, _ index: Int, _ step: Int) -> Void = { _, _, _ in }
    /// The click. `password` only for Protect and Remove Password, and only from this card's field.
    var run: @MainActor (_ item: UUID, _ password: EditorPDFSecret?) -> Void = { _, _ in }
    var notNow: @MainActor (_ item: UUID) -> Void = { _ in }
    var undo: @MainActor (_ item: UUID) -> Void = { _ in }
    var offersUndo: @MainActor (_ item: UUID) -> Bool = { _ in false }
    /// Whether the card's Undo is still held this session — gone after a relaunch or a new chat.
    var hasUndoStep: @MainActor (_ item: UUID) -> Bool = { _ in false }
    var download: @MainActor (_ item: UUID, _ path: String) -> Void = { _, _ in }
    var chooseFolder: @MainActor (_ item: UUID) -> Void = { _ in }
    var open: @MainActor (_ path: String) -> Void = { _ in }
    var reveal: @MainActor (_ paths: [String]) -> Void = { _ in }
    /// Why the button waits now — Claude answering, a sync running, another run of this tool —
    /// or nil when it may run.
    var waitReason: @MainActor (_ item: UUID) -> String? = { _ in nil }
    /// The run in flight, "page 14 of 22", or nil.
    var progress: @MainActor (_ item: UUID) -> String? = { _ in nil }
    var stop: @MainActor (_ item: UUID) -> Void = { _ in }
}

/// A card that runs one of SyncCloud's PDF tools on the person's click. Designed for 240 pt, as
/// the settings card is: names wrap, options sit under them, the run button is last.
/// The password fields live here and nowhere else — never in the card, the chat or its file.
struct AskClaudePDFCardView: View {
    let itemID: UUID
    let card: AskClaudePDFCard
    let bridge: AskClaudePDFBridge
    let hue: LiquidGlassHue
    /// Claude is answering: the button waits, as a plan card's Apply does.
    var isRunning = false
    /// Small pictures of the pages the card acts on, by page, once drawn.
    var thumbnails: [Int: CGImage] = [:]

    @State private var password = ""
    @State private var again = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(card.title, systemImage: "doc.richtext")
                .scaledFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
            rows
            if card.isOpen { options }
            ForEach(card.losses, id: \.self) { loss in
                Text(loss).scaledFont(.footnote)
                    .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title)
        // A card restored or replaced drops anything typed; a password never outlives its card.
        .onChange(of: card.state) { _, state in
            if !card.isOpen || state == .running { password = ""; again = "" }
        }
    }

    // MARK: Files

    private var showsFolders: Bool {
        Set(card.rows.map { ($0.path as NSString).deletingLastPathComponent }).count > 1 || card.rows.count == 1
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(card.rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).scaledFont(.callout)
                            .lineLimit(2).truncationMode(.middle)
                        if showsFolders {
                            Text(row.folderLabel).scaledFont(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        if let facts = Self.facts(row) {
                            Text(facts).scaledFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if let refusal = row.refusal {
                            Text(refusal).scaledFont(.caption)
                                .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.error))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if card.isOpen, let planned = Self.planned(card, row) {
                            Text("→ " + planned).scaledFont(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle)
                        }
                        if row.cloudOnly, card.isOpen {
                            Button("Download") { bridge.download(itemID, row.path) }
                                .controlSize(.small)
                                .help("Downloads \(row.name) so the card can run")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if card.action == .combine, card.isOpen {
                        Button { bridge.moveRow(itemID, index, -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help("Move up")
                            .accessibilityLabel("Move \(row.name) up")
                        Button { bridge.moveRow(itemID, index, 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == card.rows.count - 1)
                            .help("Move down")
                            .accessibilityLabel("Move \(row.name) down")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// The new file a row will make, as named before the write: next to the original, or in the
    /// folder chosen. Nil where the card says it elsewhere (Combine's name field) or can't say yet
    /// (pages not readable).
    static func planned(_ card: AskClaudePDFCard, _ row: AskClaudePDFCard.Row) -> String? {
        let place = card.folder.map { " in “\(($0 as NSString).lastPathComponent)”" } ?? ""
        func pages(extract: Bool) -> [Int]? {
            guard let count = row.pageCount, case .success(let pages) = PDFCardPages.parse(card.options.pages ?? "",
                                                                                         extract: extract, pageCount: count)
            else { return nil }
            return pages
        }
        let tool: EditorPDFTool?
        switch card.action {
        case .saveAsPDF: return PDFPlannedName.saveAsPDF(row.path) + place
        case .combine: return nil
        case .split:
            guard let count = row.pageCount, let starts = card.options.splitAt else { return nil }
            let parts = PDFPlannedName.splitParts(of: row.path, at: starts, pageCount: count)
            guard let first = parts.first else { return nil }
            return (parts.count > 1 ? "\(first) and \(parts.count - 1) more" : first) + place
        case .compress: tool = .compress(.quality(0.6))
        case .rotate: tool = .rotate(pages: [0], quarterTurns: 1)
        case .cleanMetadata: tool = .cleanMetadataCleared
        case .protect: tool = .protect(restrictEditing: false, password: EditorPDFSecret(""))
        case .removePassword: tool = .removePassword(EditorPDFSecret(""))
        case .reorder: tool = .reorder([])
        case .extract: tool = pages(extract: true).map { .extract($0) }
        case .deletePages: tool = pages(extract: false).map { .deletePages($0) }
        }
        return tool.map { PDFPlannedName.copy(of: row.path, tool: $0) + place }
    }

    /// "4 pages · 212 KB".
    static func facts(_ row: AskClaudePDFCard.Row) -> String? {
        let parts = [row.pageCount.map { $0 == 1 ? "1 page" : "\($0) pages" },
                     row.bytes.map { FileSyncManager.formatBytes($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Options

    @ViewBuilder
    private var options: some View {
        switch card.action {
        case .compress:
            Picker("Strength", selection: optionBinding(\.strength, default: .balanced)) {
                Text("Best").tag(AskClaudePDFCard.Options.Strength?.some(.best))
                Text("Balanced").tag(AskClaudePDFCard.Options.Strength?.some(.balanced))
                Text("Smallest").tag(AskClaudePDFCard.Options.Strength?.some(.smallestFile))
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .accentedSegments(hue)
            .disabled(card.options.underMB != nil)
            Toggle("Under \(Self.megabytes(card.options.underMB ?? 2)) MB", isOn: Binding(
                get: { card.options.underMB != nil },
                set: { on in update { $0.underMB = on ? ($0.underMB ?? 2) : nil } }))
                .scaledFont(.callout).controlSize(.small)
        case .rotate:
            Picker("Turn", selection: optionBinding(\.quarterTurns, default: 1)) {
                Text("Left").tag(Int?.some(3))
                Text("Right").tag(Int?.some(1))
                Text("180°").tag(Int?.some(2))
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .accentedSegments(hue)
            // Some pages only: shown, and his to change.
            if card.options.pages != nil {
                pagesField("Pages")
                thumbnailRow
            }
        case .protect:
            Picker("Protection", selection: optionBinding(\.mode, default: .lockToOpen)) {
                Text("Lock to open").tag(AskClaudePDFCard.Options.Mode?.some(.lockToOpen))
                Text("Restrict editing").tag(AskClaudePDFCard.Options.Mode?.some(.restrictEditing))
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .accentedSegments(hue)
            passwordFields(confirm: true)
        case .removePassword:
            if card.rows.first?.pageCount == nil { passwordFields(confirm: false) }
            Text(Self.unlockedNote).scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .extract, .deletePages, .reorder:
            pagesField(card.action == .reorder ? "New order" : "Pages")
            thumbnailRow
        case .split:
            Text("Starts new files at pages \(card.options.splitAt.map { $0.map(String.init).joined(separator: ", ") } ?? "")")
                .scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
        case .combine:
            TextField("Name", text: Binding(get: { card.options.name ?? "" },
                                            set: { name in update { $0.name = name } }))
                .textFieldStyle(.roundedBorder).scaledFont(.callout)
        case .saveAsPDF, .cleanMetadata:
            EmptyView()
        }
    }

    static let unlockedNote = "Ask Claude can read the unlocked copy, as it can any file."

    static func megabytes(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func passwordFields(confirm: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder).scaledFont(.callout)
            if confirm {
                SecureField("Again", text: $again)
                    .textFieldStyle(.roundedBorder).scaledFont(.callout)
            }
            Text("Typed here and used only on this Mac. Claude never sees it.")
                .scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pagesField(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).scaledFont(.callout)
                TextField("3-5, 1", text: Binding(get: { card.options.pages ?? "" },
                                                  set: { pages in update { $0.pages = pages } }))
                    .textFieldStyle(.roundedBorder).scaledFont(.callout)
            }
            if let problem = card.pagesProblem {
                // An empty field is a card waiting for pages, not a mistake: its hint is grey.
                Text(problem).scaledFont(.footnote)
                    .foregroundStyle(Self.pagesBlank(card) ? AnyShapeStyle(.secondary)
                                                           : AnyShapeStyle(ChromeInk.bodyText(colorScheme, SemanticColor.error)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// No pages typed yet — Claude offered Extract or Delete without them.
    static func pagesBlank(_ card: AskClaudePDFCard) -> Bool {
        (card.options.pages ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One place in a card's row of pages: a page, struck through when Delete takes it out, or a
    /// run of pages left out of the row.
    enum PageCell: Equatable {
        case page(Int, struck: Bool)
        case gap
    }

    /// Reorder draws this many pages of the new order, and a gap after them when there are more.
    static let reorderShown = 6

    /// The row of pages a card draws, in the order the new file has them: Delete's pages struck
    /// through among their neighbours, Reorder's first pages in their new order, the others' pages
    /// each with one either side. Empty while the pages typed can't be read. The window draws
    /// exactly the pages this names.
    static func pageStrip(_ card: AskClaudePDFCard) -> [PageCell] {
        guard card.action.choosesPages || card.options.pages != nil, let row = card.rows.first,
              let count = row.pageCount, row.refusal == nil, card.pagesProblem == nil else { return [] }
        func around(_ pages: [Int], struck: Set<Int> = []) -> [PageCell] {
            PDFCardThumbnails.shown(pages, pageCount: count).map { $0.map { .page($0, struck: struck.contains($0)) } ?? .gap }
        }
        let cells: [PageCell]
        switch card.action {
        case .split: cells = around((card.options.splitAt ?? []).map { $0 - 1 })
        default:
            guard case .success(let pages) = PDFCardPages.parse(card.options.pages ?? "", extract: card.action != .deletePages,
                                                               pageCount: count) else { return [] }
            switch card.action {
            case .reorder:
                cells = pages.prefix(reorderShown).map { .page($0, struck: false) } + (pages.count > reorderShown ? [.gap] : [])
            case .deletePages: cells = around(pages, struck: Set(pages))
            default: cells = around(pages)
            }
        }
        // A page is about 26 pt wide at 34 pt tall: seven places fill the 240 pt card.
        return Array(cells.prefix(stripPlaces))
    }

    static let stripPlaces = 7

    /// The pages `pageStrip` names, to draw.
    static func stripPages(_ strip: [PageCell]) -> [Int] {
        strip.compactMap { if case .page(let page, _) = $0 { page } else { nil } }
    }

    /// What VoiceOver says for a page in the row: "Page 3, taken out"; in a new order, where it goes.
    static func pageLabel(_ page: Int, struck: Bool, position: Int?) -> String {
        if struck { return "Page \(page + 1), taken out" }
        if let position { return "Page \(page + 1), placed \(position)" }
        return "Page \(page + 1)"
    }

    @ViewBuilder
    private var thumbnailRow: some View {
        if !thumbnails.isEmpty {
            let strip = Self.pageStrip(card)
            let reorder = card.action == .reorder
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(strip.enumerated()), id: \.offset) { index, cell in
                    switch cell {
                    case .gap:
                        Text("…").scaledFont(.caption).foregroundStyle(.secondary)
                            .frame(height: 34)
                            .accessibilityHidden(true)
                    case .page(let page, let struck):
                        if let image = thumbnails[page] {
                            VStack(spacing: 1) {
                                Image(decorative: image, scale: 2)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(height: 34)
                                    .opacity(struck ? 0.4 : 1)
                                    .overlay { if struck { strike } }
                                // A new order reads by the pages' own numbers.
                                if reorder {
                                    Text("\(page + 1)").scaledFont(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Self.pageLabel(page, struck: struck, position: reorder ? index + 1 : nil))
                        }
                    }
                }
            }
        }
    }

    /// A line corner to corner across a page Delete takes out.
    private var strike: some View {
        GeometryReader { box in
            Path { line in
                line.move(to: CGPoint(x: box.size.width, y: 0))
                line.addLine(to: CGPoint(x: 0, y: box.size.height))
            }
            .stroke(ChromeInk.bodyText(colorScheme, SemanticColor.error), lineWidth: 1.5)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch card.state {
        case .checking:
            VStack(alignment: .leading, spacing: 4) {
                lastClick
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking the file…").scaledFont(.footnote).foregroundStyle(.secondary)
                }
            }
        case .offered:
            offeredFooter
        case .running:
            // The run's progress lives in the tool's own model; read twice a second while it runs.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(bridge.progress(itemID) ?? "Working…").scaledFont(.footnote).monospacedDigit()
                    Spacer(minLength: 0)
                    Button("Stop") { bridge.stop(itemID) }.controlSize(.small)
                }
            }
        case .done, .partlyDone:
            VStack(alignment: .leading, spacing: 4) {
                Label(card.message ?? "Done.", systemImage: card.state == .done ? "checkmark.circle" : "exclamationmark.circle")
                    .scaledFont(.callout)
                    .foregroundStyle(card.state == .done ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = card.detail {
                    Text(detail).scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                doneButtons
            }
        case .nothingWritten:
            note(card.message ?? "Nothing was written.")
        case .failed:
            Text(card.message ?? "It couldn’t run.").scaledFont(.callout)
                .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.error))
                .fixedSize(horizontal: false, vertical: true)
        case .notNow:
            note("Not run.")
        case .undone:
            note(card.written.count == 1 ? "Undone: the new file is in the Trash." : "Undone: the new files are in the Trash.")
        case .replaced:
            note("A newer card took this one’s place.")
        case .quitWhileRunning:
            note(Self.quitNote(card))
        }
    }

    /// Why the last click didn't run — a wrong password, a file changed since — said until the next.
    @ViewBuilder
    private var lastClick: some View {
        if let message = card.message {
            Text(message).scaledFont(.footnote)
                .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.warning))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Read once a second: what the button waits on — a sync, another PDF run — comes and goes
    /// with nothing in the chat changing, and the panel's rows redraw only when the chat does.
    private var offeredFooter: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in offeredFooterNow }
    }

    private var offeredFooterNow: some View {
        let wait = Self.waitReason(isRunning: isRunning, bridge: bridge.waitReason(itemID))
        let blocked = card.rows.contains { $0.refusal != nil || $0.cloudOnly } || !passwordReady || card.pagesProblem != nil
        return VStack(alignment: .leading, spacing: 6) {
            lastClick
            Text(wait ?? "Nothing is written until you click.")
                .scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if card.folder == nil, card.rows.contains(where: { $0.refusal == Self.unwritableFolder }) {
                    Button("Choose Folder…") { bridge.chooseFolder(itemID) }
                }
                Spacer(minLength: 0)
                Button("Not Now") { bridge.notNow(itemID) }
                Button(Self.runTitle(card)) {
                    bridge.run(itemID, needsPassword ? EditorPDFSecret(password) : nil)
                    password = ""
                    again = ""
                }
                .buttonStyle(.borderedProminent)
                .accentedProminent()
                .disabled(wait != nil || blocked)
            }
            .controlSize(.small)
        }
    }

    /// What the run button waits on: Claude answering first, then what the window says.
    static func waitReason(isRunning: Bool, bridge: @autoclosure () -> String?) -> String? {
        isRunning ? "Waits for Claude to finish." : bridge()
    }

    /// Why there is no Undo, and what to do instead: Undo lasts only as long as SyncCloud and this
    /// chat do, and it never moves a file changed since.
    static func noUndoNote(_ card: AskClaudePDFCard, held: Bool) -> String {
        let one = card.written.count == 1
        if held {
            return one ? "Undo leaves the new file alone: it has changed since." : "Undo leaves the new files alone: they have changed since."
        }
        return "Undo isn’t kept once SyncCloud quits or the chat starts over. Move the new "
            + (one ? "file" : "files") + " to the Trash yourself if you don’t want " + (one ? "it." : "them.")
    }

    /// A card SyncCloud quit under: what it wrote before the quit is on disk, but the card never
    /// heard of it, so it says where to look (the folder chosen, if one was).
    static func quitNote(_ card: AskClaudePDFCard) -> String {
        let place: String
        if let folder = card.folder {
            place = "in “\((folder as NSString).lastPathComponent)”"
        } else if card.action == .combine, let first = card.rows.first {
            place = "next to “\(first.name)”"
        } else {
            place = card.rows.count == 1 ? "next to the original" : "next to the originals"
        }
        return "SyncCloud quit while this ran. Any new files it had made are \(place); nothing else changed."
    }

    /// A refusal the card answers with Choose Folder….
    static let unwritableFolder = "Its folder can’t be written to."

    private var needsPassword: Bool {
        card.action == .protect || (card.action == .removePassword && card.rows.first?.pageCount == nil)
    }

    private var passwordReady: Bool {
        switch card.action {
        case .protect: return !password.isEmpty && password == again
        case .removePassword: return !needsPassword || !password.isEmpty
        default: return true
        }
    }

    static func runTitle(_ card: AskClaudePDFCard) -> String {
        switch card.action {
        case .split: return "Split into \((card.options.splitAt?.count ?? 0) + 1)"
        case .combine: return "Combine"
        case .protect: return "Protect"
        default:
            let files = card.rows.count
            return files > 1 ? "\(card.action.title) \(files)" : card.action.title
        }
    }

    private var doneButtons: some View {
        // Read once a second: a file changed or moved since stops Undo from offering itself.
        TimelineView(.periodic(from: .now, by: 1)) { _ in doneButtonsNow }
    }

    private var doneButtonsNow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if card.written.count == 1, let only = card.written.first {
                    Button("Open in Edit") { bridge.open(only.path) }
                }
                if !card.written.isEmpty {
                    Button("Reveal") { bridge.reveal(card.written.map(\.path)) }
                }
                if bridge.offersUndo(itemID) {
                    Button("Undo") { bridge.undo(itemID) }
                        .help(card.written.count == 1 ? "Moves the new file to the Trash. Also in Edit ▸ Undo while it’s the latest step."
                              : "Moves the new files to the Trash. Also in Edit ▸ Undo while it’s the latest step.")
                }
            }
            .controlSize(.small)
            if !bridge.offersUndo(itemID), !card.written.isEmpty {
                Text(Self.noUndoNote(card, held: bridge.hasUndoStep(itemID))).scaledFont(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).scaledFont(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Options, written back

    private func update(_ change: (inout AskClaudePDFCard.Options) -> Void) {
        var options = card.options
        change(&options)
        bridge.setOptions(itemID, options)
    }

    private func optionBinding<Value: Equatable>(_ key: WritableKeyPath<AskClaudePDFCard.Options, Value?>,
                                                 default fallback: Value) -> Binding<Value?> {
        Binding(get: { card.options[keyPath: key] ?? fallback },
                set: { value in update { $0[keyPath: key] = value } })
    }
}
