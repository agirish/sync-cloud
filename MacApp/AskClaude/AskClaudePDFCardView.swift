import Design
import FileExplorer
import SwiftUI
import Sync

/// What a PDF card needs from the app (TE294 step 3): its run, its doors, and what the window
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

/// **A card that runs one of SyncCloud's PDF tools on the person's click** (TE294). Designed for
/// 240 pt, as the settings card is: names wrap, options sit under them, the run button is last.
/// The password fields live here and nowhere else — never in the card, the chat or its file.
struct AskClaudePDFCardView: View {
    let itemID: UUID
    let card: AskClaudePDFCard
    let bridge: AskClaudePDFBridge
    let accent: Color
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
                Text(problem).scaledFont(.footnote)
                    .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.error))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var thumbnailRow: some View {
        if !thumbnails.isEmpty {
            HStack(spacing: 4) {
                ForEach(thumbnails.keys.sorted(), id: \.self) { page in
                    if let image = thumbnails[page] {
                        Image(decorative: image, scale: 2)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(height: 34)
                            .accessibilityLabel("Page \(page + 1)")
                    }
                }
            }
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
            // What it wrote before the quit is on disk, but the card never heard of it.
            note("SyncCloud quit while this ran. Any new files it had made are next to the originals; nothing else changed.")
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
        let wait = isRunning ? "Waits for Claude to finish." : bridge.waitReason(itemID)
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

    @ViewBuilder
    private var doneButtonsNow: some View {
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
