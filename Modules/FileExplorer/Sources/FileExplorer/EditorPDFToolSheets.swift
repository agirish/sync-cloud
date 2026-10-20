import AppKit
import SwiftUI
import PDFToolkitCore
import Design
import Sync

/// One sheet per tool that needs to ask something. **A sheet stays up while its run is in the
/// lane** and closes when the run ends with a copy or a reason; a failure is shown in place, beside
/// the field that caused it.
struct EditorPDFToolSheetView: View {
    @ObservedObject var tools: EditorPDFTools
    let sheet: EditorPDFToolSheet
    let accent: Color

    var body: some View {
        Group {
            switch sheet {
            case .pages(let action, let prefill):
                EditorPDFPageRangeSheet(tools: tools, action: action, typed: prefill)
            case .compress:
                EditorPDFCompressSheet(tools: tools)
            case .metadata:
                EditorPDFMetadataSheet(tools: tools)
            case .protect:
                EditorPDFProtectSheet(tools: tools)
            case .removePassword:
                EditorPDFRemovePasswordSheet(tools: tools)
            }
        }
        .padding(20)
        // A floor, not a fixed width: at the Large text size the radio rows and captions need more.
        .frame(minWidth: 400, idealWidth: 420)
        .tint(accent)
    }
}

/// The shared parts of a tool sheet: a title, what it writes, the content, a failure, two buttons.
struct EditorPDFToolSheetFrame<Content: View>: View {
    @ObservedObject var tools: EditorPDFTools
    let title: String
    let action: String
    let canRun: Bool
    let failure: String?
    let run: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).scaledFont(.system(size: 13, weight: .semibold))
            content
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Writes a new copy next to the original. “\(tools.name)” isn’t changed.")
                .scaledFont(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {
                    if tools.running != nil { tools.cancelRun() } else { tools.sheet = nil }
                }
                .keyboardShortcut(.cancelAction)
                Button(action, action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun || tools.running != nil)
            }
        }
    }
}

extension EditorPDFTools {
    var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "" }

    /// Runs a sheet's tool and closes the sheet unless it failed or the reader declined — what a
    /// sheet's button does. Returns the failure to show in place.
    func runFromSheet(_ tool: EditorPDFTool) async -> String? {
        let asked = sheet
        let file = path
        let outcome = await run(tool, bannerFailures: false)
        // Only the sheet that asked, on the file it asked about — another file's sheet may be up.
        guard sheet == asked, path == file else { return nil }
        switch outcome {
        case .failed(let message): return message
        case .declined: return nil
        case .wrote, .nothingWritten, .cancelled:
            sheet = nil
            return nil
        }
    }
}

/// Extract Pages… and Delete Pages…: a page range, parsed by the toolkit's own parser.
struct EditorPDFPageRangeSheet: View {
    @ObservedObject var tools: EditorPDFTools
    let action: EditorPDFPageAction
    @State var typed: String
    @State private var failure: String?

