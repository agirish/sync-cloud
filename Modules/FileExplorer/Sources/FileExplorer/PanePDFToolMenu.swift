import CoreGraphics
import Foundation
import PDFToolkitCore
import Sync
import SwiftUI

/// What a pane row's PDF Tools submenu asks the window to do: Edit's whole-file tools, by its Tools
/// menu's names, plus Combine and Split, which Edit's lacks. No page tools (Extract, Delete,
/// Reorder): a row has no pages to pick, and Open in Edit leads to them. Split asks where its parts
/// start in its own sheet.
public enum PDFToolRequest: Equatable, Sendable {
    case rotateAll(quarterTurns: Int)
    case compress
    case cleanMetadata
    case protect
    case removePassword
    /// Several PDFs into one, in an order the sheet sets.
    case combine
    /// One PDF into several, at the pages the sheet names.
    case split

    /// Whether the request runs over several files. Passwords are one file at a time: each
    /// file's password is its own.
    public var runsOnSeveral: Bool {
        switch self {
        case .rotateAll, .compress, .cleanMetadata, .combine: return true
        case .protect, .removePassword, .split: return false
        }
    }
}

/// What a row's menu offers, or `nil` for no submenu: hidden rather than greyed, so a row that
/// could run nothing shows nothing. Hidden when any item is a folder, not a PDF
/// (`EditableText.isPDF`, the reader's gate), or cloud-only (the row offers Download, and a tool
/// would have no bytes to read).
///
/// File ▸ PDF Tools asks the same question through ``forSelection(_:)`` outside a PDF open in
/// Edit, and greys where the row hides.
public enum PanePDFToolOffer: Equatable, Sendable {
    /// One PDF, with its protection as the menu reads it (see ``PDFMenuEncryption``).
    case single(path: String, encryption: PDFEncryptionState)
    case several(paths: [String])

    /// The submenu's name, on the row and in File ▸, counting the files a batch runs over.
    public var title: String {
        switch self {
        case .single: return "PDF Tools"
        case .several(let paths): return "PDF Tools · \(paths.count) files"
        }
    }

    /// The answer for a selection, for both the row menu and File ▸ PDF Tools, so they can't
    /// disagree. One file is probed for its protection; several share one cloud answer per
    /// selection (``PanePDFSelectionCloud``).
    ///
    /// What the memos can't answer (an `lstat`, a link to resolve, the protection probe) is read off
    /// the main thread through `reads` (`BoundedCloudRead`), and the tools are withheld if it doesn't
    /// answer in time: both callers ask on the main thread (a right-click, every window render), and
    /// a wedged File Provider holds those reads for seconds.
    @MainActor
    public static func forSelection(_ nodes: [FileNode]) -> PanePDFToolOffer? {
        forSelection(nodes, reads: .shared)
    }

    /// The same, through a reader of the caller's: the row menu's `cloudReads`.
    @MainActor
    static func forSelection(_ nodes: [FileNode], reads: BoundedCloudRead) -> PanePDFToolOffer? {
        offer(for: nodes,
              anyCloudOnly: { PanePDFSelectionCloud.anyCloudOnly(nodes, reads: reads) },
              encryption: { PDFMenuEncryption.state(for: $0, reads: reads) })
    }

    /// The cheap rules first (path math, a flag on the node), so a folder or JPEG never pays a cloud
    /// lookup and a cloud-only file never pays a probe. Nil, too, when either read gave no answer.
    ///
    /// A link is asked about as the file it points to, so a link to a cloud-only PDF is hidden and
    /// never reaches the probe, which reads the file and would download it on selection.
    static func offer(for nodes: [FileNode], anyCloudOnly: () -> Bool?,
                      encryption: (FileNode) -> PDFEncryptionState?) -> PanePDFToolOffer? {
        guard !nodes.isEmpty,
              nodes.allSatisfy({ !$0.isDirectory && EditableText.isPDF(path: $0.id) }),
              anyCloudOnly() == false
        else { return nil }
        if nodes.count == 1, let node = nodes.first {
            return encryption(node).map { .single(path: node.id, encryption: $0) }
        }
        return .several(paths: nodes.map(\.id))
    }
}

