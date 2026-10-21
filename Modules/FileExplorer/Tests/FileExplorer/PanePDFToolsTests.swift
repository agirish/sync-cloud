import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Sync
import EventsTestSupport
import FileExplorerTestSupport
@testable import FileExplorer

/// A row-menu delegate with a window behind it — `canRunPDFTools` — recording what it was asked.
@MainActor
private final class ToolBox {
    var asked: [(PDFToolRequest, [String])] = []
}

private struct PDFToolDelegate: FileActionDelegate {
    let box: ToolBox
    /// False for the same menu with no window behind it — the baseline a hidden submenu matches.
    var offersTools = true
    var canRunPDFTools: Bool { offersTools }
    func handlePDFTool(_ request: PDFToolRequest, paths: [String]) {
        MainActor.assumeIsolated { box.asked.append((request, paths)) }
    }
    func handleRefresh() {}
    func handleOpenInEditor(_ path: String) {}
    func handleFocus(_ node: FileNode) {}
    func handleCopy(_ nodes: [FileNode]) {}
    func handleMove(_ nodes: [FileNode]) {}
    func handleDelete(_ nodes: [FileNode]) {}
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
    func handlePaste(_ targetDir: FileNode) {}
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
    func handlePasteToPath(_ path: String) {}
    func handleRename(_ node: FileNode) {}
    func handleCreateFolder(at path: String) {}
    func handleGetInfo(for path: String) {}
    func handleSort(_ option: SortOption) {}
    func handleIgnore(_ nodes: [FileNode]) {}
    func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
}

/// **The PDF Tools submenu in a pane's row menu, and the runs it starts** — Phase 4.
///
/// Serialized, because every run takes `PDFKitSerialAccess`'s one lane. No test here holds the
/// lane: each awaits its own run, so a crowded lane makes them slow, never wrong.
@MainActor
@Suite(.serialized) final class PanePDFToolsTests {

