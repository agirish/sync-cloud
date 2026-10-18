import AppKit
import Combine
import Events
import os
import PDFToolkitCore
import Sync

/// What the app does around a tool's copy — the half of a run that needs the window.
public struct EditorPDFToolHost {
    /// A copy landed at this path: the rail and the panes re-list (Export as PDF's follow-up).
    public var didWrite: (String) -> Void
    /// The banner's Open — the copy in Edit, through the same door a rail click takes.
    public var open: (String) -> Void
    /// The banner's Reveal in Browse.
    public var reveal: (String) -> Void

    public init(didWrite: @escaping (String) -> Void = { _ in },
                open: @escaping (String) -> Void = { _ in },
                reveal: @escaping (String) -> Void = { _ in }) {
        self.didWrite = didWrite
        self.open = open
        self.reveal = reveal
    }
}

/// What a run says once it is over, at the top of the PDF card.
public struct EditorPDFToolBanner: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A copy was written at this path — the banner offers Open and Reveal in Browse.
        case wrote(String)
        /// Nothing went wrong and nothing was written — "already about as small as this gets".
        case note
        case failure
    }
    public let id = UUID()
    public var message: String
    public var kind: Kind
}

/// How a run ended — what a sheet needs to decide whether to close.
public enum EditorPDFToolOutcome: Equatable, Sendable {
    case wrote(String)
    /// Ran (or decided not to run) and wrote nothing, for a reason that is not a failure.
    case nothingWritten(String)
    case cancelled
    /// The reader turned the fidelity confirmation down.
    case declined
    case failed(String)
}

/// The sheet the header or the Pages tab asked for.
public enum EditorPDFToolSheet: Identifiable, Equatable, Sendable {
    case pages(EditorPDFPageAction, prefill: String)
    case compress
    case metadata
    case protect
    case removePassword

    public var id: String {
        switch self {
        case .pages(let action, _): return "pages-\(action)"
        case .compress: return "compress"
        case .metadata: return "metadata"
        case .protect: return "protect"
        case .removePassword: return "remove-password"
        }
    }
}

public enum EditorPDFPageAction: String, Sendable {
    case extract
    case delete
}

/// **The Pages tab's selection** — click, ⌘-click and ⇧-click over the pages as they are SHOWN,
/// which during a pending reorder is not page order.
public struct EditorPDFPageSelection: Equatable, Sendable {
    public private(set) var pages: Set<Int> = []
    /// Where ⇧-click extends from.
    public private(set) var anchor: Int?

    public enum Click: Sendable { case plain, toggle, extend }

    public static func click(for flags: NSEvent.ModifierFlags) -> Click {
        if flags.contains(.command) { return .toggle }
        if flags.contains(.shift) { return .extend }
        return .plain
    }

    /// `order` is the pages as shown, zero-based page indices.
    public mutating func click(_ page: Int, _ click: Click, order: [Int]) {
        switch click {
        case .plain:
            pages = [page]
            anchor = page
        case .toggle:
            if pages.contains(page) { pages.remove(page) } else { pages.insert(page) }
            anchor = page
        case .extend:
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: page) else {
                pages = [page]
                self.anchor = page
                return
            }
            pages.formUnion(order[min(from, to)...max(from, to)])
        }
    }

    public mutating func clear() {
        pages = []
        anchor = nil
    }

    /// The pages a menu on `page` acts on: the selection when the page is in it, else that page.
    public func target(for page: Int, order: [Int]) -> [Int] {
        guard pages.contains(page) else { return [page] }
        return order.filter(pages.contains)
    }
}

/// **A reorder the reader has dragged and not saved** — the pages in their new order.
public enum EditorPDFArrangement {
    /// `moving` dropped onto `target`: they take its place, after it when dragged forward and
    /// before it when dragged back — the way a dragged row lands in a Finder list.
    public static func moving(_ moving: [Int], onto target: Int, in order: [Int]) -> [Int] {
        let moved = order.filter(Set(moving).contains)
        guard !moved.isEmpty, !moved.contains(target),
              let first = order.firstIndex(of: moved[0]), let targetAt = order.firstIndex(of: target)
        else { return order }
        var rest = order.filter { !moved.contains($0) }
        guard let inRest = rest.firstIndex(of: target) else { return order }
        rest.insert(contentsOf: moved, at: first < targetAt ? inRest + 1 : inRest)
        return rest
    }
}

