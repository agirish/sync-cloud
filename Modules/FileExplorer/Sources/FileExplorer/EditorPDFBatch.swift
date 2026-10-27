import AppKit
import Combine
import Events
import PDFKit
import PDFToolkitCore
import Sync

/// One of the tools that runs over several files — the whole-file ones whose options do not
/// depend on the file. Passwords are not here: each file's is its own.
public enum EditorPDFBatchTool: Equatable, Sendable {
    case rotate(quarterTurns: Int)
    case compress(EditorPDFCompression)
    /// Every field cleared — there is no one file's fields to edit.
    case cleanMetadata

    /// The tool as Edit runs it on one file of `pageCount` pages — so the copy's name, the log's
    /// words and the toolkit call are Edit's own, not a second table of them.
    func tool(pageCount: Int) -> EditorPDFTool {
        switch self {
        case .rotate(let turns): return .rotate(pages: Array(0..<pageCount), quarterTurns: turns)
        case .compress(let compression): return .compress(compression)
        case .cleanMetadata: return .cleanMetadata(.cleared)
        }
    }

    /// What a file's log line says was done — Edit's words, except that Rotate names every page
    /// without knowing how many there are.
    var logDetail: String {
        if case .rotate(let turns) = self { return "rotate \(EditorPDFCopyName.degrees(turns)) all pages" }
        return tool(pageCount: 0).logDetail
    }

    /// What the summary calls a copy: "Saved 2 compressed copies".
    var copyNoun: (one: String, many: String) {
        switch self {
        case .rotate: return ("rotated copy", "rotated copies")
        case .compress: return ("compressed copy", "compressed copies")
        case .cleanMetadata: return ("cleaned copy", "cleaned copies")
        }
    }
}

/// Which batch the sheet is for, before its options are chosen.
public enum EditorPDFBatchKind: Equatable, Sendable {
    case rotate(quarterTurns: Int)
    case compress
    case cleanMetadata
}

/// **Edit's whole-file PDF tools over several files at once** — Rotate All Pages, Compress and
/// Clean Metadata, from a pane's menu.
///
/// **One file at a time, one lane turn per file.** Each turn opens the file, reads whether it can
/// run, and runs — then gives the lane back, so a duplicate scan, a thumbnail or find interleaves
/// between files rather than waiting out the whole batch. The copy is written outside the lane,
/// by ``EditorPDFCopyWriter``, exactly as one file's run writes it: a new file next to its
/// original, never over anything, and the original never touched.
///
/// **A file that cannot run is skipped with its reason, not failed with the batch**: one locked to
/// open (no tool can read it), one encrypted for Clean Metadata (the toolkit refuses), one
/// whose owner forbids the changes Rotate makes in place, one Compress cannot make smaller. Cancel stops the file in hand — nothing is written for it — and
/// skips the rest; the copies already written stay.
@MainActor
public final class EditorPDFBatch: ObservableObject, Identifiable {

    public enum Skip: Equatable, Sendable {
        case alreadySmall
        case lockedToOpen
        /// Encrypted for Clean Metadata, which the toolkit refuses on any encrypted file
        /// (`metadataEncrypted`). Said as encrypted, not as an owner's restrictions (L11): a file
        /// can be encrypted with every permission allowed, and the skip is the same for it. The way
        /// past it is Remove Password…, which this one opens without asking for a password.
        case passwordProtected
        /// Encrypted with its owner's restrictions, which forbid the changes Rotate makes in place.
        case restrictedByOwner
        case noPages
        case inTheCloud
        case cancelled