extension FileNode {
    /// The path a door asks the cloud question of: the file a link points to, else the node's own
    /// (``MaterializationStatus/linkTarget(of:)``). The walk records which nodes are links, so an
    /// ordinary row pays no `lstat`; a node built without saying is asked.
    var linkTarget: String {
        isSymbolicLink == false ? id : MaterializationStatus.linkTarget(of: id)
    }
}

/// Whether any of a selection is cloud-only, as PDF Tools and Save as PDF ask it: each link as the
/// file it points to (``FileNode/linkTarget``), each file by the badge's memo, else an `lstat`.
///
/// The memo is read here, the filesystem off the main thread. A selected row has usually had its
/// badge answered, so most selections never touch the disk. The rest is one read through `reads`
/// (`BoundedCloudRead`), nil if it doesn't answer in time. A link's target is `lstat`ed even when
/// the memo knows it, to save a second trip back to this actor; the memo's answer still wins.
///
/// Several files' answer is held for a second, since the menu bar asks on every window render. A
/// file evicted inside that second is caught again when the run starts. One file is asked afresh
/// each time, as the row's own Download is.
@MainActor
enum PanePDFSelectionCloud {
    private static var last: (ids: [String], at: Date, answer: Bool)?
    static let lifetime: TimeInterval = 1

    static func anyCloudOnly(_ nodes: [FileNode], reads: BoundedCloudRead, now: Date = Date()) -> Bool? {
        anyCloudOnly(nodes, now: now) { walk($0, reads: reads) }
    }

    /// The hold around `walk`. Nil — no answer — is never held.
    static func anyCloudOnly(_ nodes: [FileNode], now: Date = Date(),
                             walk: ([FileNode]) -> Bool?) -> Bool? {
        let ids = nodes.map(\.id)
        if nodes.count > 1, let last, last.ids == ids, now.timeIntervalSince(last.at) < lifetime { return last.answer }
        guard let answer = walk(nodes) else { return nil }
        if nodes.count > 1 { last = (ids, now, answer) }
        return answer
    }

    /// One file the memo could not answer, as the read found it.
    private struct Read: Sendable {
        let target: String
        let isCloudOnly: Bool
    }

    private static func walk(_ nodes: [FileNode], reads: BoundedCloudRead) -> Bool? {
        var unanswered: [FileNode] = []
        for node in nodes {
            if node.isSymbolicLink == false, let known = CloudOnlyBadgeCache.cached(node.id) {
                if known { return true }
            } else {
                unanswered.append(node)
            }
        }
        if unanswered.isEmpty { return false }
        guard let found = reads.run({ [unanswered] in
            unanswered.map { node in
                let target = node.linkTarget
                return Read(target: target, isCloudOnly: MaterializationStatus.isCloudOnly(atPath: target))
            }
        }) else { return nil }
        return found.contains { CloudOnlyBadgeCache.cached($0.target) ?? $0.isCloudOnly }
    }
}

/// How a PDF is protected, as a row's menu reads it: from CoreGraphics, waited for briefly.
///
/// The menu is built on the main thread, so it can't wait on the PDFKit lane. `CGPDFDocument` is
/// outside the lane's scope (see `PDFKitSerialAccess`) and reads only the trailer and encryption
/// dictionary: a few milliseconds even on a large PDF, then a memo lookup.
///
/// The probe runs off the main thread (`BoundedCloudRead`), because opening a File Provider file
/// goes through the provider, which a wedged one holds. A probe that doesn't answer in time answers
/// nil, which withholds the tools, and isn't remembered.
///
/// Maps as `PDFToolkit.encryptionState` maps PDFKit's: not encrypted is `.none`, encrypted and
/// unlocked `.restrictedOnly`, encrypted and locked `.lockedToOpen`. A file CoreGraphics can't open
/// answers `.none`, as the toolkit's does. The lane reads the state again before anything runs, so
/// a file changed in between is caught.
@MainActor
enum PDFMenuEncryption {
    struct Key: Hashable {
        var path: String
        var modified: Date?
        var size: Int?
    }

