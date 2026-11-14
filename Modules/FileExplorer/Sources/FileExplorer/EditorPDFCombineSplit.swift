import AppKit
import Combine
import Events
import PDFKit
import PDFToolkitCore
import Sync

/// Combines several PDFs into one, or splits one into several, from a pane's menu. One model for
/// both: each is one run of several steps with one sheet, one capsule entry and one ending, as a
/// batch is.
///
/// Combine reads each file in its own lane turn first (one locked to open stops the run with its
/// name, since the merge can't open it), then merges them in order in one turn (the toolkit's
/// `mergeData`) and writes one new file into the first file's folder under the typed name, with
/// the app's keep-both rule. The originals are only read.
///
/// Split is Extract, once per part, through Edit's own ``EditorPDFTools``: each part is named and
/// written exactly as an extract of those pages is, "Statement (pages 4–8).pdf". Stop ends the run
/// after the part in hand; the parts written stay.
@MainActor
public final class EditorPDFCombineSplit: ObservableObject, Identifiable {

    public enum Job: Equatable, Sendable {
        /// The files, in the order the menu had them.
        case combine([String])
        case split(String)
    }

    /// The part in hand: part 2 of 3, or for Combine, file 2 of 3 read and then the merge.
    public struct Progress: Equatable, Sendable {
        public var step: Int
        public var steps: Int
        public var detail: String
    }

    public let id = UUID()
    public let job: Job
    let writer: String
    /// Set by the window; a no-op otherwise.
    public var host = PanePDFToolHost()

    /// Combine's files in the order they will go in; the sheet's ↑ and ↓ move them.
    @Published public var order: [String] = []
    /// Combine's new file's name, as typed: the first file's with "(combined)" to start with.
    @Published public var name = ""
    /// Split's "Start new files at pages" field, as typed.
    @Published public var splitAt = ""

    /// What the lane read of Split's file before the sheet opened.
    @Published public private(set) var pageCount = 0
    /// Split's form question, said in the sheet rather than asked in an alert: what every part loses.
    @Published public private(set) var formNote: String?

    @Published public private(set) var progress: Progress?
    @Published public private(set) var isRunning = false
    /// Between the request and the sheet: Split's lane read.
    @Published public private(set) var isPreparing = false
    @Published public var showsSheet = false
    public private(set) var startedAt: Date?
    @Published public var banner: EditorPDFToolBanner?