/// **Edit's PDF tools: the selection, a pending reorder, a run, and what it said.** A sibling of
/// ``EditorPDFViewState`` on ``EditorPDFDocument`` — observed by the header's Tools menu, the Pages
/// tab and the card's banner, and by nothing that redraws the window.
///
/// **Every tool writes a NEW copy and never touches the open file**, so nothing here registers undo
/// (as Export as PDF and ⌘N do not): a copy destroys nothing, and removing it is an ordinary Trash.
/// The open file stays open — and read-only — and opening the copy is the reader's choice, from
/// the banner.
@MainActor
public final class EditorPDFTools: ObservableObject {

    /// The file the tools act on — the reader's — or `nil` with nothing open.
    public private(set) var path: String?
    @Published public private(set) var pageCount = 0
    /// How the file on disk is protected, read in the lane when it opened. `nil` until then.
    @Published public private(set) var encryption: PDFEncryptionState?
    @Published public private(set) var selection = EditorPDFPageSelection()
    /// A dragged order not yet saved, or `nil`. Never the identity: a drag back to where the pages
    /// were is no arrangement at all.
    @Published public private(set) var arrangement: [Int]?
    /// The run in flight, or `nil` — one at a time.
    @Published public private(set) var running: Running?
    @Published public var sheet: EditorPDFToolSheet?
    @Published public var banner: EditorPDFToolBanner?

    /// "page N of M", from Compress — as it reached the main actor. Cleared when a run starts, and
    /// left on the last page when it ends; it is shown only while ``running`` is set.
    @Published public private(set) var progress: Progress?

    public struct Running: Equatable {
        public var tool: String
    }

    public struct Progress: Equatable, Sendable {
        public var page: Int
        public var total: Int
    }

    /// Set by the app; a no-op otherwise, so a test can run a tool without a window.
    public var host = EditorPDFToolHost()
    /// Asks whether to go ahead despite `warning` — a native alert in the app, a canned answer in a
    /// test. `toolTitle` is the tool's own title, which `detailLines` names.
    var confirm: @MainActor (OutputFidelityWarning, String) -> Bool = { EditorPDFTools.confirmWithAlert($0, toolTitle: $1) }
    /// Asks whether a pending reorder may be dropped — see ``confirmLeaving()``.
    var confirmDiscardingArrangement: @MainActor () -> Bool = { EditorPDFTools.confirmDiscardWithAlert() }

    private var cancelFlag: CancelFlag?
    private var generation = 0
    /// Every progress report that has reached the main actor — the tests' way to see it did.
    private(set) var progressReports = 0

    public init() {}

    // MARK: The file

    func attach(path: String, pageCount: Int, encryption: PDFEncryptionState) {
        if self.path != path || self.pageCount != pageCount {
            // The same file, changed on disk under a pending order: the order named pages that
            // are no longer there, so it goes — and says so rather than vanishing.
            let dropped = self.path == path && arrangement != nil
            selection.clear()
            arrangement = nil
            if dropped {
                banner = EditorPDFToolBanner(message: "The file changed on disk, so the new page order was dropped.",
                                             kind: .note)
            }
        }
        if self.path != path {
            banner = nil
            dragToken = UUID()
        }
        self.path = path
        self.pageCount = pageCount
        self.encryption = encryption
    }

    /// The page count, once a locked file has been unlocked in the reader.
    func update(pageCount: Int) {
        guard pageCount != self.pageCount else { return }
        self.pageCount = pageCount
        selection.clear()
        arrangement = nil
    }

    func detach() {
        generation &+= 1
        cancelFlag?.cancel()
        path = nil
        pageCount = 0
        encryption = nil
        selection.clear()
        arrangement = nil
        running = nil
        sheet = nil
        banner = nil
    }

    // MARK: What can run

    /// **Why nothing but Remove Password is offered**, for a file locked to open. Every toolkit
    /// call opens the file by URL, and a locked one is refused there — unlocking it in the reader
    /// does not unlock the file.
    public static let lockedReason = "Remove the password first. That writes an unlocked copy."
    /// Why Clean Metadata is not offered on any encrypted file — the toolkit refuses
    /// (`metadataEncrypted`), so it is said up front instead.
    public static let metadataEncryptedReason =
        "This PDF is password-protected, so its metadata can’t be cleaned. Remove the password first."

    /// Whether the page tools, Compress and Protect may run. Restricted-only files are let through:
    /// rebuilding tools work on them, and the in-place ones say why not in the toolkit's words.
    public var offersPageTools: Bool { encryption != nil && encryption != .lockedToOpen && pageCount > 0 }
    public var offersMetadata: Bool { encryption == PDFEncryptionState.none && pageCount > 0 }
    public var offersProtect: Bool { encryption == PDFEncryptionState.none && pageCount > 0 }
    public var offersRemovePassword: Bool { encryption == .lockedToOpen || encryption == .restrictedOnly }