    var body: some View {
        let parsed = Self.parse(typed, action: action, pageCount: tools.pageCount, arrangement: tools.arrangement)
        EditorPDFToolSheetFrame(tools: tools, title: action == .extract ? "Extract Pages" : "Delete Pages",
                                action: action == .extract ? "Extract" : "Delete",
                                canRun: parsed.pages != nil, failure: failure, run: { go(parsed.pages) }) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(action == .extract ? "Pages, e.g. 3-5, 1" : "Pages, e.g. 1, 4-6", text: $typed)
                    .textFieldStyle(.roundedBorder)
                Text(parsed.caption)
                    .scaledFont(.system(size: 11))
                    // Blank is not an error yet — it is where an empty selection starts.
                    .foregroundStyle(parsed.pages == nil && !parsed.isBlank ? AnyShapeStyle(.red)
                                                                            : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func go(_ pages: [Int]?) {
        guard let pages else { return }
        failure = nil
        let tool: EditorPDFTool = action == .extract ? .extract(pages) : .deletePages(pages)
        Task { failure = await tools.runFromSheet(tool) }
    }

    /// The pages typed, or why not — Extract keeps the order typed and allows a page twice, Delete
    /// does not care about order. Blank is refused for both: blank-means-all would make Delete
    /// "delete everything" and Extract a plain copy.
    ///
    /// **An en dash is read as a hyphen**: the copy's name and this sheet's own caption say "3–5", and
    /// pasting that back used to fail — `PageRangeParser` reads only "-".
    ///
    /// With a dragged order pending, Delete's caption says the copy takes it — the run does
    /// (``EditorPDFTool/composing(_:arrangement:)``); Extract's order is the one typed either way.
    static func parse(_ text: String, action: EditorPDFPageAction, pageCount: Int,
                      arrangement: [Int]? = nil) -> (pages: [Int]?, caption: String, isBlank: Bool) {
        let typed = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (nil, action == .extract ? "Type the pages to keep, in the order you want them — e.g. 3-5, 1."
                                            : "Type the pages to leave out — e.g. 1, 4-6.", true)
        }
        do {
            let pages = try PageRangeParser.parse(typed, pageCount: pageCount, emptyMeansAllPages: false,
                                                  preserveOrder: action == .extract)
            if action == .delete, Set(pages).count >= pageCount {
                return (nil, PDFOperationError.cannotRemoveEveryPage.errorDescription ?? "", false)
            }
            let tool = EditorPDFTool.composing(action == .extract ? .extract(pages) : .deletePages(pages),
                                               arrangement: arrangement)
            var detail = action == .extract
                ? "Keeps \(EditorPDFCopyName.pageList(pages)), in this order"
                : "Leaves out \(EditorPDFCopyName.pageList(pages.sorted()))"
            if case .arranged = tool { detail += ", in the new page order" }
            return (pages, "\(detail) — as “… (\(tool.suffix)).pdf”.", false)
        } catch {
            return (nil, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, false)
        }
    }
}

/// Compress…: a strength, or a size to come in under — with the run's progress and Cancel.
struct EditorPDFCompressSheet: View {
    @ObservedObject var tools: EditorPDFTools
    @State private var byTarget = false
    @State private var quality = EditorPDFCompression.strengths[1].quality
    /// Typed as text and read on the button, not a `value:` field — that commits only on Return
    /// or focus loss, so a click on Compress could run at the number the field held before.
    @State private var typedMegabytes = "2"
    @State private var failure: String?
    /// Read once when the sheet opens — the body redraws on every page of progress.
    @State private var size: Int?