    /// Keyed by the row's own date and size, so a rewritten file is read again and no `stat` is paid
    /// to find out.
    private static var memo: [Key: PDFEncryptionState] = [:]
    static let capacity = 4096
    /// Every probe that reached CoreGraphics, so tests can see the memo held.
    private(set) static var probes = 0

    static func state(for node: FileNode, reads: BoundedCloudRead = .shared) -> PDFEncryptionState? {
        let key = Key(path: node.id, modified: node.modificationDate, size: node.fileSize)
        if let known = memo[key] { return known }
        let path = node.id
        guard let state = reads.run({ probe(path) }) else { return nil }
        probes &+= 1
        if memo.count >= capacity { memo.removeAll(keepingCapacity: true) }
        memo[key] = state
        return state
    }

    nonisolated static func probe(_ path: String) -> PDFEncryptionState {
        guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL),
              document.isEncrypted else { return .none }
        return document.isUnlocked ? .restrictedOnly : .lockedToOpen
    }
}

/// The submenu itself, one section of the row menu below Open in Edit. Each item hands its request
/// to the delegate; the window re-reads the file in the lane and presents Edit's own sheet.
struct PanePDFToolsSubmenu: View {
    let offer: PanePDFToolOffer
    let delegate: FileActionDelegate

    var body: some View {
        Menu {
            PanePDFToolsMenuItems(offer: offer) { delegate.handlePDFTool($0, paths: $1) }
        } label: {
            Label(offer.title, systemImage: "wrench.and.screwdriver")
        }
    }

    /// Edit's Tools menu without its page tools, in its order, with Split under Rotate and with
    /// what Edit would grey out left out: a file locked to open holds only Remove Password under
    /// Edit's reason, and a restricted one says why Clean Metadata is missing, in its place.
    @ViewBuilder
    static func singleItems(encryption: PDFEncryptionState, run: @escaping (PDFToolRequest) -> Void) -> some View {
        if encryption == .lockedToOpen {
            Text(EditorPDFTools.lockedReason)
            Divider()
            Button("Remove Password…") { run(.removePassword) }
        } else {
            rotateItems(run: run)
            Button("Split…") { run(.split) }
            Divider()
            Button("Compress…") { run(.compress) }
            // Where Edit's menu puts its reason, in the item's own place.
            if encryption == .restrictedOnly {
                Text(EditorPDFTools.metadataEncryptedReason)
            } else {
                Button("Clean Metadata…") { run(.cleanMetadata) }
            }
            Divider()
            if encryption == .restrictedOnly {
                Button("Remove Password…") { run(.removePassword) }
            } else {
                Button("Protect with Password…") { run(.protect) }
            }
        }
    }

    @ViewBuilder
    static func severalItems(count: Int, run: @escaping (PDFToolRequest) -> Void) -> some View {
        rotateItems(run: run)
        Divider()
        Button("Compress \(count) Files…") { run(.compress) }
        Button("Clean Metadata of \(count) Files…") { run(.cleanMetadata) }
        Divider()
        Button("Combine \(count) Files…") { run(.combine) }
    }

    /// Edit's three turns, under Edit's name for them.
    static func rotateItems(run: @escaping (PDFToolRequest) -> Void) -> some View {
        Menu("Rotate All Pages") {
            Button("Rotate Left") { run(.rotateAll(quarterTurns: -1)) }
            Button("Rotate Right") { run(.rotateAll(quarterTurns: 1)) }
            Button("Rotate 180°") { run(.rotateAll(quarterTurns: 2)) }
        }
    }
}

/// The submenu's lines for an offer, the same view on a row and in File ▸ PDF Tools outside a PDF
/// open in Edit. `run` is handed each request with the paths it runs over.
public struct PanePDFToolsMenuItems: View {
    let offer: PanePDFToolOffer
    let run: (PDFToolRequest, [String]) -> Void

    public init(offer: PanePDFToolOffer, run: @escaping (PDFToolRequest, [String]) -> Void) {
        self.offer = offer
        self.run = run
    }

    public var body: some View {
        switch offer {
        case .single(let path, let encryption):
            PanePDFToolsSubmenu.singleItems(encryption: encryption) { run($0, [path]) }
        case .several(let paths):
            PanePDFToolsSubmenu.severalItems(count: paths.count) { run($0, paths) }
        }
    }
}
