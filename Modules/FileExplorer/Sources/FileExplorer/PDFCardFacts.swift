import AppKit
import os
import PDFKit
import PDFToolkitCore
import Sync

/// **What an Ask Claude PDF card says about a file before the click** (TE294 step 3): its pages,
/// size and protection, how many form fields it has, whether its folder takes a new file, and what
/// a given tool's copy would lose — in the words the tool's own sheet uses — with the stamp it was
/// read at, which the run then holds the file to.
public struct PDFCardFacts: Equatable, Sendable {
    public enum Protection: String, Codable, Sendable {
        case none
        /// Encrypted with its owner's restrictions; it opens without a password.
        case restricted
        /// Needs a password to open. Its pages aren't counted until it is unlocked.
        case locked
    }

    public var pageCount: Int
    public var protection: Protection
    public var bytes: Int
    public var stamp: EditorFileStore.Stamp
    public var fieldCount: Int
    /// What the copy would lose, one sentence each; empty when nothing.
    public var losses: [String]
    public var folderIsWritable: Bool
}

/// How a read of a card's file ended.
public enum PDFCardRead: Equatable, Sendable {
    case facts(PDFCardFacts)
    /// Only in the cloud: nothing reads it until it is downloaded.
    case cloudOnly
    case gone
    case unreadable
    /// The PDF lane didn't answer in time — a long scan holds it. Try again later.
    case busy
}

public enum PDFCardFactsReader {
    /// The longest a card waits on the lane before saying "busy" rather than holding Claude's turn.
    public static let laneWait: Duration = .seconds(5)

    /// **Reads `path` for a card that would run `tool`** — off the main thread, in one bounded
    /// turn of the app's one PDF lane. Nothing reads a file only in the cloud: that would download it.
    @MainActor
    public static func read(_ path: String, for tool: EditorPDFTool, timeout: Duration = laneWait,
                            isCloudOnly: @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) })
    async -> PDFCardRead {
        if isCloudOnly(MaterializationStatus.linkTarget(of: path)) { return .cloudOnly }
        guard let stamp = EditorFileStore.stamp(ofPath: path) else { return .gone }
        let input = URL(fileURLWithPath: EditorFileStore.resolved(path))
        let folderIsWritable = SaveAsPDFName.folderIsWritable(for: path)
        guard let read = await bounded(timeout, { laneRead(input, tool: tool) }) else { return .busy }
        guard let lane = read else { return .unreadable }
        return .facts(PDFCardFacts(pageCount: lane.pageCount, protection: lane.protection, bytes: stamp.size,
                                   stamp: stamp, fieldCount: lane.fieldCount,
                                   losses: losses(tool, lane: lane), folderIsWritable: folderIsWritable))
    }

    /// What the lane turn learns.
    struct LaneFacts: Sendable {
        var pageCount: Int
        var protection: PDFCardFacts.Protection
        var fieldCount: Int
        var formLoss: Bool
        var droppedParts: [PDFToolkit.DroppedCatalogPart]
    }

    /// Called in the lane. `nil` for a file PDFKit can't open.
    nonisolated static func laneRead(_ input: URL, tool: EditorPDFTool) -> LaneFacts? {
        guard let document = PDFDocument(url: input) else { return nil }
        if document.isLocked {
            return LaneFacts(pageCount: 0, protection: .locked, fieldCount: 0, formLoss: false, droppedParts: [])
        }
        let protection: PDFCardFacts.Protection = document.isEncrypted ? .restricted : .none
        let fields = (try? PDFToolkit.formFields(at: input))?.count ?? 0
        let formLoss = fields > 0
            && OutputFidelityWarning.detect(in: [input], formLoss: tool.formLoss, checksBookmarks: false) != nil
        return LaneFacts(pageCount: document.pageCount, protection: protection, fieldCount: fields,
                         formLoss: formLoss, droppedParts: PDFToolkit.droppedCatalogParts(in: document))
    }

    /// **The tool's losses for this file, only those it has** — Compress's redraw always, since
    /// every file has text to lose.
    @MainActor
    static func losses(_ tool: EditorPDFTool, lane: LaneFacts) -> [String] {
        var said: [String] = []
        if case .compress = tool { said.append(compressRedraw) }
        if lane.formLoss {
            said.append(tool.formLoss == .formFlattened ? formFlattened : formStopsWorking)
        }
        if tool.dropsCatalogParts(fileHasForm: lane.fieldCount > 0), let note = EditorPDFTools.droppedPartsNote(lane.droppedParts) {
            said.append(note)
        }
        if lane.protection == .restricted, tool.rebuildsDocument { said.append(restrictionsGo) }
        return said
    }

    public static let compressRedraw = "Every page becomes a picture, so the copy’s text can’t be selected or searched."
    public static let formFlattened = "Its form stops being fillable in the copy."
    public static let formStopsWorking = "Its fillable form won’t work in the copy."
    public static let restrictionsGo = "The copy won’t keep its owner’s editing restrictions."

    /// **Runs `body` in the lane, or answers `nil` once `timeout` passes** — whichever comes first.
    /// The lane itself can't be interrupted: a turn that has started runs to its end. Past the
    /// timeout the queued turn is cancelled, so when it comes it does nothing.
    static func bounded<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () -> T) async -> T? {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        let finish: @Sendable (T?) -> Void = { value in
            let continuation = pending.withLock { held -> CheckedContinuation<T?, Never>? in
                defer { held = nil }
                return held
            }
            continuation?.resume(returning: value)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            pending.withLock { $0 = continuation }
            let work = Task.detached {
                if let value = await PDFKitSerialAccess.performUnlessCancelled(body) { finish(value) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                work.cancel()
                finish(nil)
            }
        }
    }
}