    /// Why a tool is greyed out, or `nil` — the first line of the Tools menu.
    public var disabledReason: String? {
        encryption == .lockedToOpen ? Self.lockedReason : nil
    }

    // MARK: Selection and the pending reorder

    /// The pages as the Pages tab shows them.
    public var order: [Int] { arrangement ?? Array(0..<pageCount) }

    /// Names this document in a dragged page — not its path, which a drop into another app's text
    /// field would paste. A new one per file, so a page from another PDF is no reorder of this one.
    public private(set) var dragToken = UUID()

    /// Whether the Pages tab takes a drop: a file the tools can rebuild, and no run in flight — a
    /// drag while the reordered copy is saving would be cleared by that save.
    public var acceptsReorder: Bool { offersPageTools && running == nil }

    public func click(_ page: Int, _ click: EditorPDFPageSelection.Click) {
        selection.click(page, click, order: order)
    }

    public func clearSelection() { selection.clear() }

    /// `pages` dropped onto `target` in the Pages tab — a pending order, written nowhere.
    public func move(_ pages: [Int], onto target: Int) {
        guard acceptsReorder else { return }
        let next = EditorPDFArrangement.moving(pages, onto: target, in: order)
        arrangement = next == Array(0..<pageCount) ? nil : next
    }

    /// Back to the file's own order.
    public func resetArrangement() { arrangement = nil }

    /// **Asks before a pending reorder is dropped** by opening another file or closing this one.
    /// True when there is nothing to lose or the reader said to drop it.
    public func confirmLeaving() -> Bool {
        guard arrangement != nil else { return true }
        guard confirmDiscardingArrangement() else { return false }
        arrangement = nil
        return true
    }

    // MARK: Running

    public func cancelRun() { cancelFlag?.cancel() }

    /// Saves the pending reorder as a copy; the arrangement goes once it has landed.
    @discardableResult
    public func saveArrangement() async -> EditorPDFToolOutcome {
        guard let arrangement else { return .nothingWritten("There is no new order to save.") }
        let outcome = await run(.reorder(arrangement))
        // Only the order that was saved — not one dragged since, or another file's.
        if case .wrote = outcome, self.arrangement == arrangement { self.arrangement = nil }
        return outcome
    }

