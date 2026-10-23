import CoreGraphics
import Foundation
import PDFToolkitCore
import Sync
import SwiftUI

/// **What a pane row's PDF Tools submenu asks the window to do** — Edit's whole-file tools, by the
/// names its Tools menu gives them. The page tools (Extract, Delete, Reorder) are not here: a row
/// has no pages to pick, and Open in Edit, a few items up, leads to them.
public enum PDFToolRequest: Equatable, Sendable {
    case rotateAll(quarterTurns: Int)
    case compress
    case cleanMetadata
    case protect
    case removePassword

    /// Whether the request runs over several files. Passwords are one file at a time: each
    /// file's password is its own.
    public var runsOnSeveral: Bool {
        switch self {
        case .rotateAll, .compress, .cleanMetadata: return true
        case .protect, .removePassword: return false
        }
    }
}

/// **What a row's menu offers, or `nil` for no submenu at all** — hidden rather than greyed, so a
/// row that could run nothing shows nothing.
///
/// Hidden when any item is a folder, is not a PDF (`EditableText.isPDF`, the gate every door into
/// the reader asks), or is cloud-only — a cloud-only row already offers Download, and a tool would
/// have no bytes to read.
///
/// **File ▸ PDF Tools asks the same question**, through ``forSelection(_:)``, outside a PDF open in
/// Edit — and greys where the row hides.
public enum PanePDFToolOffer: Equatable, Sendable {
    /// One PDF, with its protection as the menu reads it — see ``PDFMenuEncryption``.
    case single(path: String, encryption: PDFEncryptionState)
    case several(paths: [String])

    /// The submenu's name — on the row and in File ▸ — which counts the files a batch runs over.
    public var title: String {
        switch self {
        case .single: return "PDF Tools"
        case .several(let paths): return "PDF Tools · \(paths.count) files"
        }
    }

    /// **The row menu's answer for a selection, and File ▸ PDF Tools' too** — so the two cannot
    /// disagree about whether a selection takes the tools, or which. One file is probed for its
    /// protection; several share one cloud answer per selection (``PanePDFSelectionCloud``).
    ///
    /// The cloud lookup is the row's own: the badge's memo, else an `lstat`. The menu bar asks on
    /// every window render, and a selected row has been drawn, so its badge has answered — and a
    /// batch's answer is held for the second either caller asks in.
    @MainActor
    public static func forSelection(_ nodes: [FileNode]) -> PanePDFToolOffer? {
        if nodes.count > 1 {
            let paths = nodes.map(\.linkTarget)
            return offer(for: nodes,
                         isCloudOnly: { _ in PanePDFSelectionCloud.anyCloudOnly(paths, isCloudOnly: FileContextMenu.isCloudOnly) },
                         encryption: { _ in .none })
        }
        return offer(for: nodes, isCloudOnly: FileContextMenu.isCloudOnly, encryption: PDFMenuEncryption.state(for:))
    }

    /// The cheap rules first — path math and a flag the node holds — so a selection with a folder
    /// or a JPEG in it never pays a cloud lookup, and a cloud-only file never pays a probe.
    ///
    /// **A link is asked about as the file it points to** (TE206), so a link to a cloud-only PDF
    /// is hidden as that PDF is — and never reaches the probe, which reads the file and so
    /// downloaded it, on the main thread, the moment the row was selected.
    static func offer(for nodes: [FileNode], isCloudOnly: (String) -> Bool,
                      encryption: (FileNode) -> PDFEncryptionState) -> PanePDFToolOffer? {
        guard !nodes.isEmpty,
              nodes.allSatisfy({ !$0.isDirectory && EditableText.isPDF(path: $0.id) }),
              !nodes.contains(where: { isCloudOnly($0.linkTarget) })
        else { return nil }
        if nodes.count == 1, let node = nodes.first {
            return .single(path: node.id, encryption: encryption(node))
        }
        return .several(paths: nodes.map(\.id))
    }
}