/// **Small pictures of a card's pages** (TE294 step 3) — the pages a tool acts on, with one either
/// side, drawn in the lane and handed back as `CGImage`s: `NSImage` can't cross actors.
public enum PDFCardThumbnails {
    /// The pages a card draws for `pages` of `pageCount`: each one, with one page either side, and
    /// `nil` where a run of others is left out — so a 300-page file still fits a card.
    public static func shown(_ pages: [Int], pageCount: Int) -> [Int?] {
        var keep = Set<Int>()
        for page in pages where page >= 0 && page < pageCount {
            keep.formUnion([page - 1, page, page + 1].filter { $0 >= 0 && $0 < pageCount })
        }
        var out: [Int?] = []
        var last: Int?
        for page in keep.sorted() {
            if let last, page > last + 1 { out.append(nil) }
            out.append(page)
            last = page
        }
        return out
    }

    /// The pages drawn `height` points tall, by page; `nil` when the lane didn't answer in time.
    public static func render(_ path: String, pages: [Int], height: CGFloat,
                              timeout: Duration = PDFCardFactsReader.laneWait,
                              isCloudOnly: @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) })
    async -> [Int: CGImage]? {
        // Nothing reads a file only in the cloud: that would download it.
        if isCloudOnly(MaterializationStatus.linkTarget(of: path)) { return nil }
        let input = URL(fileURLWithPath: EditorFileStore.resolved(path))
        let boxed = await PDFCardFactsReader.bounded(timeout) { () -> [Int: SendableImage] in
            guard let document = PDFDocument(url: input), !document.isLocked else { return [:] }
            var images: [Int: SendableImage] = [:]
            for index in pages {
                guard let page = document.page(at: index) else { continue }
                // A page turned a quarter is drawn turned: its picture is the box on its side.
                var box = page.bounds(for: .cropBox).size
                if page.rotation % 180 != 0 { box = CGSize(width: box.height, height: box.width) }
                let scale = box.height > 0 ? height / box.height : 1
                let size = NSSize(width: max(1, box.width * scale), height: height)
                if let image = page.thumbnail(of: size, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    images[index] = SendableImage(image)
                }
            }
            return images
        }
        return boxed?.mapValues(\.cgImage)
    }
}

public extension EditorPDFTool {
    /// Clean Metadata as a card runs it: every field cleared, as a batch does — without the app
    /// target having to name the toolkit's fields type.
    static var cleanMetadataCleared: EditorPDFTool { .cleanMetadata(.cleared) }
}

/// **Pages typed on a card**, read as Edit's page-range sheet reads them — an en dash is a hyphen,
/// "every page" can't be deleted — so a card and the sheet agree on what "3–5" means.
@MainActor
public enum PDFCardPages {
    /// Zero-based pages for Extract (in the order typed) or Delete, or the sheet's sentence for why not.
    public static func parse(_ text: String, extract: Bool, pageCount: Int) -> Result<[Int], PDFCardPagesProblem> {
        let read = EditorPDFPageRangeSheet.parse(text, action: extract ? .extract : .delete, pageCount: pageCount)
        guard let pages = read.pages else { return .failure(PDFCardPagesProblem(sentence: read.caption)) }
        return .success(pages)
    }

    /// One-based, runs collapsed: [2, 3, 4, 0] → "3–5, 1".
    public static func label(_ pages: [Int]) -> String { EditorPDFCopyName.runs(pages, dash: "–") }
}

public struct PDFCardPagesProblem: Error, Equatable, Sendable {
    public let sentence: String
}

/// **The name a card's new file starts as** (TE294) — the menus' own naming, before the write. The
/// keep-both rule may still add a number when a file of that name is there by then, so a card says
/// it as the plan and the report says what was written.
public enum PDFPlannedName {
    /// A tool's copy: "Scan (compressed).pdf", "Statement (pages 3–5).pdf".
    public static func copy(of original: String, tool: EditorPDFTool) -> String {
        (EditorPDFCopyName.firstChoice(for: original, suffix: tool.suffix) as NSString).lastPathComponent
    }

    /// Save as PDF's: the original's name with ".pdf".
    public static func saveAsPDF(_ original: String) -> String {
        (SaveAsPDFName.firstChoice(for: original) as NSString).lastPathComponent
    }

    /// Split's parts, starting at the one-based pages given: "Statement (page 1).pdf", …
    @MainActor
    public static func splitParts(of original: String, at starts: [Int], pageCount: Int) -> [String] {
        guard case .success(let parts) = EditorPDFCombineSplit.parts(starts.map(String.init).joined(separator: ","),
                                                                    pageCount: pageCount) else { return [] }
        return parts.map { copy(of: original, tool: .extract($0)) }
    }
}