    let folder = NSTemporaryDirectory() + "pane-pdf-tools-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    private func node(_ path: String, isDirectory: Bool = false) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory)
    }

    private struct Original {
        let bytes: Data
        let modified: Date
    }

    /// The original's bytes and date — set into the past first, so a write this second could not
    /// hide behind it.
    private func pin(_ file: String) throws -> Original {
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file)
        return Original(bytes: try Data(contentsOf: URL(fileURLWithPath: file)), modified: past)
    }

    private func expectUntouched(_ file: String, _ original: Original, _ label: String) throws {
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == original.bytes, "\(label): the original's bytes changed")
        let modified = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
        #expect(modified == original.modified, "\(label): the original's date moved")
    }

    // MARK: Where the submenu is drawn

    /// Every item of the row menu over `nodes` (the first is the row clicked), in drawn order, as
    /// widths — `OpenInEditorVerbTests`' drawn-row approach.
    private static func drawnRowWidths(_ nodes: [FileNode], delegate: FileActionDelegate) -> [CGFloat] {
        let row = nodes[0]
        let menu = FileContextMenu(row: PaneRow(side: .left, version: 1, node: row, children: nil),
                                   selection: nodes.count > 1 ? Set(nodes.map(\.id)) : [],
                                   tree: PaneTree(side: .left, version: 1, nodes: nodes),
                                   otherTree: PaneTree(side: .right, version: 1, nodes: []),
                                   otherSelection: [], isLeft: true, currentPath: "/",
                                   delegate: delegate, otherPaneName: "Right", isSingleSource: false,
                                   onQuickLook: { _ in }, selectionResolver: PaneSelectionResolver())
        return rings(AnyView(VStack(alignment: .leading, spacing: 0) { menu }.frame(width: 260)), height: 900)
            .map(\.width)
    }

    /// A pop-up `Menu` measures a point wider inside the stack than alone (measured: 129 against
    /// 128), so the submenu is matched within a point and a half — still clear of every neighbour.
    private static func same(_ drawn: CGFloat, _ solo: CGFloat) -> Bool { abs(drawn - solo) <= 1.5 }

    private static func soloWidth<V: View>(_ item: V) -> CGFloat {
        rings(AnyView(VStack(alignment: .leading) { item }.frame(width: 260)), height: 80).first?.width ?? 0
    }

    private static func rings(_ view: AnyView, height: CGFloat) -> [CGRect] {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        host.layoutSubtreeIfNeeded()
        return FocusRings.frames(in: host).sorted { $0.minY < $1.minY }
    }

    private var submenuWidth: CGFloat {
        Self.soloWidth(PanePDFToolsSubmenu(offer: .single(path: "/x.pdf", encryption: .none),
                                           delegate: PDFToolDelegate(box: ToolBox())))
    }

    /// **A single PDF row draws the submenu in its own section: after the open-and-inspect items,
    /// before Rename** — and Open in Edit still leads the branch, first after Refresh.
    @Test func aSinglePDFRowDrawsTheSubmenuBetweenQuickLookAndRename() throws {
        let file = path("Statement.pdf")
        PDFFixtures.write(file, pages: 2)
        let delegate = PDFToolDelegate(box: ToolBox())
        let tools = submenuWidth
        let quickLook = Self.soloWidth(Button(action: {}) { Label("Quick Look", systemImage: "doc.viewfinder") })
        let rename = Self.soloWidth(Button(action: {}) { Label("Rename", systemImage: "pencil") })
        let editor = Self.soloWidth(SharedFileMenuItems.openInEditor(file, delegate: delegate))
        #expect(Set([tools, quickLook, rename, editor]).count == 4,
                "two labels measure the same, so a row cannot be told from its neighbour")

        let drawn = Self.drawnRowWidths([node(file)], delegate: delegate)
        #expect(drawn.filter { Self.same($0, tools) }.count == 1, "PDF Tools is drawn \(drawn.filter { Self.same($0, tools) }.count) times")
        let at = try #require(drawn.firstIndex { Self.same($0, tools) }, "PDF Tools is not drawn at all: \(drawn)")
        let quickLookAt = try #require(drawn.firstIndex(of: quickLook))
        let renameAt = try #require(drawn.firstIndex(of: rename))
        #expect(quickLookAt < at && at < renameAt, "PDF Tools is at \(at), Quick Look \(quickLookAt), Rename \(renameAt)")
        #expect(drawn.firstIndex(of: editor) == 1, "Open in Edit no longer leads the single-file branch")
    }

    /// **Hidden, not greyed** — a folder, a `.docx`, a cloud-only PDF and a selection holding
    /// anything but PDFs draw no submenu at all, single or batch.
    @Test func whatNoToolCouldReadDrawsNoSubmenu() throws {
        let pdf = path("A.pdf"), other = path("B.pdf"), docx = path("Letter.docx"), cloud = path("Cloud.pdf")
        PDFFixtures.write(pdf, pages: 1)
        PDFFixtures.write(other, pages: 1)
        PDFFixtures.write(cloud, pages: 1)
        try Data("x".utf8).write(to: URL(fileURLWithPath: docx))
        let sub = path("Sub")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        CloudOnlyBadgeCache.record(cloud, isCloudOnly: true)
        defer { CloudOnlyBadgeCache.forget(cloud) }
        let delegate = PDFToolDelegate(box: ToolBox())
        let several = Self.soloWidth(PanePDFToolsSubmenu(offer: .several(paths: [pdf, other]), delegate: delegate))

        let cases: [(String, [FileNode])] = [
            ("a folder", [node(sub, isDirectory: true)]),
            ("a .docx", [node(docx)]),
            ("a cloud-only PDF", [node(cloud)]),
            ("a PDF with a .docx", [node(pdf), node(docx)]),
            ("a PDF with a folder", [node(pdf), node(sub, isDirectory: true)]),
            ("a PDF with a cloud-only PDF", [node(pdf), node(cloud)]),
        ]
        let baseline = PDFToolDelegate(box: ToolBox(), offersTools: false)
        for (label, nodes) in cases {
            // The whole menu, item for item, is the menu with no tools at all.
            let drawn = Self.drawnRowWidths(nodes, delegate: delegate)
            #expect(drawn == Self.drawnRowWidths(nodes, delegate: baseline), "\(label) draws a PDF Tools submenu: \(drawn)")
            #expect(PanePDFToolOffer.offer(for: nodes, isCloudOnly: FileContextMenu.isCloudOnly,
                                           encryption: { _ in .none }) == nil, "\(label) is offered tools")
        }
        // …and two plain PDFs DO draw it, so the absences above are the rule and not a blind test.
        let two = Self.drawnRowWidths([node(pdf), node(other)], delegate: delegate)
        #expect(two.count == Self.drawnRowWidths([node(pdf), node(other)], delegate: baseline).count + 1
                && two.contains { Self.same($0, several) }, "two PDFs draw no batch submenu: \(two)")
        let one = Self.drawnRowWidths([node(pdf)], delegate: delegate)
        #expect(one.count == Self.drawnRowWidths([node(pdf)], delegate: baseline).count + 1,
                "one PDF draws no submenu: \(one)")
    }

    /// **Three PDFs draw the batch submenu, first after Refresh, holding three items**: Rotate All
    /// Pages, Compress 3 Files…, Clean Metadata of 3 Files… — and no password item.
    @Test func threePDFsDrawTheBatchSubmenuWithThreeItems() throws {
        let paths = ["One.pdf", "Two.pdf", "Three.pdf"].map(path)
        for file in paths { PDFFixtures.write(file, pages: 1) }
        let box = ToolBox()
        let delegate = PDFToolDelegate(box: box)
        let several = Self.soloWidth(PanePDFToolsSubmenu(offer: .several(paths: paths), delegate: delegate))
        let drawn = Self.drawnRowWidths(paths.map { node($0) }, delegate: delegate)
        #expect(drawn.firstIndex { Self.same($0, several) } == 1, "the batch submenu is not first after Refresh: \(drawn)")

        let items = Self.rings(AnyView(VStack(alignment: .leading) {
            PanePDFToolsSubmenu.severalItems(count: 3) { box.asked.append(($0, paths)) }
        }.frame(width: 260)), height: 200)
        #expect(items.count == 3, "the batch submenu holds \(items.count) items")
    }

    /// Edit's items for each protection, Extract left out and what Edit would grey out left out —
    /// a locked file holds Remove Password alone.
    @Test func theSingleSubmenuHoldsEditsItemsForEachProtection() {
        func count(_ encryption: PDFEncryptionState) -> Int {
            Self.rings(AnyView(VStack(alignment: .leading) {
                PanePDFToolsSubmenu.singleItems(encryption: encryption) { _ in }
            }.frame(width: 260)), height: 300).count
        }
        // Rotate All Pages ▸, Compress…, Clean Metadata…, Protect with Password…
        #expect(count(.none) == 4)
        // Rotate All Pages ▸, Compress…, Remove Password…
        #expect(count(.restrictedOnly) == 3)
        // Remove Password…
        #expect(count(.lockedToOpen) == 1)
    }

    // MARK: The menu bar's half — File ▸ PDF Tools outside a PDF open in Edit

    /// **File ▸ PDF Tools asks the row's own question** — `forSelection` is what both the row menu
    /// and the menu bar's resolver call, so the cases the row hides are the cases the menu bar
    /// greys, and one file's protection is probed for both.
    @Test func theMenuBarAsksTheRowsQuestion() throws {
        let pdf = path("A.pdf"), other = path("B.pdf"), docx = path("Letter.docx"), cloud = path("Cloud.pdf")
        let locked = path("Locked.pdf"), restricted = path("Restricted.pdf")
        PDFFixtures.write(pdf, pages: 1)
        PDFFixtures.write(other, pages: 1)
        PDFFixtures.write(cloud, pages: 1)
        PDFFixtures.writeLocked(locked, password: "pw")
        PDFFixtures.writeRestricted(restricted)
        try Data("x".utf8).write(to: URL(fileURLWithPath: docx))
        let sub = path("Sub")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        CloudOnlyBadgeCache.record(cloud, isCloudOnly: true)
        defer { CloudOnlyBadgeCache.forget(cloud) }

        let hidden: [(String, [FileNode])] = [
            ("nothing", []),
            ("a folder", [node(sub, isDirectory: true)]),
            ("a .docx", [node(docx)]),
            ("a cloud-only PDF", [node(cloud)]),
            ("a PDF with a .docx", [node(pdf), node(docx)]),
            ("a PDF with a folder", [node(pdf), node(sub, isDirectory: true)]),
            ("a PDF with a cloud-only PDF", [node(pdf), node(cloud)]),
        ]
        for (label, nodes) in hidden {
            #expect(PanePDFToolOffer.forSelection(nodes) == nil, "\(label) is offered tools")
        }
        #expect(PanePDFToolOffer.forSelection([node(pdf)]) == .single(path: pdf, encryption: .none))
        #expect(PanePDFToolOffer.forSelection([node(restricted)]) == .single(path: restricted, encryption: .restrictedOnly),
                "one file's protection is not the probe's")
        #expect(PanePDFToolOffer.forSelection([node(locked)]) == .single(path: locked, encryption: .lockedToOpen))
        #expect(PanePDFToolOffer.forSelection([node(pdf), node(other)]) == .several(paths: [pdf, other]))
    }

    /// The submenu's name, on the row and in File ▸ — a batch counts its files.
    @Test func theSubmenuIsNamedForWhatItRunsOver() {
        #expect(PanePDFToolOffer.single(path: "/a.pdf", encryption: .lockedToOpen).title == "PDF Tools")
        #expect(PanePDFToolOffer.several(paths: ["/a.pdf", "/b.pdf", "/c.pdf"]).title == "PDF Tools · 3 files")
    }

    /// One line of a menu AppKit built: its title (a submenu with its own lines after `▸`), and
    /// whether it can be chosen.
    private static func lines(_ menu: NSMenu) -> [String] {
        menu.update()
        return menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if let submenu = item.submenu { return "\(item.title) ▸ \(lines(submenu).joined(separator: ", "))" }
            return item.isEnabled ? item.title : "(\(item.title))"
        }
    }

    /// **The lines File ▸ PDF Tools draws for a selection, as AppKit builds them** — the row's own
    /// `PanePDFToolsMenuItems`, through `NSHostingMenu`, which is how a SwiftUI menu becomes an
    /// `NSMenu`. Each protection's lines, the reasons as lines nothing can choose, and a batch's
    /// three tools with no password item.
    @Test func theMenuBarDrawsTheRowsLines() {
        func drawn(_ offer: PanePDFToolOffer) -> [String] {
            Self.lines(NSHostingMenu(rootView: PanePDFToolsMenuItems(offer: offer) { _, _ in }))
        }
        let rotate = "Rotate All Pages ▸ Rotate Left, Rotate Right, Rotate 180°"
        #expect(drawn(.single(path: "/a.pdf", encryption: .none))
                == [rotate, "—", "Compress…", "Clean Metadata…", "—", "Protect with Password…"])
        #expect(drawn(.single(path: "/a.pdf", encryption: .restrictedOnly))
                == [rotate, "—", "Compress…", "(\(EditorPDFTools.metadataEncryptedReason))", "—", "Remove Password…"])
        #expect(drawn(.single(path: "/a.pdf", encryption: .lockedToOpen))
                == ["(\(EditorPDFTools.lockedReason))", "—", "Remove Password…"])
        #expect(drawn(.several(paths: ["/a.pdf", "/b.pdf", "/c.pdf"]))
                == [rotate, "—", "Compress 3 Files…", "Clean Metadata of 3 Files…"])
    }

    // MARK: The menu's protection probe

    /// **CoreGraphics answers what the toolkit answers**, for each of the three states — the menu's
    /// items are only as right as this mapping.
    @Test func theMenuProbeAgreesWithTheToolkit() {
        let plain = path("Plain.pdf"), locked = path("Locked.pdf"), restricted = path("Restricted.pdf")
        PDFFixtures.write(plain, pages: 1)
        PDFFixtures.writeLocked(locked, password: "pw")
        PDFFixtures.writeRestricted(restricted)
        for (file, expected) in [(plain, PDFEncryptionState.none), (locked, .lockedToOpen), (restricted, .restrictedOnly)] {
            let toolkit = PDFToolkit.encryptionState(of: URL(fileURLWithPath: file))
            #expect(toolkit == expected, "the fixture is not what it says: \(toolkit)")
            #expect(PDFMenuEncryption.probe(file) == toolkit, "\((file as NSString).lastPathComponent)")
        }
    }

    /// **Read once per file version** — a second ask is the memo's, and a new modification date
    /// (the file rewritten) is read again.
    @Test func theMenuProbeIsReadOncePerVersion() {
        let file = path("Memo.pdf")
        PDFFixtures.write(file, pages: 1)
        var row = FileNode(id: file, name: "Memo.pdf", isDirectory: false,
                           modificationDate: Date(timeIntervalSince1970: 1_000), fileSize: 10)
        let before = PDFMenuEncryption.probes
        _ = PDFMenuEncryption.state(for: row)
        _ = PDFMenuEncryption.state(for: row)
        #expect(PDFMenuEncryption.probes == before + 1, "the same version was probed twice")
        row.modificationDate = Date(timeIntervalSince1970: 2_000)
        _ = PDFMenuEncryption.state(for: row)
        #expect(PDFMenuEncryption.probes == before + 2, "a rewritten file was answered from the memo")
    }

    // MARK: One file, from a pane

    enum Single: String, CaseIterable, Sendable {
        case rotate, compress, metadata, protect, removePassword

        var request: PDFToolRequest {
            switch self {
            case .rotate: return .rotateAll(quarterTurns: 1)
            case .compress: return .compress
            case .metadata: return .cleanMetadata
            case .protect: return .protect
            case .removePassword: return .removePassword
            }
        }

        /// What the sheet's button would run.
        var tool: EditorPDFTool {
            switch self {
            case .rotate: return .rotate(pages: [0, 1, 2], quarterTurns: 1)
            case .compress: return .compress(.quality(0.35))
            case .metadata: return .cleanMetadata(.cleared)
            case .protect: return .protect(restrictEditing: false, password: EditorPDFSecret("pw"))
            case .removePassword: return .removePassword(EditorPDFSecret("pw"))
            }
        }

        var sheet: EditorPDFToolSheet? {
            switch self {
            case .rotate: return nil
            case .compress: return .compress
            case .metadata: return .metadata
            case .protect: return .protect
            case .removePassword: return .removePassword
            }
        }
    }

    /// **Each tool, from a pane, writes the name it writes in Edit** — Edit's own suffix table,
    /// beside the original, which keeps its bytes and its date. Through the window's model: the
    /// lane read, the sheet the request names, then the sheet's own run.
    @Test(arguments: Single.allCases)
    func aPaneRunWritesEditsCopyAndLeavesTheOriginal(_ item: Single) async throws {
        let file = path("Invoice-\(item.rawValue).pdf")
        switch item {
        case .compress: PDFFixtures.writeScan(file, pages: 3)
        case .removePassword: PDFFixtures.writeLocked(file, password: "pw", pages: 3)
        default: PDFFixtures.write(file, pages: 3)
        }
        let original = try pin(file)
        var wrote: [String] = []
        let model = PanePDFTools()
        model.host = PanePDFToolHost(didWrite: { wrote.append($0) })
        let log = LogCapture()
        model.start(item.request, paths: [file], writer: "PDF Tools in Browse")
        await model.work?.value
        guard case .single(let tools)? = model.current else { Issue.record("no single run"); return }
        if let sheet = item.sheet {
            #expect(tools.sheet == sheet, "\(item): the sheet raised is \(String(describing: tools.sheet))")
            #expect(await tools.runFromSheet(item.tool) == nil, "\(item) failed in its sheet")
            #expect(tools.sheet == nil, "\(item): the sheet stayed up after a copy was written")
        }
        let expected = EditorPDFCopyName.firstChoice(for: file, suffix: item.tool.suffix)
        #expect(tools.banner?.kind == .wrote(expected), "\(item): \(String(describing: tools.banner))")
        #expect(FileManager.default.fileExists(atPath: expected), "\(item): no copy at \(expected)")
        #expect(wrote == [expected], "\(item): the window was told of \(wrote)")
        try expectUntouched(file, original, "\(item)")
        let name = (expected as NSString).lastPathComponent
        #expect(await log.holds(.info, containing: "PDF Tools in Browse wrote \(name)"),
                "\(item): the log line does not name the workspace")
    }

    /// **The banner's Open and Reveal reach the window** — Open with the copy, Reveal with it as a
    /// one-item list — through the host the single run was handed.
    @Test func theBannersOpenAndRevealReachTheWindow() async throws {
        let file = path("Banner.pdf")
        PDFFixtures.write(file, pages: 2)
        var opened: [String] = [], revealed: [[String]] = []
        let model = PanePDFTools()
        model.host = PanePDFToolHost(open: { opened.append($0) }, reveal: { revealed.append($0) })
        model.start(.rotateAll(quarterTurns: 2), paths: [file], writer: "PDF Tools in Compare")
        await model.work?.value
        guard case .single(let tools)? = model.current,
              case .wrote(let copy)? = tools.banner?.kind else { Issue.record("no copy written"); return }
        tools.host.open(copy)
        tools.host.reveal(copy)
        #expect(opened == [copy])
        #expect(revealed == [[copy]])
    }

    /// A file that changed between the menu and the lane — here, one the menu offered Protect for
    /// that turns out to be locked — is told why in the banner, and no sheet opens.
    @Test func theLanesAnswerDecidesNotTheMenus() async {
        let file = path("Changed.pdf")
        PDFFixtures.writeLocked(file, password: "pw")
        let model = PanePDFTools()
        model.start(.protect, paths: [file], writer: "PDF Tools in Browse")
        await model.work?.value
        guard case .single(let tools)? = model.current else { Issue.record("no single run"); return }
        #expect(tools.sheet == nil)
        #expect(tools.banner?.message == EditorPDFTools.lockedReason)
    }

    // MARK: Several files

    private func batch(_ kind: EditorPDFBatchKind, _ paths: [String]) -> EditorPDFBatch {
        let batch = EditorPDFBatch(kind: kind, paths: paths, writer: "PDF Tools in Compare")
        batch.confirm = { _ in true }
        return batch
    }

    /// **A batch's refusal reads as a single file's does** — a restricted file's Rotate said the
    /// toolkit's "Password Protect → Remove password", a PDF Utils menu SyncCloud does not have.
    @Test func aBatchRefusalIsInEditsWords() async throws {
        let restricted = path("Statement.pdf")
        PDFFixtures.writeRestricted(restricted)
        let batch = batch(.rotate(quarterTurns: 1), [restricted])
        await batch.run(.rotate(quarterTurns: 1))
        guard case .failed(let reason) = batch.files[0].status else {
            Issue.record("a restricted file's rotate did not fail: \(batch.files[0].status)"); return
        }
        #expect(!reason.contains("Password Protect"), "the batch sent the reader to PDF Utils: \(reason)")
        #expect(reason.contains("PDF Tools ▸ Remove Password…"), "\(reason)")
    }

    /// **N copies, N originals untouched, one parse at a time** — each file its own lane turn.
    @Test(arguments: [EditorPDFBatchTool.rotate(quarterTurns: 1), .compress(.quality(0.35)), .cleanMetadata])
    func aBatchWritesACopyOfEachAndTouchesNoOriginal(_ tool: EditorPDFBatchTool) async throws {
        let paths = ["Jan.pdf", "Feb.pdf", "Mar.pdf"].map(path)
        for file in paths {
            if case .compress = tool { PDFFixtures.writeScan(file, pages: 2) } else { PDFFixtures.write(file, pages: 2) }
        }
        let originals = try paths.map(pin)
        let kind: EditorPDFBatchKind = switch tool {
        case .rotate(let turns): .rotate(quarterTurns: turns)
        case .compress: .compress
        case .cleanMetadata: .cleanMetadata
        }
        let batch = batch(kind, paths)
        var reread: [String] = []
        batch.host = PanePDFToolHost(didWrite: { reread.append($0) })
        let log = LogCapture()
        #expect(await batch.run(tool) == .finished)
        let suffix = tool.tool(pageCount: 0).suffix
        let copies = paths.map { EditorPDFCopyName.firstChoice(for: $0, suffix: suffix) }
        for (index, copy) in copies.enumerated() {
            #expect(FileManager.default.fileExists(atPath: copy), "no copy at \(copy)")
            try expectUntouched(paths[index], originals[index], (paths[index] as NSString).lastPathComponent)
            #expect(await log.holds(.info, containing: "PDF Tools in Compare wrote \((copy as NSString).lastPathComponent)"))
        }
        #expect(batch.banner?.kind == .wroteSeveral(copies))
        #expect(batch.banner?.message.hasPrefix("Saved 3 ") == true, "\(String(describing: batch.banner))")
        // One folder, so the panes re-read once — not once per copy.
        #expect(reread.count == 1, "the panes re-read \(reread.count) times")
        #expect(PDFKitSerialAccess.peakConcurrentParses <= 1, "two parses ran at once")
    }

    /// **Cancel stops the file in hand and skips the rest; the copies already written stay**, and
    /// nothing half-written is left behind. Over Compress, which the toolkit can stop between
    /// pages, and over Rotate, which it cannot — so the batch's own checks are what stop it.
    @Test(arguments: [EditorPDFBatchTool.compress(.quality(0.35)), .rotate(quarterTurns: 1)])
    func cancellingMidBatchKeepsWhatWasWrittenAndLeavesNoStaging(_ tool: EditorPDFBatchTool) async throws {
        let paths = ["A.pdf", "B.pdf", "C.pdf"].map(path)
        for file in paths { PDFFixtures.writeScan(file, pages: 2) }
        let kind: EditorPDFBatchKind = if case .compress = tool { .compress } else { .rotate(quarterTurns: 1) }
        let batch = batch(kind, paths)
        var started: [Int] = []
        batch.fileStarted = { [weak batch] index in
            started.append(index)
            if index == 1 { batch?.cancel() }
        }
        await batch.run(tool)
        let suffix = tool.tool(pageCount: 0).suffix
        let first = EditorPDFCopyName.firstChoice(for: paths[0], suffix: suffix)
        #expect(batch.files.map(\.status) == [.wrote(first, sizes: batch.files[0].status.sizes),
                                              .skipped(.cancelled), .skipped(.cancelled)])
        #expect(started == [0, 1], "files after the cancel were started: \(started)")
        #expect(files() == ["A (\(suffix)).pdf", "A.pdf", "B.pdf", "C.pdf"], "\(files())")
        #expect(!files().contains { $0.contains(".tmp_") }, "a staging file was left: \(files())")
        #expect(batch.banner?.kind == .wrote(first))
        let noun = tool.copyNoun.one
        #expect(batch.banner?.message == "Cancelled. Saved 1 \(noun) · 2 not done")
        #expect(batch.banner?.detail == nil, "the files Cancel never reached were named: \(String(describing: batch.banner?.detail))")
    }

    /// **A batch banner's doors go to the copies still there**, as Edit's banner's do — Reveal left
    /// a trashed copy in its list, and Open opened a path that was gone.
    @Test func aBatchBannersDoorsSkipCopiesThatAreGone() throws {
        let kept = path("A (rotated).pdf"), gone = path("B (rotated).pdf")
        PDFFixtures.write(kept, pages: 1)
        let batch = batch(.rotate(quarterTurns: 1), [])
        var revealed: [[String]] = []
        batch.follow([kept, gone]) { revealed.append($0) }
        #expect(revealed == [[kept]])
        try FileManager.default.removeItem(atPath: kept)
        batch.follow([kept]) { revealed.append($0) }
        #expect(revealed.count == 1, "a door opened onto a copy that is gone")
        #expect(batch.banner?.message == "“A (rotated).pdf” is no longer there — it was moved or deleted.")
        // And the banner's buttons go through it.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/PanePDFTools.swift"), encoding: .utf8)
        #expect(!source.contains("batch.host.reveal(paths) }"), "Reveal skips follow()")
        #expect(source.contains("batch.follow(paths) { batch.host.reveal($0) }"))
    }

    /// **Cancel while a file's copy is being written writes nothing for it** — one file's run takes
    /// its copy back; a batch kept it, under "Cancelled.".
    @Test func cancellingWhileACopyIsWrittenTakesItBack() async throws {
        let paths = ["A.pdf", "B.pdf"].map(path)
        for file in paths { PDFFixtures.write(file, pages: 2) }
        let batch = batch(.rotate(quarterTurns: 1), paths)
        batch.writeStartedHook = { [weak batch] in batch?.cancel() }
        await batch.run(.rotate(quarterTurns: 1))
        #expect(batch.files.map(\.status) == [.skipped(.cancelled), .skipped(.cancelled)])
        #expect(files() == ["A.pdf", "B.pdf"], "a copy cancelled while it was written stayed: \(files())")
    }

    /// **A file moved away after it was chosen is said to be gone, by name** — not "PDFKit
    /// couldn't read it", in a banner whose sheet, listing the files, has already closed.
    @Test func aFileGoneMidBatchIsSaidToBeGoneByName() async throws {
        let paths = ["A.pdf", "Gone.pdf"].map(path)
        for file in paths { PDFFixtures.write(file, pages: 2) }
        let batch = batch(.rotate(quarterTurns: 1), paths)
        batch.fileStarted = { index in if index == 0 { try? FileManager.default.removeItem(atPath: paths[1]) } }
        await batch.run(.rotate(quarterTurns: 1))
        #expect(batch.files[1].status == .failed(EditorPDFBatch.goneReason))
        #expect(batch.banner?.message == "Saved 1 rotated copy · 1 failed", "\(batch.banner?.message ?? "no banner")")
        #expect(batch.banner?.detail == "“Gone.pdf” — \(EditorPDFBatch.goneReason)", "\(batch.banner?.detail ?? "no detail")")
    }

    /// **A file that cannot run is skipped with its reason** — no smaller after Compress, locked to
    /// open — and the banner's detail names each, with its reason, after the sheet that showed them
    /// has closed (TE113). The skipped files come first, so a run that named only the last could
    /// not pass.
    @Test func noGainAndLockedFilesAreSkippedWithTheirReasons() async throws {
        let scan = path("Scan.pdf"), lean = path("Lean.pdf"), locked = path("Locked.pdf")
        PDFFixtures.writeScan(scan, pages: 2)
        PDFFixtures.write(lean, pages: 2)
        PDFFixtures.writeLocked(locked, password: "pw")
        let batch = batch(.compress, [lean, locked, scan])
        await batch.run(.compress(.quality(0.85)))
        #expect(batch.files[0].status == .skipped(.alreadySmall), "\(batch.files[0].status)")
        #expect(batch.files[1].status == .skipped(.lockedToOpen), "\(batch.files[1].status)")
        #expect(batch.banner?.message == "Saved 1 compressed copy · 2 skipped")
        #expect(batch.banner?.detail == "“Lean.pdf” — already small\n“Locked.pdf” — locked with a password",
                "\(String(describing: batch.banner?.detail))")
        #expect(!batch.showsSheet, "the sheet stayed up")
    }

    /// **A file evicted to the cloud since the menu was built is skipped, never opened** — PDFKit
    /// opening the placeholder would download it. The batch asks as each file starts, and a single
    /// request asks before its lane read.
    @Test func aFileStillInTheCloudIsNotOpened() async {
        let local = path("Local.pdf"), cloud = path("Cloud.pdf")
        PDFFixtures.write(local, pages: 1)
        PDFFixtures.write(cloud, pages: 1)
        let batch = batch(.rotate(quarterTurns: 1), [local, cloud])
        batch.isCloudOnly = { $0 == cloud }
        await batch.run(.rotate(quarterTurns: 1))
        #expect(batch.files[1].status == .skipped(.inTheCloud))
        #expect(batch.banner?.message == "Saved 1 rotated copy · 1 skipped")
        #expect(batch.banner?.detail == "“Cloud.pdf” — still in the cloud")

        let model = PanePDFTools()
        model.isCloudOnly = { $0 == cloud }
        model.start(.compress, paths: [cloud], writer: "PDF Tools in Browse")
        await model.work?.value
        guard case .single(let tools)? = model.current else { Issue.record("no single run"); return }
        #expect(tools.sheet == nil && tools.path == nil, "a cloud-only file was read")
        #expect(tools.banner?.message == EditorPDFTools.cloudOnlyReason("Cloud.pdf"))
    }

    /// **The form question does not open a file still in the cloud** — reading its form would
    /// download it before the batch's own cloud check skipped it.
    @Test func theFormQuestionDoesNotOpenAFileStillInTheCloud() async throws {
        let form = path("Cloud form.pdf"), plain = path("Plain.pdf")
        try PDFFixtures.writeAcroForm(form)
        PDFFixtures.write(plain, pages: 1)
        let batch = batch(.compress, [form, plain])
        batch.isCloudOnly = { $0 == form }
        var asked: [EditorPDFBatchWarning] = []
        batch.confirm = { asked.append($0); return true }
        await batch.run(.compress(.quality(0.35)))
        #expect(asked.isEmpty, "the form question read the cloud-only file: \(asked.map(\.names))")
        #expect(batch.files[0].status == .skipped(.inTheCloud))
    }

    /// The selection's cloud answer is walked once per render pass, not once per selected row.
    @Test func aSelectionsCloudAnswerIsWalkedOncePerPass() {
        var asked = 0
        let paths = ["/x/\(UUID().uuidString)/A.pdf", "/x/B.pdf"]
        let now = Date()
        for _ in 0..<5 {
            _ = PanePDFSelectionCloud.anyCloudOnly(paths, now: now) { _ in asked += 1; return false }
        }
        #expect(asked == 2, "the selection was walked \(asked / 2) times")
        _ = PanePDFSelectionCloud.anyCloudOnly(paths, now: now.addingTimeInterval(2)) { _ in asked += 1; return false }
        #expect(asked == 4, "a stale answer was served")
    }

    /// **A batch says when a copy lost its original's restrictions**, as one file's run does —
    /// Compress rebuilds the document, which carries no encryption. An unrestricted original's copy
    /// says nothing of it.
    @Test func aBatchSaysWhichCopiesLostTheirRestrictions() async throws {
        let restricted = path("Restricted scan.pdf"), plain = path("Plain scan.pdf"), staged = path("staged.pdf")
        PDFFixtures.writeScan(staged, pages: 1)
        PDFFixtures.writeScan(plain, pages: 1)
        let scan = try #require(PDFDocument(url: URL(fileURLWithPath: staged)))
        #expect(scan.write(to: URL(fileURLWithPath: restricted),
                           withOptions: [.ownerPasswordOption: "owner-only",
                                         .accessPermissionsOption: NSNumber(value: PDFPermissionPreset.openAndPrintOnly)]))
        try FileManager.default.removeItem(atPath: staged)
        let batch = batch(.compress, [restricted, plain])
        batch.confirm = { _ in true }
        await batch.run(.compress(.quality(0.35)))
        #expect(batch.banner?.message == "Saved 2 compressed copies · 1 has no editing restrictions",
                "\(String(describing: batch.banner?.message))")
        #expect(EditorPDFBatch.summary([.wrote("a", sizes: nil), .wrote("b", sizes: nil)], tool: .compress(.quality(0.35)),
                                       cancelled: false, unrestricted: 2)
                == "Saved 2 compressed copies · 2 have no editing restrictions")
    }

    /// Clean Metadata skips a password-protected file — the toolkit refuses one — and says so.
    @Test func cleanMetadataSkipsAProtectedFile() async {
        let plain = path("Plain.pdf"), restricted = path("Restricted.pdf")
        PDFFixtures.write(plain, pages: 1)
        PDFFixtures.writeRestricted(restricted)
        let batch = batch(.cleanMetadata, [plain, restricted])
        await batch.run(.cleanMetadata)
        #expect(batch.files[1].status == .skipped(.passwordProtected))
        #expect(batch.banner?.message == "Saved 1 cleaned copy · 1 skipped")
        #expect(batch.banner?.detail == "“Restricted.pdf” — password-protected")
    }

    /// **One form question for the batch, naming only the files with a form** — and turned down,
    /// nothing is written.
    @Test func theFormWarningNamesOnlyTheFilesWithAForm() async throws {
        let form = path("Form.pdf"), scan = path("Scan.pdf"), plain = path("Plain.pdf")
        try PDFFixtures.writeAcroForm(form)
        PDFFixtures.writeScan(scan, pages: 1)
        PDFFixtures.write(plain, pages: 1)
        let batch = batch(.compress, [form, scan, plain])
        var asked: [EditorPDFBatchWarning] = []
        batch.confirm = { asked.append($0); return false }
        #expect(await batch.run(.compress(.quality(0.35))) == .declined)
        #expect(asked.count == 1, "asked \(asked.count) times")
        #expect(asked.first?.names == ["Form.pdf"])
        #expect(asked.first?.title == "1 of 3 files has a form that will stop being fillable")
        #expect(files() == ["Form.pdf", "Plain.pdf", "Scan.pdf"], "a declined batch wrote \(files())")
    }

    /// **A sheet that is up is a run in progress, though nothing runs yet** — a second request from
    /// the menu bar used to replace it, and the Protect sheet vanished with its password.
    @Test func aSecondRequestLeavesAnOpenSheetUp() async throws {
        let file = path("Open sheet.pdf")
        PDFFixtures.write(file, pages: 1)
        let model = PanePDFTools()
        model.start(.protect, paths: [file], writer: "PDF Tools in Browse")
        await model.work?.value
        guard case .single(let first)? = model.current else { Issue.record("no single run"); return }
        try #require(first.sheet == .protect && first.running == nil)
        model.start(.compress, paths: [file], writer: "PDF Tools in Browse")
        guard case .single(let still)? = model.current else { Issue.record("the run went"); return }
        #expect(still === first, "a second request replaced the open sheet's run")
        #expect(first.sheet == .protect)
        #expect(first.banner?.message == EditorPDFTools.busyMessage)
    }

    /// **⌘Q asks about a pane's run**, a sheet up included — and asks nothing when nothing runs.
    @Test func quittingAsksAboutAPanesRun() async throws {
        let file = path("Quit.pdf")
        PDFFixtures.write(file, pages: 1)
        let model = PanePDFTools()
        var asked = 0
        var answer = false
        model.confirmQuit = { asked += 1; return answer }
        #expect(model.mayQuit() && asked == 0, "asked with nothing running")
        model.start(.protect, paths: [file], writer: "PDF Tools in Browse")
        await model.work?.value
        #expect(model.isBusy, "the premise: the Protect sheet is up")
        #expect(!model.mayQuit() && asked == 1, "a declined question still let the app quit")
        answer = true
        #expect(model.mayQuit() && asked == 2)
    }

    /// The window refuses a second request while one runs, in the running one's banner.
    @Test func aSecondRequestWaitsItsTurn() async {
        let paths = ["One.pdf", "Two.pdf"].map(path)
        for file in paths { PDFFixtures.write(file, pages: 1) }
        let model = PanePDFTools()
        model.start(.rotateAll(quarterTurns: 1), paths: paths, writer: "PDF Tools in Browse")
        guard case .batch(let first)? = model.current else { Issue.record("no batch"); return }
        model.start(.compress, paths: [paths[0]], writer: "PDF Tools in Browse")
        if case .batch(let still)? = model.current { #expect(still === first, "a second run replaced the first") }
        await model.work?.value
        #expect(first.banner?.kind == .wroteSeveral(paths.map {
            EditorPDFCopyName.firstChoice(for: $0, suffix: "rotated") }))
    }
}

private extension EditorPDFBatch.Status {
    var sizes: String? {
        if case .wrote(_, let sizes) = self { return sizes }
        return nil
    }
}