    /// **Runs `tool` on the open file and writes its copy.** Refusals first (no lane turn), then
    /// the fidelity confirmation when the file has something to lose, then the lane, then the copy.
    /// Every ending is reported on ``banner`` unless `bannerFailures` is false — a sheet shows its
    /// own failure in place, where the field that caused it is.
    @discardableResult
    public func run(_ tool: EditorPDFTool, bannerFailures: Bool = true) async -> EditorPDFToolOutcome {
        guard let path else { return .nothingWritten("No PDF is open.") }
        guard running == nil else {
            banner = EditorPDFToolBanner(message: "Another tool is still running.", kind: .note)
            return .nothingWritten("Another tool is still running.")
        }
        let generation = self.generation
        // **The file itself, through any symlink**: the toolkit reads the source's size with
        // `resourceValues(.fileSizeKey)`, which does not follow one — so Compress on a symlinked
        // PDF measured the LINK and never ran. The copy is still named beside `path`, the folder
        // the reader sees.
        let input = URL(fileURLWithPath: EditorFileStore.resolved(path))
        let name = (path as NSString).lastPathComponent

        func end(_ outcome: EditorPDFToolOutcome) -> EditorPDFToolOutcome {
            // Another file is open now: what this run says is about one that is not on screen.
            guard generation == self.generation else { return outcome }
            running = nil
            cancelFlag = nil
            switch outcome {
            case .wrote(let copy):
                let copyName = (copy as NSString).lastPathComponent
                banner = EditorPDFToolBanner(message: wroteMessage(copyName, tool: tool, source: path, copy: copy),
                                             kind: .wrote(copy))
            case .nothingWritten(let message):
                banner = EditorPDFToolBanner(message: message, kind: .note)
            case .cancelled:
                banner = EditorPDFToolBanner(message: "\(tool.title) cancelled — nothing was written.", kind: .note)
            case .failed(let message):
                if bannerFailures { banner = EditorPDFToolBanner(message: message, kind: .failure) }
            case .declined:
                break
            }
            return outcome
        }

        if let refusal = EditorPDFToolEngine.refusal(tool, pageCount: pageCount) { return end(.failed(refusal)) }
        if case .compress(.target(let bytes)) = tool, let size = EditorFileStore.stamp(ofPath: path)?.size,
           size <= bytes {
            return end(.nothingWritten("“\(name)” is already \(FileSyncManager.formatBytes(size)), under the "
                                       + "\(FileSyncManager.formatBytes(bytes)) target — nothing was written."))
        }

        running = Running(tool: tool.title)
        progress = nil
        let flag = CancelFlag()
        cancelFlag = flag
        if let warning = await EditorPDFToolEngine.fidelityWarning(for: tool, input: input) {
            guard generation == self.generation, !flag.isCancelled else { return end(.cancelled) }
            guard confirm(warning, tool.title) else { return end(.declined) }
        }
        guard generation == self.generation else { return end(.cancelled) }

        let before = EditorFileStore.stamp(ofPath: path)
        let result = await EditorPDFToolEngine.run(
            tool, input: input,
            progress: { [weak self] page, total in
                Task { @MainActor in
                    // Counted and kept even when it lands after the run has ended — the lane
                    // can finish before the main actor reads its first report.
                    guard let self, generation == self.generation else { return }
                    self.progressReports &+= 1
                    self.progress = Progress(page: page, total: total)
                }
            },
            isCancelled: { flag.isCancelled })
        // A close or another file while the lane worked: the bytes are for a file no longer open.
        guard generation == self.generation else { return end(.cancelled) }
        // **Cancel holds for every tool, not only Compress's page loop** — pressed while the run
        // waited for the lane, or after Compress's last page, it still means "write nothing".
        if flag.isCancelled, case .success = result {
            Logger.shared.info("Edit cancelled \(tool.title.lowercased()) of \(name) — nothing written")
            return end(.cancelled)
        }

        switch result {
        case .failure(let error) where error is CancellationError:
            Logger.shared.info("Edit cancelled \(tool.title.lowercased()) of \(name) — nothing written")
            return end(.cancelled)
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Logger.shared.info("Edit could not \(tool.logDetail) of \(name) — \(message)")
            return end(.failed(message))
        case .success(.noGain):
            Logger.shared.info("Edit wrote nothing for \(tool.logDetail) of \(name) — no smaller than the original")
            return end(.nothingWritten(Self.noGainMessage(tool)))
        case .success(.bytes(let data)):
            let suffix = tool.suffix
            let written = await Task.detached(priority: .userInitiated) {
                Result { try EditorPDFCopyWriter.write(data, besides: path, suffix: suffix) }
            }.value
            switch written {
            case .failure(let error):
                let message = "Couldn’t write the copy of “\(name)” — \(error.localizedDescription)"
                Logger.shared.warning("Edit could not write \(tool.logDetail) of \(name): \(error.localizedDescription)")
                return end(.failed(message))
            case .success(let copy):
                let sizes = Self.sizes(before: before?.size, after: data.count)
                Logger.shared.info("Edit wrote \((copy as NSString).lastPathComponent) from \(name) — "
                                   + tool.logDetail + (sizes.map { ", \($0)" } ?? ""))
                host.didWrite(copy)
                return end(.wrote(copy))
            }
        }
    }

    /// The banner's sentence for a copy that landed — sizes for Compress, and for a size target the
    /// reader missed, by how much.
    private func wroteMessage(_ copyName: String, tool: EditorPDFTool, source: String, copy: String) -> String {
        guard case .compress(let compression) = tool else { return "Wrote “\(copyName)”" }
        let before = EditorFileStore.stamp(ofPath: source)?.size
        let after = EditorFileStore.stamp(ofPath: copy)?.size
        let sizes = Self.sizes(before: before, after: after).map { " — \($0)" } ?? ""
        if case .target(let bytes) = compression, let after, after > bytes {
            return "Wrote “\(copyName)”\(sizes). No setting reached \(FileSyncManager.formatBytes(bytes)); "
                + "this is the smallest it got."
        }
        return "Wrote “\(copyName)”\(sizes)"
    }

    static func sizes(before: Int?, after: Int?) -> String? {
        guard let before, let after else { return nil }
        return "\(FileSyncManager.formatBytes(before)) → \(FileSyncManager.formatBytes(after))"
    }

    static func noGainMessage(_ tool: EditorPDFTool) -> String {
        if case .compress(.target) = tool {
            return "Compressing couldn’t make this file any smaller — nothing was written."
        }
        return "Already about as small as this compression gets — nothing was written."
    }

    // MARK: The questions

    static func confirmWithAlert(_ warning: OutputFidelityWarning, toolTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.confirmationTitle
        alert.informativeText = (warning.detailLines(toolTitle: toolTitle) + [warning.keptLine])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        alert.addButton(withTitle: warning.confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmDiscardWithAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard the new page order?"
        alert.informativeText = "The pages were reordered but no copy was saved. The original file is unchanged either way."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Polled from the lane between Compress's pages; set from the main actor by Cancel.
final class CancelFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}