    var body: some View {
        EditorPDFToolSheetFrame(tools: tools, title: "Compress", action: "Compress",
                                canRun: !byTarget || EditorPDFCompression.megabytes(typedMegabytes) != nil,
                                failure: failure, run: go) {
            VStack(alignment: .leading, spacing: 10) {
                EditorPDFCompressControls(byTarget: $byTarget, quality: $quality,
                                          typedMegabytes: $typedMegabytes)
                if let size {
                    Text("This file is \(FileSyncManager.formatBytes(size)). Every page is redrawn as an "
                         + "image, so text in the copy can’t be selected.")
                        .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if tools.running != nil {
                    EditorPDFProgressRow(progress: tools.progress)
                }
            }
        }
        .task { size = tools.path.flatMap { EditorFileStore.stamp(ofPath: $0)?.size } }
    }

    private func go() {
        failure = nil
        let compression: EditorPDFCompression
        if byTarget {
            guard let megabytes = EditorPDFCompression.megabytes(typedMegabytes) else { return }
            compression = .target(bytes: EditorPDFCompression.bytes(megabytes: megabytes))
        } else {
            compression = .quality(quality)
        }
        Task { failure = await tools.runFromSheet(.compress(compression)) }
    }
}

/// **Compress's settings** — a strength, or a size to come in under. One file's sheet and a
/// batch's (``EditorPDFBatchSheet``) draw these same controls, so the two cannot drift.
struct EditorPDFCompressControls: View {
    @Binding var byTarget: Bool
    @Binding var quality: Double
    @Binding var typedMegabytes: String
    /// A batch's target is each file's, and says so.
    var perFile = false
    /// The window's hue, for the segmented picker — `accentedSegments` takes the hue itself.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    var body: some View {
        Picker("", selection: $byTarget) {
            Text("By strength").tag(false)
            Text(perFile ? "To a size per file" : "To a size").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accentedSegments(LiquidGlassHue(rawValue: glassHueRaw) ?? .blue)
        if byTarget {
            HStack(spacing: 6) {
                Text("Under")
                TextField("2", text: $typedMegabytes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Text("MB")
            }
            Text("Tries lower quality until the file fits.")
                .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Picker("", selection: $quality) {
                ForEach(EditorPDFCompression.strengths, id: \.quality) { strength in
                    Text("\(strength.title) — \(strength.subtitle)").tag(strength.quality)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

/// "Page 12 of 300", under a bar — Compress's progress as the lane reports it.
struct EditorPDFProgressRow: View {
    let progress: EditorPDFTools.Progress?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let page = progress?.page, let total = progress?.total, total > 0 {
                ProgressView(value: Double(page), total: Double(total))
                Text("Page \(page) of \(total)")
                    .scaledFont(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for the PDF reader…")
                    .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Clean Metadata…: the fields the file says, editable, or cleared all at once.
struct EditorPDFMetadataSheet: View {
    @ObservedObject var tools: EditorPDFTools
    @State private var fields: PDFMetadataFields?
    @State private var hasForm = false
    @State private var failure: String?

    var body: some View {
        EditorPDFToolSheetFrame(tools: tools, title: "Clean Metadata", action: "Write Cleaned Copy",
                                canRun: fields != nil, failure: failure, run: go) {
            if let binding = Binding($fields) {
                VStack(alignment: .leading, spacing: 8) {
                    Form {
                        TextField("Title", text: binding.title)
                        TextField("Author", text: binding.author)
                        TextField("Subject", text: binding.subject)
                        TextField("Keywords", text: binding.keywords)
                        TextField("Creator", text: binding.creator)
                    }
                    Button("Clear All") { fields = PDFMetadataFields.cleared }
                        .controlSize(.small)
                    Text(Self.stampedLine(binding.wrappedValue))
                        .scaledFont(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if hasForm {
                        Text("This PDF has a fillable form, so some embedded (XMP) metadata may remain in the copy.")
                            .scaledFont(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if failure == nil {
                ProgressView().controlSize(.small)
            }
        }
        .task { await read() }
    }

    /// Producer and the two dates are what PDFKit writes on every save, whatever is asked for.
    static func stampedLine(_ fields: PDFMetadataFields) -> String {
        let producer = fields.producer.isEmpty ? "none" : "“\(fields.producer)”"
        return "Producer (\(producer)) and the created and modified dates are replaced with the "
            + "system’s own when the copy is written."
    }

    private func read() async {
        guard let path = tools.path else { return }
        switch await Self.read(path: path, isCloudOnly: tools.isCloudOnly) {
        case .success(let read):
            fields = read.fields
            hasForm = read.hasForm
        case .failure(let error):
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// What the file says, and whether it has a form — one lane turn, by URL. **Never for a file
    /// evicted since it opened**: the toolkit opening the placeholder downloads it, in the lane every
    /// duplicate scan waits on, and nobody asked for that — the run refuses it the same way.
    static func read(path: String, isCloudOnly: (String) -> Bool) async -> Result<ReadFields, any Error> {
        if isCloudOnly(path) {
            return .failure(Refusal(EditorPDFTools.cloudOnlyReason((path as NSString).lastPathComponent)))
        }
        let url = URL(fileURLWithPath: EditorFileStore.resolved(path))
        return await PDFKitSerialAccess.perform {
            Result { ReadFields(fields: try PDFToolkit.readMetadata(inputURL: url),
                                hasForm: PDFToolkit.hasInteractiveForm(at: url)) }
        }
    }

    /// A refusal made before the lane, in words for the sheet.
    struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ reason: String) { errorDescription = reason }
    }

    struct ReadFields: Sendable {
        var fields: PDFMetadataFields
        var hasForm: Bool
    }

    private func go() {
        guard let fields else { return }
        failure = nil
        Task { failure = await tools.runFromSheet(.cleanMetadata(fields)) }
    }
}

/// Protect with Password…: lock to open, or restrict editing — two secure fields and a strength
/// hint. **The password lives in this sheet's state alone** and goes with the sheet.
struct EditorPDFProtectSheet: View {
    @ObservedObject var tools: EditorPDFTools
    @State private var restrictEditing = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var failure: String?
    /// The window's hue, for the segmented picker — `accentedSegments` takes the hue itself.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    var body: some View {
        let strength = PasswordStrengthEstimator.estimate(password)
        let matches = !password.isEmpty && password == confirmation
        EditorPDFToolSheetFrame(tools: tools, title: "Protect with Password", action: "Write Protected Copy",
                                canRun: matches, failure: failure, run: go) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $restrictEditing) {
                    Text("Lock to open").tag(false)
                    Text("Restrict editing").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(LiquidGlassHue(rawValue: glassHueRaw) ?? .blue)
                Text(restrictEditing
                     ? "The copy opens without a password; copying, editing and changing pages need it. Readers honor this — it doesn’t encrypt what the pages say."
                     : "The copy needs this password to open. SyncCloud doesn’t keep it — without it, the copy can’t be opened.")
                    .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Confirm password", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 6) {
                    EditorPDFStrengthMeter(strength: strength)
                    Text(!confirmation.isEmpty && !matches ? "The passwords don’t match." : strength.label)
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(!confirmation.isEmpty && !matches ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
        }
        .onDisappear { password = ""; confirmation = "" }
    }

    private func go() {
        let tool = EditorPDFTool.protect(restrictEditing: restrictEditing, password: EditorPDFSecret(password))
        failure = nil
        Task { failure = await tools.runFromSheet(tool) }
    }
}

/// Four segments, pdf-utils' meter.
struct EditorPDFStrengthMeter: View {
    let strength: PasswordStrength

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < strength.filledSegments ? Self.color(strength) : Color.secondary.opacity(0.25))
                    .frame(width: 18, height: 4)
            }
        }
        .accessibilityLabel("Password strength: \(strength.label)")
    }

    static func color(_ strength: PasswordStrength) -> Color {
        switch strength {
        case .empty, .weak: return .red
        case .fair: return .orange
        case .good, .strong: return .green
        }
    }
}

/// Remove Password…: the password, for a file locked to open; for a restricted one, nothing to type
/// — the toolkit cannot check an owner password on a file that is not locked, so none is asked for.
struct EditorPDFRemovePasswordSheet: View {
    @ObservedObject var tools: EditorPDFTools
    @State private var password = ""
    @State private var failure: String?

    var body: some View {
        let locked = tools.encryption == .lockedToOpen
        EditorPDFToolSheetFrame(tools: tools, title: "Remove Password", action: "Write Unlocked Copy",
                                canRun: !locked || !password.isEmpty, failure: failure, run: go) {
            VStack(alignment: .leading, spacing: 8) {
                if locked {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Text("The copy opens without a password. SyncCloud uses this one only to write it.")
                        .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // A locked file's form cannot be seen without the password, so the warning the
                    // other rebuilding tools give only when there IS a form is said here always.
                    Text("If this PDF has fillable form fields, they stop working in the copy.")
                        .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("This PDF opens without a password and only restricts editing. The copy drops those restrictions.")
                        .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onDisappear { password = "" }
    }

    private func go() {
        let tool = EditorPDFTool.removePassword(EditorPDFSecret(password))
        password = ""
        failure = nil
        Task { failure = await tools.runFromSheet(tool) }
    }
}