    var isCloudOnly: @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }
    /// For a run a request made: the ending is left off ``banner`` (the asker reads ``lastReport``
    /// and ``written``) and no sheet is raised.
    var quiet = false
    /// The stamp each file had when the asker read it, by path; a file that changed since is
    /// left alone. Empty for a menu, whose sheet read the file itself.
    var expected: [String: EditorFileStore.Stamp] = [:]
    /// Where the new files go instead of beside the first file or the original: a request's chosen
    /// folder, for one that can't be written to. `nil` for the menu.
    var destinationFolder: String?
    private(set) var lastReport: EditorPDFToolBanner?
    /// Every file the last run wrote, with the stamp of the file the writer made.
    public private(set) var written: [PDFWrittenFile] = []
    /// How many files the last run set out to write: Combine's one, or Split's parts.
    private(set) var asked = 0
    private var stopRequested = false
    private var facts: (encryption: PDFEncryptionState, droppedParts: [PDFToolkit.DroppedCatalogPart],
                        stamp: EditorFileStore.Stamp?)?
    /// The request's own work, kept so a test can await it.
    private(set) var work: Task<Void, Never>?

    public init(job: Job, writer: String) {
        self.job = job
        self.writer = writer
        if case .combine(let paths) = job {
            order = paths
            name = paths.first.map(Self.defaultName) ?? ""
        }
    }

    // MARK: Asking

    /// Readies the sheet. Combine opens it at once; Split first reads its file's page count and
    /// protection in the lane, and says in the banner why it can't split, if it can't. A request's
    /// run (``quiet``) reads the same and raises no sheet.
    func prepare() {
        switch job {
        case .combine:
            showsSheet = !quiet
        case .split(let path):
            let name = (path as NSString).lastPathComponent
            if isCloudOnly(MaterializationStatus.linkTarget(of: path)) {
                refuseToPrepare(EditorPDFToolBanner(message: EditorPDFTools.cloudOnlyReason(name), kind: .note, download: path))
                return
            }
            isPreparing = true
            work = Task { @MainActor in
                defer { isPreparing = false }
                let input = URL(fileURLWithPath: EditorFileStore.resolved(path))
                let stamp = EditorFileStore.stamp(ofPath: path)
                guard case .facts(let pages, let encryption, let dropped) = await EditorPDFToolEngine.probe(input) else {
                    refuseToPrepare(EditorPDFToolBanner(message: PanePDFTools.unreadableReason(name), kind: .failure))
                    return
                }
                if encryption == .lockedToOpen {
                    refuseToPrepare(EditorPDFToolBanner(message: EditorPDFTools.lockedReason, kind: .note))
                    return
                }
                guard pages > 1 else {
                    refuseToPrepare(EditorPDFToolBanner(message: "“\(name)” has one page, so there’s nothing to split.", kind: .note))
                    return
                }
                pageCount = pages
                facts = (encryption, dropped, stamp)
                formNote = await EditorPDFToolEngine.fidelityWarning(for: .extract([0]), input: input)
                    .map { _ in Self.splitFormNote }
                showsSheet = !quiet
            }
        }
    }

    /// Why Split can't be readied: on the pane's banner for the menu; for a request, only where the
    /// asker reads it, since the pane's layer takes anything set on ``banner``.
    private(set) var prepareRefusal: EditorPDFToolBanner?

    private func refuseToPrepare(_ said: EditorPDFToolBanner) {
        if quiet { prepareRefusal = said } else { banner = said }
    }

    static let splitFormNote = "Its fillable form won’t work in the new files."
    public static let combineNote = "The combined file keeps no bookmarks and no fillable forms."

    // MARK: Combine's name

    /// "Receipt (combined).pdf": the first file's name, as every tool names its copy.
    public static func defaultName(_ first: String) -> String {
        (EditorPDFCopyName.firstChoice(for: first, suffix: "combined") as NSString).lastPathComponent
    }

    /// The typed name with ".pdf", or why it can't be one. Counted as the writer counts a name
    /// (``EditorPDFCopyName/nameLength(_:)``), so a name this passes is one the write takes.
    static func fileName(_ typed: String) -> Result<String, NameProblem> {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.empty) }
        if (name as NSString).pathExtension.lowercased() != "pdf" { name += ".pdf" }
        if name.contains("/") || name.contains(":") { return .failure(.separator) }
        if name.hasPrefix(".") { return .failure(.dot) }
        if EditorPDFCopyName.nameLength(name) > EditorPDFCopyName.longestName { return .failure(.tooLong) }
        return .success(name)
    }

    public enum NameProblem: Error, Equatable {
        case empty, separator, dot, tooLong

        public var sentence: String {
            switch self {
            case .empty: return "Type a name for the combined file."
            case .separator: return "A name can’t contain “/” or “:”."
            case .dot: return "A name can’t start with a dot."
            case .tooLong: return "That name is too long."
            }
        }
    }

    /// Moves Combine's file at `index` one place up (`-1`) or down (`1`).
    public func move(_ index: Int, by step: Int) {
        let target = index + step
        guard order.indices.contains(index), order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }

    /// Whether Combine's rows need their folder beside the name: the files aren't all in one.
    public var rowsShowFolders: Bool {
        Set(order.map { ($0 as NSString).deletingLastPathComponent }).count > 1
    }

    // MARK: Split's parts

    /// The parts for "4, 9" on a 12-page file: pages 1–3, 4–8, 9–12, zero-based and in order, or
    /// why the typed starts can't be. Each start is the page a new file begins on, so 1 and anything
    /// past the last page are refused; starts must go up; at most ``maxParts`` parts.
    static func parts(_ typed: String, pageCount: Int) -> Result<[[Int]], SplitProblem> {
        let tokens = typed.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
        guard !tokens.isEmpty else { return .failure(.empty) }
        var starts: [Int] = []
        for token in tokens {
            guard let page = Int(token) else { return .failure(.notANumber(token)) }
            guard page >= 2, page <= pageCount else { return .failure(.outOfRange(page, pageCount)) }
            if let last = starts.last, page <= last { return .failure(.notIncreasing) }
            starts.append(page)
        }
        guard starts.count < maxParts else { return .failure(.tooMany) }
        let bounds = [1] + starts + [pageCount + 1]
        return .success(zip(bounds, bounds.dropFirst()).map { Array(($0 - 1)..<($1 - 1)) })
    }

    nonisolated static let maxParts = 20

    public enum SplitProblem: Error, Equatable {
        case empty
        case notANumber(String)
        case outOfRange(Int, Int)
        case notIncreasing
        case tooMany

        public var sentence: String {
            switch self {
            case .empty: return "Type the pages new files start at, like 4, 9."
            case .notANumber(let token): return "“\(token)” isn’t a page number."
            case .outOfRange(let page, let count):
                return page < 2 ? "The first file always starts at page 1 — type where the next ones start."
                    : "Page \(page) is past the end: this PDF has \(count) pages."
            case .notIncreasing: return "Type the pages in order, each after the one before."
            case .tooMany: return "That’s more than \(EditorPDFCombineSplit.maxParts) files — split it in fewer places."
            }
        }
    }

    // MARK: Running

    public func stop() {
        stopRequested = true
    }

    /// Runs the job with what the sheet holds. The sheet goes; the run is in the capsule.
    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        startedAt = Date()
        stopRequested = false
        showsSheet = false
        banner = nil
        lastReport = nil
        written = []
        asked = 0
        defer {
            isRunning = false
            progress = nil
        }
        switch job {
        case .combine: await runCombine()
        case .split(let path): await runSplit(path)
        }
    }

    private func runCombine() async {
        let inputs = order
        guard inputs.count > 1, case .success(let fileName) = Self.fileName(name), let first = inputs.first else { return }
        asked = 1
        var restricted = 0
        var pages = 0
        for (index, path) in inputs.enumerated() {
            let name = (path as NSString).lastPathComponent
            if stopRequested { return end(stoppedNote) }
            progress = Progress(step: index + 1, steps: inputs.count + 1, detail: name)
            if isCloudOnly(MaterializationStatus.linkTarget(of: path)) {
                return end(EditorPDFToolBanner(message: EditorPDFTools.cloudOnlyReason(name), kind: .failure, download: path))
            }
            guard let stamp = EditorFileStore.stamp(ofPath: path) else {
                return end(EditorPDFToolBanner(message: "“\(name)” \(EditorPDFBatch.goneReason).", kind: .failure))
            }
            if let want = expected[path], stamp != want {
                return end(EditorPDFToolBanner(message: PanePDFTools.changedSinceAskedReason(name), kind: .failure))
            }
            switch await EditorPDFToolEngine.probe(URL(fileURLWithPath: EditorFileStore.resolved(path))) {
            case .unreadable:
                return end(EditorPDFToolBanner(message: PanePDFTools.unreadableReason(name), kind: .failure))
            case .facts(_, .lockedToOpen, _):
                return end(EditorPDFToolBanner(message: "“\(name)” is locked with a password. Remove it first, then combine.",
                                               kind: .failure))
            case .facts(let count, let encryption, _):
                pages += count
                if encryption == .restrictedOnly { restricted += 1 }
            }
        }
        if stopRequested { return end(stoppedNote) }
        progress = Progress(step: inputs.count + 1, steps: inputs.count + 1, detail: "Combining")
        let urls = inputs.map { URL(fileURLWithPath: EditorFileStore.resolved($0)) }
        // The page count is the merged file's own, read in the same turn: the probes above were
        // earlier turns, and a file could have changed in between.
        let merged = await PDFKitSerialAccess.perform { () -> Result<(Data, Int), Error> in
            Result {
                let data = try PDFToolkit.mergeData(inputs: urls.map { (url: $0, pageIndices: nil) })
                return (data, PDFDocument(data: data)?.pageCount ?? 0)
            }
        }
        if stopRequested { return end(stoppedNote) }
        // Asked again with the bytes in hand: the merge read every file once more.
        for path in inputs {
            if let want = expected[path], EditorFileStore.stamp(ofPath: path) != want {
                return end(EditorPDFToolBanner(message: PanePDFTools.changedSinceAskedReason((path as NSString).lastPathComponent),
                                               kind: .failure))
            }
        }
        let folder = destinationFolder ?? (first as NSString).deletingLastPathComponent
        let wanted = (folder as NSString).appendingPathComponent(fileName)
        switch merged.map({ $0.0 }) {
        case .failure(let error):
            Logger.shared.warning("\(writer) could not combine \(inputs.count) PDFs — \(error.localizedDescription)")
            return end(EditorPDFToolBanner(message: "Couldn’t combine them — \(error.localizedDescription)", kind: .failure))
        case .success(let data):
            let written = await Task.detached(priority: .userInitiated) {
                Result { try EditorPDFCopyWriter.writeStamped(data, wanting: wanted) }
            }.value
            switch written {
            case .failure(let error):
                return end(EditorPDFToolBanner(message: "Couldn’t write the combined file — \(error.localizedDescription)",
                                               kind: .failure))
            case .success(let landed):
                // Stop pressed while it was written still means nothing is written, as the
                // capsule's Stop says: the file just made goes, if it is still the one made.
                if stopRequested {
                    guard EditorFileStore.stamp(ofPath: landed.path) == landed.stamp else { return end(stoppedNote) }
                    do {
                        try FileManager.default.removeItem(atPath: landed.path)
                    } catch {
                        // Said, not swallowed: the file is still there, so "Nothing was written" would be false.
                        let copyName = (landed.path as NSString).lastPathComponent
                        Logger.shared.warning("\(writer) stopped combining \(inputs.count) PDFs, but couldn't remove "
                                              + "\(landed.path): \(error.localizedDescription)")
                        return end(EditorPDFToolBanner(
                            message: "Stopped, but “\(copyName)” couldn’t be removed — it’s still in the folder.",
                            kind: .failure))
                    }
                    return end(stoppedNote)
                }
                if case .success(let (_, count)) = merged, count > 0 { pages = count }
                let copyName = (landed.path as NSString).lastPathComponent
                Logger.shared.info("\(writer) combined \(inputs.count) PDFs into \(copyName) — \(pages) pages")
                self.written.append(PDFWrittenFile(source: first, path: landed.path, stamp: landed.stamp, bytes: data.count,
                                              pageCount: pages))
                host.didWrite(landed.path)
                var message = "Saved “\(copyName)” — \(SaveAsPDFSummary.pages(pages)) from \(inputs.count) PDFs"
                if restricted > 0 { message += ". It has no editing restrictions" }
                end(EditorPDFToolBanner(message: message, kind: .wrote(landed.path)))
            }
        }
    }

    private func runSplit(_ path: String) async {
        guard let facts, case .success(let parts) = Self.parts(splitAt, pageCount: pageCount) else { return }
        let source = (path as NSString).lastPathComponent
        asked = parts.count
        let tools = EditorPDFTools()
        tools.writer = writer
        tools.isCloudOnly = isCloudOnly
        tools.quiet = true
        // Said in the sheet already, once for every part.
        tools.confirm = { _, _ in true }
        tools.attach(path: path, pageCount: pageCount, encryption: facts.encryption, droppedParts: facts.droppedParts)
        // The file as the sheet read it: one changed since is not split by its old page numbers.
        tools.shownStamp = expected[path] ?? facts.stamp
        tools.changedMessage = PanePDFTools.changedSinceAskedReason
        tools.destinationFolder = destinationFolder
        let host = self.host
        tools.host = EditorPDFToolHost(didWrite: host.didWrite)
        var copies: [String] = []
        parts: for (index, part) in parts.enumerated() {
            if stopRequested { break }
            progress = Progress(step: index + 1, steps: parts.count,
                                detail: EditorPDFCopyName.pageList(part))
            switch await tools.run(.extract(part)) {
            case .wrote(let copy):
                copies.append(copy)
                if let landed = tools.lastWrite { written.append(landed) }
            case .failed(let message):
                return end(EditorPDFToolBanner(
                    message: copies.isEmpty ? message : "Saved \(copies.count) of \(parts.count) files from “\(source)”. \(message)",
                    kind: copies.isEmpty ? .failure : .wroteSeveral(copies)))
            case .nothingWritten(let message):
                return end(EditorPDFToolBanner(message: message, kind: .note))
            case .cancelled, .declined:
                break parts
            }
        }
        Logger.shared.info("\(writer) split \(Self.logName(path)) into \(copies.count) of \(parts.count) files")
        if copies.count < parts.count {
            return end(EditorPDFToolBanner(message: "Stopped. Saved \(copies.count) of \(parts.count) files from “\(source)”.",
                                           kind: copies.isEmpty ? .note : .wroteSeveral(copies)))
        }
        end(EditorPDFToolBanner(message: "Saved \(copies.count) files from “\(source)”", kind: .wroteSeveral(copies)))
    }

    private var stoppedNote: EditorPDFToolBanner {
        EditorPDFToolBanner(message: "Stopped. Nothing was written.", kind: .note)
    }

    private func end(_ ending: EditorPDFToolBanner) {
        lastReport = ending
        if !quiet { banner = ending }
    }

    private static func logName(_ path: String) -> String { (path as NSString).lastPathComponent }
}