extension FileNode {
    /// The path a door asks the cloud question of: the file a link points to, else the node's own
    /// (``MaterializationStatus/linkTarget(of:)``). The walk says whether each node is a link, so
    /// an ordinary row pays no `lstat` here; a node built without saying is asked.
    var linkTarget: String {
        isSymbolicLink == false ? id : MaterializationStatus.linkTarget(of: id)
    }
}

/// **A selection's cloud answer, held for the render pass that asks it once per row.**
///
/// The row menu is built with every visible row, and a selected row's menu acts on the whole
/// selection — so N selected rows on screen each asked about all N files, an `lstat` apiece for any
/// the badge cache has not seen. One answer per selection, kept for a second, makes that one walk
/// per render. A file evicted inside that second is caught again when the run starts.
@MainActor
enum PanePDFSelectionCloud {
    private static var last: (paths: [String], at: Date, answer: Bool)?
    static let lifetime: TimeInterval = 1

    static func anyCloudOnly(_ paths: [String], now: Date = Date(),
                             isCloudOnly: (String) -> Bool) -> Bool {
        if let last, last.paths == paths, now.timeIntervalSince(last.at) < lifetime { return last.answer }
        let answer = paths.contains(where: isCloudOnly)
        last = (paths, now, answer)
        return answer
    }
}

/// **How a PDF is protected, as a row's menu reads it — synchronously, from CoreGraphics.**
///
/// The menu is built with its row, so it cannot wait on the PDFKit lane. `CGPDFDocument` is not
/// PDFKit, and so outside the lane's scope (see `PDFKitSerialAccess`): it reads the trailer and the
/// encryption dictionary and nothing else. Measured 2026-10-17 on this Mac with CoreGraphics
/// already loaded, as it always is in the app: 0.7 ms on a 697 MB PDF, 0.15–2.7 ms on 29 untouched
/// local PDFs of 20–125 MB (one 7 ms outlier, a 23 MB slide deck), ~2 ms on a locked and on a
/// restricted 54 MB file. Then it is a dictionary lookup.
///
/// The answer maps exactly as `PDFToolkit.encryptionState` maps PDFKit's: not encrypted is
/// `.none`, encrypted and unlocked is `.restrictedOnly`, encrypted and locked is `.lockedToOpen` —
/// PDFKit's `isLocked` and `isEncrypted` are CoreGraphics's `isUnlocked` and `isEncrypted`. A file
/// CoreGraphics cannot open answers `.none`, as the toolkit's does. The lane reads the state again
/// before anything runs, so a file that changed between the two is told, not trusted.
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
    /// Every probe that reached CoreGraphics — the tests' way to see the memo held.
    private(set) static var probes = 0

    static func state(for node: FileNode) -> PDFEncryptionState {
        let key = Key(path: node.id, modified: node.modificationDate, size: node.fileSize)
        if let known = memo[key] { return known }
        let state = probe(node.id)
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

/// **The submenu itself** — one section of the row menu, below Open in Edit and its neighbours.
/// Each item hands its request to the delegate; the window reads the file again in the lane and
/// presents the same sheet Edit's Tools menu does.
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

    /// Edit's Tools menu without its page tools (Extract and Delete), in its order, with what Edit
    /// would grey out left out — so a file locked to open holds only Remove Password, under Edit's
    /// own reason, and a restricted one says why Clean Metadata is not there, where it would be.
    @ViewBuilder
    static func singleItems(encryption: PDFEncryptionState, run: @escaping (PDFToolRequest) -> Void) -> some View {
        if encryption == .lockedToOpen {
            Text(EditorPDFTools.lockedReason)
            Divider()
            Button("Remove Password…") { run(.removePassword) }
        } else {
            rotateItems(run: run)
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

/// **The submenu's lines for an offer** — on a row, and in File ▸ PDF Tools outside a PDF open in
/// Edit, the same view in both. `run` is handed each request with the paths it runs over.
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