        /// The summary's words for it, after "N skipped,".
        var reason: String {
            switch self {
            case .alreadySmall: return "already small"
            case .lockedToOpen: return "locked with a password"
            case .passwordProtected: return "it’s encrypted, so its metadata can’t be cleaned"
            case .restrictedByOwner: return "its owner doesn’t allow changing its pages"
            case .noPages: return "no pages"
            case .inTheCloud: return "still in the cloud"
            case .cancelled: return "canceled"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case waiting
        case running
        case wrote(String, sizes: String?)
        case skipped(Skip)
        case failed(String)
    }

    public struct File: Equatable, Identifiable, Sendable {
        public var path: String
        public var status: Status
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// "File 2 of 5 · page 40 of 112" — the file in hand, and Compress's page when it reports one.
    public struct Progress: Equatable, Sendable {
        public var file: Int
        public var files: Int
        public var page: Int?
        public var pages: Int?

        public var text: String {
            let file = "File \(self.file) of \(files)"
            guard let page, let pages, pages > 0 else { return file }
            return "\(file) · page \(page) of \(pages)"
        }

        /// The whole batch's share done, for one bar.
        public var fraction: Double {
            guard files > 0 else { return 0 }
            let within = (page.flatMap { page in pages.map { Double(page) / Double(max($0, 1)) } }) ?? 0
            return (Double(file - 1) + within) / Double(files)
        }
    }

    /// How a run ended, for the sheet — a declined warning leaves it up, anything else closes it.
    public enum Outcome: Equatable, Sendable {
        case finished
        case declined
        case busy
    }

    public let id = UUID()
    public let kind: EditorPDFBatchKind
    @Published public private(set) var files: [File]
    @Published public private(set) var progress: Progress?
    @Published public private(set) var isRunning = false
    @Published public var showsSheet = false
    /// When the run began — what orders it among the window's other runs in the capsule.
    public private(set) var startedAt: Date?
    @Published public var banner: EditorPDFToolBanner?

    /// Who the log lines say ran it — the workspace the menu was in.
    let writer: String
    /// Set by the window; a no-op otherwise, so a test can run a batch without one.
    public var host = PanePDFToolHost()
    /// Asks once whether to go ahead when some files would lose a form — a native alert in the
    /// app, a canned answer in a test.
    var confirm: @MainActor (EditorPDFBatchWarning) -> Bool = { EditorPDFBatch.confirmWithAlert($0) }

    private var cancelFlag: CancelFlag?
    /// Copies this run wrote from a restricted original that came out unrestricted.
    private var unrestrictedCopies = 0
    /// Called as each file starts, before its lane turn is asked for — a test's way to cancel at a
    /// known file rather than racing the lane for it.
    var fileStarted: @MainActor (Int) -> Void = { _ in }
    /// Called on the main actor as a file's copy is handed to the writer — a test's way to cancel
    /// while the bytes are being written. `nil` in the app.
    var writeStartedHook: (@MainActor () -> Void)?
    /// Whether a file's bytes are still only in the cloud — asked as each file starts, since the
    /// menu's answer can be a moment old and opening a placeholder in PDFKit would download it.
    var isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }

    public init(kind: EditorPDFBatchKind, paths: [String], writer: String) {
        self.kind = kind
        self.writer = writer
        files = paths.map { File(path: $0, status: .waiting) }
    }

    public var count: Int { files.count }

    public func cancel() { cancelFlag?.cancel() }

    // MARK: Running

    /// **Runs `tool` over every file, in order, and says how it went in one banner.** The form
    /// warning first, as one question naming the files that would lose a form; then each file in
    /// its own lane turn; then the panes re-read, once per folder a copy landed in.
    @discardableResult
    public func run(_ tool: EditorPDFBatchTool) async -> Outcome {
        guard !isRunning else { return .busy }
        isRunning = true
        let flag = CancelFlag()
        cancelFlag = flag
        progress = nil
        banner = nil
        unrestrictedCopies = 0
        for index in files.indices { files[index].status = .waiting }
        defer {
            isRunning = false
            cancelFlag = nil
        }

        if let warning = await formWarning(for: tool, cancelled: flag), !flag.isCancelled {
            guard confirm(warning) else { return .declined }
        }
        // **The sheet has asked its question, so it goes** (Run Room CH): the run goes on in the
        // toolbar's capsule with its Stop, beside any other run, and the window stays usable.
        startedAt = Date()
        showsSheet = false

        for index in files.indices {
            if flag.isCancelled {
                for rest in index..<files.count { files[rest].status = .skipped(.cancelled) }
                break
            }
            progress = Progress(file: index + 1, files: files.count)
            files[index].status = .running
            fileStarted(index)
            files[index].status = await runOne(tool, at: index, flag: flag)
            log(files[index], tool: tool)
        }
        finish(tool, cancelled: flag.isCancelled)
        return .finished
    }

    /// One file, start to end. Never throws and never stops the batch: every ending is a status.
    private func runOne(_ tool: EditorPDFBatchTool, at index: Int, flag: CancelFlag) async -> Status {
        let path = files[index].path
        let input = URL(fileURLWithPath: EditorFileStore.resolved(path))
        if isCloudOnly(MaterializationStatus.linkTarget(of: path)) { return .skipped(.inTheCloud) }
        // Moved or deleted since it was chosen: said as such, not as a file PDFKit couldn't read.
        if EditorFileStore.stamp(ofPath: path) == nil { return .failed(Self.goneReason) }
        if case .compress(.target(let bytes)) = tool, let size = EditorFileStore.stamp(ofPath: path)?.size,
           size <= bytes {
            return .skipped(.alreadySmall)
        }
        let before = EditorFileStore.stamp(ofPath: path)?.size
        let file = index + 1, files = self.files.count
        let turn = await PDFKitSerialAccess.perform {
            Self.laneTurn(tool, input: input,
                          progress: { page, total in
                              Task { @MainActor [weak self] in
                                  // Only while this file is still the one in hand.
                                  guard let self, self.progress?.file == file else { return }
                                  self.progress = Progress(file: file, files: files, page: page, pages: total)
                              }
                          },
                          isCancelled: { flag.isCancelled })
        }
        // **Cancel holds for the file in hand whatever the tool** — pressed while it waited for the
        // lane, or after Compress's last page, it still means "write nothing for it".
        if flag.isCancelled { return .skipped(.cancelled) }
        switch turn {
        case .skipped(let skip):
            return .skipped(skip)
        case .failed(let message):
            return .failed(message)
        case .output(.noGain, _):
            return .skipped(.alreadySmall)
        case .output(.bytes(let data, _, _), let unrestricted):
            let suffix = tool.tool(pageCount: 0).suffix
            writeStartedHook?()
            let written = await Task.detached(priority: .userInitiated) {
                Result { try EditorPDFCopyWriter.writeStamped(data, besides: path, suffix: suffix) }
            }.value
            // **Cancel pressed while the copy was being written still means "write nothing for
            // it"**, as one file's run already holds: the copy is taken back, if it is still the
            // file this run made.
            if case .success(let landed) = written, flag.isCancelled {
                if EditorFileStore.stamp(ofPath: landed.path) == landed.stamp {
                    try? FileManager.default.removeItem(atPath: landed.path)
                }
                return .skipped(.cancelled)
            }
            switch written.map(\.path) {
            case .failure(let error):
                return .failed("Couldn’t write the copy — \(error.localizedDescription)")
            case .success(let copy):
                if unrestricted { unrestrictedCopies += 1 }
                let sizes: String? = if case .compress = tool {
                    EditorPDFTools.sizes(before: before, after: data.count)
                } else {
                    nil
                }
                return .wrote(copy, sizes: sizes)
            }
        }
    }

    /// A file moved or deleted after it was chosen.
    nonisolated static let goneReason = "it is no longer there — it was moved or deleted"

    /// What one file's lane turn came back with.
    enum Turn: Sendable {
        case skipped(Skip)
        case failed(String)
        /// `unrestricted`: the original's owner restricted editing and the tool rebuilt the
        /// document, so the copy carries no restrictions — said, as one file's run says it.
        case output(EditorPDFToolEngine.Output, unrestricted: Bool)
    }

    /// **The whole of one file's turn in the lane**: open it, decide whether it can run — the same
    /// reading `PDFToolkit.encryptionState` makes — and run. Called from the lane.
    nonisolated static func laneTurn(_ tool: EditorPDFBatchTool, input: URL,
                                     progress: (@Sendable (Int, Int) -> Void)?,
                                     isCancelled: (@Sendable () -> Bool)?) -> Turn {
        if isCancelled?() == true { return .skipped(.cancelled) }
        guard let document = PDFDocument(url: input) else {
            return .failed(FileManager.default.fileExists(atPath: input.path) ? "couldn’t read this PDF" : goneReason)
        }
        if document.isLocked { return .skipped(.lockedToOpen) }
        if case .cleanMetadata = tool, document.isEncrypted { return .skipped(.passwordProtected) }
        let pageCount = document.pageCount
        let edit = tool.tool(pageCount: pageCount)
        if ownerForbids(edit, isEncrypted: document.isEncrypted, allowsAssembly: document.allowsDocumentAssembly) {
            return .skipped(.restrictedByOwner)
        }
        if pageCount == 0 { return .skipped(.noPages) }
        if let refusal = EditorPDFToolEngine.refusal(edit, pageCount: pageCount) { return .failed(refusal) }
        do {
            return .output(try EditorPDFToolEngine.output(of: edit, input: input,
                                                          progress: progress, isCancelled: isCancelled),
                           unrestricted: document.isEncrypted && edit.rebuildsDocument)
        } catch is CancellationError {
            return .skipped(.cancelled)
        } catch {
            // In Edit's words, as a single file's run says it — not the toolkit's PDF Utils ones.
            return .failed(EditorPDFToolEngine.reason(error, tool: edit))
        }
    }

    /// **Whether the owner's restrictions forbid `edit` on this file** (PD3) — the toolkit's own test
    /// for Rotate and Delete Pages, which change the document in place (`openEditableDocument`):
    /// encrypted, and no page assembly. Skipped before the run rather than failed by it, whose
    /// sentence names the file and so named it twice after the reasons line's own name; and the run
    /// is not paid for. The tools that rebuild the document run on such a file.
    nonisolated static func ownerForbids(_ edit: EditorPDFTool, isEncrypted: Bool, allowsAssembly: Bool) -> Bool {
        switch edit {
        case .rotate, .deletePages: return isEncrypted && !allowsAssembly
        default: return false
        }
    }

    // MARK: The form warning

    /// **One question for the whole batch**, naming only the files that would lose a form — each
    /// read in its own lane turn, so the lane is given back between files here too.
    private func formWarning(for tool: EditorPDFBatchTool, cancelled flag: CancelFlag) async -> EditorPDFBatchWarning? {
        let edit = tool.tool(pageCount: 0)
        guard edit.formLoss != nil else { return nil }
        var atRisk: [String] = []
        var warning: OutputFidelityWarning?
        for file in files {
            if flag.isCancelled { return nil }
            // Not a file still in the cloud: reading its form opens it in PDFKit, which downloads
            // it — the very read ``runOne(_:at:flag:)`` skips it to avoid.
            if isCloudOnly(MaterializationStatus.linkTarget(of: file.path)) { continue }
            let input = URL(fileURLWithPath: EditorFileStore.resolved(file.path))
            if let found = await EditorPDFToolEngine.fidelityWarning(for: edit, input: input) {
                atRisk.append(file.name)
                warning = warning ?? found
            }
        }
        guard let warning, !atRisk.isEmpty else { return nil }
        return EditorPDFBatchWarning(names: atRisk, of: files.count, warning: warning, toolTitle: edit.title)
    }

    static func confirmWithAlert(_ warning: EditorPDFBatchWarning) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.title
        alert.informativeText = warning.detail
        alert.addButton(withTitle: warning.warning.confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: The ending

    /// One log line per file, naming the workspace — never "Edit", which ran nothing here.
    private func log(_ file: File, tool: EditorPDFBatchTool) {
        let detail = tool.logDetail
        // Edit's log name — the folder too, so two same-named PDFs are told apart.
        let name = EditorPDFTools.logName(file.path)
        switch file.status {
        case .wrote(let copy, let sizes):
            Logger.shared.info("\(writer) wrote \((copy as NSString).lastPathComponent) from \(name) — "
                               + detail + (sizes.map { ", \($0)" } ?? ""))
        case .skipped(let skip):
            Logger.shared.info("\(writer) skipped \(name) for \(detail) — \(skip.reason)")
        case .failed(let message):
            Logger.shared.info("\(writer) could not \(detail) of \(name) — \(message)")
        case .waiting, .running:
            break
        }
    }

    private func finish(_ tool: EditorPDFBatchTool, cancelled: Bool) {
        let copies = files.compactMap { file -> String? in
            if case .wrote(let copy, _) = file.status { return copy }
            return nil
        }
        // The panes re-read once per folder a copy landed in, not once per copy.
        var folders: Set<String> = []
        for copy in copies where folders.insert((copy as NSString).deletingLastPathComponent).inserted {
            host.didWrite(copy)
        }
        let message = Self.summary(files.map(\.status), tool: tool, cancelled: cancelled,
                                   unrestricted: unrestrictedCopies)
        let kind: EditorPDFToolBanner.Kind
        switch copies.count {
        case 0: kind = files.contains { if case .failed = $0.status { return true }; return false } ? .failure : .note
        case 1: kind = .wrote(copies[0])
        default: kind = .wroteSeveral(copies)
        }
        banner = EditorPDFToolBanner(message: message, kind: kind,
                                     detail: Self.reasons(files.map { ($0.name, $0.status) }))
        // The sheet goes; the reasons its rows showed stay in the banner's detail.
        showsSheet = false
    }

    /// "Saved 2 compressed copies · 1 skipped · 1 failed" — what was written, then how many were
    /// skipped and how many failed; ``reasons(_:)`` says which, and why, on the line under it.
    ///
    /// `unrestricted` copies came from originals whose owner restricted editing, and do not carry
    /// the restrictions — "· 1 has no editing restrictions", right after what was written.
    static func summary(_ statuses: [Status], tool: EditorPDFBatchTool, cancelled: Bool,
                        unrestricted: Int = 0) -> String {
        var wrote = 0, skipped = 0, notDone = 0, failed = 0
        for status in statuses {
            switch status {
            case .wrote: wrote += 1
            case .skipped(.cancelled): notDone += 1
            case .skipped: skipped += 1
            case .failed: failed += 1
            case .waiting, .running: break
            }
        }
        let noun = tool.copyNoun
        var parts = [wrote == 0 ? "Nothing was saved" : "Saved \(wrote) \(wrote == 1 ? noun.one : noun.many)"]
        if unrestricted > 0 {
            parts.append(unrestricted == 1 ? "1 has no editing restrictions" : "\(unrestricted) have no editing restrictions")
        }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if notDone > 0 { parts.append("\(notDone) not done") }
        if failed > 0 { parts.append("\(failed) failed") }
        return (cancelled ? "Canceled. " : "") + parts.joined(separator: " · ")
    }

    /// The most files ``reasons(_:)`` names before "and N more" — the banner floats over the panes.
    static let reasonsShown = 5

    /// **Which files were skipped or failed, and why** — "“Scan 3.pdf” — locked with a password", one
    /// per line, in the batch's order: the rows of the sheet that closed, for what went wrong. The
    /// files Cancel never reached are not named; the summary counts them as "not done".
    ///
    /// **A file skipped for its owner's restrictions ends the reasons with the way past them** —
    /// Remove Password writes a copy without them, the step the single file's refusal names
    /// (``EditorPDFToolEngine/liftRestrictionsStep``). Once, however many such files there are, and
    /// for Clean Metadata's encrypted skip too: a file that reaches it opened without a password.
    static func reasons(_ files: [(name: String, status: Status)]) -> String? {
        let lines = files.compactMap { file -> String? in
            switch file.status {
            case .skipped(.cancelled): return nil
            case .skipped(let skip): return "“\(file.name)” — \(skip.reason)"
            case .failed(let message): return "“\(file.name)” — \(message)"
            case .waiting, .running, .wrote: return nil
            }
        }
        guard !lines.isEmpty else { return nil }
        let shown = lines.prefix(reasonsShown)
        let more = lines.count - shown.count
        let restricted = files.contains { $0.status == .skipped(.restrictedByOwner) }
        let encrypted = files.contains { $0.status == .skipped(.passwordProtected) }
        var all: [String] = Array(shown)
        if more > 0 { all.append("and \(more) more") }
        if restricted { all.append(EditorPDFToolEngine.liftRestrictionsStep) }
        if encrypted { all.append(EditorPDFToolEngine.decryptStep) }
        return all.joined(separator: "\n")
    }
}

/// **The batch's one form question** — "1 of 3 files has a form that will stop being fillable",
/// the files named, then the toolkit's own sentences for what goes and what is kept.
public struct EditorPDFBatchWarning: Equatable, Sendable {
    public var names: [String]
    public var of: Int
    public var warning: OutputFidelityWarning
    public var toolTitle: String

    public var title: String {
        let has = names.count == 1 ? "has a form" : "have forms"
        return "\(names.count) of \(of) files \(has) that will stop being fillable"
    }

    public var detail: String {
        ([names.joined(separator: ", ")] + warning.detailLines(toolTitle: toolTitle) + [warning.keptLine])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
