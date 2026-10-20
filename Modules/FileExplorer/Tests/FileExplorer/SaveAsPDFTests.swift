import Testing
import AppKit
import PDFKit
import SwiftUI
import Sync
import FileExplorerTestSupport
@testable import FileExplorer

/// A row-menu delegate with a window behind it — `canSaveAsPDF` — recording what it was asked.
@MainActor
private final class SaveBox {
    var asked: [[String]] = []
}

private struct SaveDelegate: FileActionDelegate {
    let box: SaveBox
    /// False for the same menu with no window behind it — the baseline a hidden item matches.
    var offersSave = true
    var canSaveAsPDF: Bool { offersSave }
    func handleSaveAsPDF(paths: [String]) {
        MainActor.assumeIsolated { box.asked.append(paths) }
    }
    /// PDF Tools stays live, so a PDF row draws them and the tests can tell the two items apart.
    var canRunPDFTools: Bool { true }
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

/// **Save as PDF: the offer, the row menu's item, the run, and its banner** (CV1–CV5).
///
/// Serialized: the runs print through WebKit and AppKit, one operation at a time per process.
@MainActor
@Suite(.serialized) final class SaveAsPDFTests {

    let folder = NSTemporaryDirectory() + "save-as-pdf-" + UUID().uuidString

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

    private func write(_ text: String, _ name: String) throws -> String {
        let file = path(name)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        return file
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

    private func pdfText(_ file: String) -> String {
        PDFDocument(url: URL(fileURLWithPath: file))?.string ?? ""
    }

    /// A model whose folders are all writable unless a test says otherwise, and nothing in the cloud.
    private func model(host: PaneSaveAsPDFHost = PaneSaveAsPDFHost()) -> PaneSaveAsPDF {
        let model = PaneSaveAsPDF()
        model.host = host
        model.isCloudOnly = { _ in false }
        model.geometry = { .letter }
        return model
    }

    private func run(_ model: PaneSaveAsPDF, _ paths: [String]) async {
        model.start(paths: paths, writer: "Save as PDF in a test")
        await model.work?.value
    }

    // MARK: The run — beside the original, never over anything

    /// **Beside the original, under its name, and the original untouched** (CV4, decision AN).
    @Test func savesBesideTheOriginalUnderItsName() async throws {
        let note = try write("# Trip\n\nSAVEASPDF-NOTE\n", "Trip notes.md")
        let original = try pin(note)
        var wrote: [String] = []
        let model = model(host: PaneSaveAsPDFHost(didWrite: { wrote.append($0) }))
        await run(model, [note])

        let pdf = path("Trip notes.pdf")
        #expect(files() == ["Trip notes.md", "Trip notes.pdf"])
        #expect(pdfText(pdf).contains("SAVEASPDF-NOTE"))
        #expect(wrote == [pdf], "the panes were not told about the PDF")
        #expect(model.banner?.kind == .saved(pdf))
        #expect(model.banner?.message == "Saved “Trip notes.pdf” · 1 page")
        #expect(model.banner?.detail == nil)
        #expect(!model.isRunning)
        try expectUntouched(note, original, "Trip notes.md")
    }

    /// **A name already taken gets the next number, as Finder numbers it**, and the file that had
    /// the name is left exactly as it was.
    @Test func aTakenNameGetsTheNextNumber() async throws {
        let note = try write("SAVEASPDF-CLASH\n", "Lease.txt")
        let taken = path("Lease.pdf"), alsoTaken = path("Lease 2.pdf")
        try Data("not a pdf".utf8).write(to: URL(fileURLWithPath: taken))
        let before = try pin(taken)
        let model = model()
        await run(model, [note])
        #expect(files() == ["Lease 2.pdf", "Lease.pdf", "Lease.txt"])
        #expect(pdfText(alsoTaken).contains("SAVEASPDF-CLASH"))
        try expectUntouched(taken, before, "the PDF already there")

        // And again: the next free number.
        await run(model, [note])
        #expect(files() == ["Lease 2.pdf", "Lease 3.pdf", "Lease.pdf", "Lease.txt"])
    }

    /// **A folder that cannot be written to asks where** — and a declined panel saves nothing and
    /// says why.
    @Test func aReadOnlyFolderAsksWhere() async throws {
        let note = try write("SAVEASPDF-ELSEWHERE\n", "Wi-Fi.txt")
        let elsewhere = path("Chosen.pdf")
        var asked: [(String, String)] = []
        let model = model(host: PaneSaveAsPDFHost(chooseDestination: { original, name in
            asked.append((original, name))
            return elsewhere
        }))
        model.folderIsWritable = { _ in false }
        await run(model, [note])
        #expect(asked.map(\.0) == [note])
        #expect(asked.map(\.1) == ["Wi-Fi.pdf"], "the panel did not suggest the original's name")
        #expect(pdfText(elsewhere).contains("SAVEASPDF-ELSEWHERE"))
        #expect(model.banner?.kind == .saved(elsewhere))

        let declined = self.model(host: PaneSaveAsPDFHost(chooseDestination: { _, _ in nil }))
        declined.folderIsWritable = { _ in false }
        await run(declined, [note])
        #expect(!files().contains("Wi-Fi.pdf"))
        #expect(declined.banner?.kind == .failure)
        #expect(declined.banner?.message == "Couldn’t save “Wi-Fi.txt” as PDF: its folder can’t be written to.")
    }

    /// The real answer to "can this folder take a new file", on a folder that cannot.
    @Test func aLockedFolderIsNotWritable() throws {
        let locked = path("Locked")
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        #expect(!SaveAsPDFName.folderIsWritable(for: (locked as NSString).appendingPathComponent("a.md")))
        #expect(SaveAsPDFName.folderIsWritable(for: path("a.md")))
    }

    /// **A batch saves each file, and its banner reveals them all.** A file evicted to the cloud by
    /// its turn is skipped with its reason and named; the rest are saved.
    @Test func aBatchSavesEachAndNamesWhatItCouldNot() async throws {
        let one = try write("SAVEASPDF-ONE\n", "One.md")
        let cloud = try write("x\n", "Cloud.md")
        let two = try write("SAVEASPDF-TWO\n", "Two.txt")
        let rich = path("Memo.rtf")
        try FileManager.default.copyItem(atPath: try SaveAsPDFRenderTests.fixture("Memo.rtf"), toPath: rich)
        let model = model()
        model.isCloudOnly = { $0 == cloud }
        await run(model, [one, cloud, two, rich])

        #expect(files() == ["Cloud.md", "Memo.pdf", "Memo.rtf", "One.md", "One.pdf", "Two.pdf", "Two.txt"])
        #expect(pdfText(path("Memo.pdf")).contains("SAVEASPDF-WORD-MARKER"))
        #expect(model.banner?.kind == .savedSeveral([path("One.pdf"), path("Two.pdf"), path("Memo.pdf")]))
        #expect(model.banner?.message == "Saved 3 of 4 as PDF. “Cloud.md” couldn’t be saved.")
        #expect(model.banner?.detail == "Cloud.md: it isn’t downloaded")

        let all = self.model()
        await run(all, [one, two])
        #expect(all.banner?.message == "Saved 2 files as PDF.")
    }

    /// **Stop ends the run after the file in hand**; what was saved stays, and the banner says how
    /// far it got.
    @Test func stopEndsTheRunBetweenFiles() async throws {
        let paths = try ["A.md", "B.md", "C.md"].map { try write("SAVEASPDF-\($0)\n", $0) }
        var model: PaneSaveAsPDF!
        model = self.model(host: PaneSaveAsPDFHost(didWrite: { _ in model.stop() }))
        await run(model, paths)
        #expect(files() == ["A.md", "A.pdf", "B.md", "C.md"])
        #expect(model.banner?.message == "Stopped. Saved 1 of 3 as PDF.")
        #expect(model.banner?.kind == .savedSeveral([path("A.pdf")]))
    }

    /// One run at a time: a second request mid-run is told so, and none of its files is saved.
    @Test func aSecondRequestWhileRunningIsRefused() async throws {
        let first = try write("one\n", "First.md"), second = try write("two\n", "Second.md")
        let model = model()
        model.start(paths: [first], writer: "test")
        model.start(paths: [second], writer: "test")
        #expect(model.busyNote != nil)
        await model.work?.value
        #expect(files() == ["First.md", "First.pdf", "Second.md"])
    }

    /// Progress reads as the mockup draws it.
    @Test func progressReadsAsTheMockup() {
        #expect(PaneSaveAsPDFLayer.progressMessage(.init(done: 3, total: 12, name: "x")) == "Saving 12 files as PDF · 4 of 12")
        #expect(PaneSaveAsPDFLayer.progressMessage(.init(done: 0, total: 1, name: "Lease.docx")) == "Saving “Lease.docx” as PDF…")
    }

    // MARK: The banner's words

    /// A deck of pictures with no words Vision could read says its text can't be searched.
    @Test func aDeckOfPicturesIsSaidSo() {
        let deck = SaveAsPDFSummary.Saved(name: "Old Pitch.pptx", copy: "/f/Old Pitch.pdf", pageCount: 14,
                                          picturePages: 14, isRecognised: false)
        let one = SaveAsPDFSummary.banner(total: 1, saved: [deck], failed: [], stoppedBefore: 0)
        #expect(one.message == "Saved “Old Pitch.pdf” · 14 pages")
        #expect(one.detail == "Its slides were pictures, so their text can’t be selected or searched.")

        let memo = SaveAsPDFSummary.Saved(name: "Memo.docx", copy: "/f/Memo.pdf", pageCount: 1,
                                          picturePages: 0, isRecognised: false)
        let failed = SaveAsPDFSummary.Failed(name: "Broken.docx", reason: "macOS couldn’t read it")
        let batch = SaveAsPDFSummary.banner(total: 3, saved: [memo, deck], failed: [failed], stoppedBefore: 0)
        #expect(batch.message == "Saved 2 of 3 as PDF. “Broken.docx” couldn’t be saved.")
        #expect(batch.detail == "Slides in “Old Pitch.pptx” were pictures, so their text can’t be selected or searched. "
                + "Broken.docx: macOS couldn’t read it")
        // A deck with text says nothing about pictures.
        #expect(SaveAsPDFSummary.banner(total: 1, saved: [memo], failed: [], stoppedBefore: 0).detail == nil)
    }

    /// **A deck of pictures whose words were recognised says so, and that they may be wrong** — the
    /// sentence Abhishek chose on 2026-10-19 — and a batch names each kind of deck apart.
    @Test func aDeckOfRecognisedPicturesIsSaidSo() {
        let read = SaveAsPDFSummary.Saved(name: "Survey.pptx", copy: "/f/Survey.pdf", pageCount: 6,
                                          picturePages: 6, isRecognised: true)
        let one = SaveAsPDFSummary.banner(total: 1, saved: [read], failed: [], stoppedBefore: 0)
        #expect(one.message == "Saved “Survey.pdf” · 6 pages")
        #expect(one.detail == "Its slides were pictures; their text was recognised so it can be searched, but may have mistakes.")

        let blank = SaveAsPDFSummary.Saved(name: "Photos.pptx", copy: "/f/Photos.pdf", pageCount: 3,
                                           picturePages: 3, isRecognised: false)
        let batch = SaveAsPDFSummary.banner(total: 2, saved: [read, blank], failed: [], stoppedBefore: 0)
        #expect(batch.detail == "Slides in “Survey.pptx” were pictures; their text was recognised so it can be searched, "
                + "but may have mistakes. Slides in “Photos.pptx” were pictures, so their text can’t be selected or searched.")
    }

    /// **A deck only partly pictures says how many were** — the count Abhishek chose on 2026-10-19 —
    /// and nothing at all when Vision read no words in them: a text deck's slide of photos is no news.
    @Test func aDeckPartlyOfPicturesCountsThem() {
        let council = SaveAsPDFSummary.Saved(name: "Council.pptx", copy: "/f/Council.pdf", pageCount: 50,
                                             picturePages: 1, isRecognised: true)
        let one = SaveAsPDFSummary.banner(total: 1, saved: [council], failed: [], stoppedBefore: 0)
        #expect(one.message == "Saved “Council.pdf” · 50 pages")
        #expect(one.detail == "1 of its 50 slides was a picture; its text was recognised so it can be searched, "
                + "but may have mistakes.")

        var three = council
        three.picturePages = 3
        #expect(SaveAsPDFSummary.banner(total: 1, saved: [three], failed: [], stoppedBefore: 0).detail
                == "3 of its 50 slides were pictures; their text was recognised so it can be searched, but may have mistakes.")

        let survey = SaveAsPDFSummary.Saved(name: "Survey.pptx", copy: "/f/Survey.pdf", pageCount: 6,
                                            picturePages: 6, isRecognised: true)
        let batch = SaveAsPDFSummary.banner(total: 2, saved: [survey, council], failed: [], stoppedBefore: 0)
        #expect(batch.detail == "Slides in “Survey.pptx” and “Council.pptx” (1 of 50) were pictures; their text was "
                + "recognised so it can be searched, but may have mistakes.")

        var unread = council
        unread.isRecognised = false
        #expect(SaveAsPDFSummary.banner(total: 1, saved: [unread], failed: [], stoppedBefore: 0).detail == nil)
        #expect(SaveAsPDFSummary.banner(total: 2, saved: [unread, unread], failed: [], stoppedBefore: 0).detail == nil)
    }

    @Test func everyFileFailingIsAFailure() {
        let failed = ["A.docx", "B.pptx"].map { SaveAsPDFSummary.Failed(name: $0, reason: "macOS couldn’t read it") }
        let banner = SaveAsPDFSummary.banner(total: 2, saved: [], failed: failed, stoppedBefore: 0)
        #expect(banner.kind == .failure)
        #expect(banner.message == "Couldn’t save any of the 2 files as PDF.")
    }

    @Test func namesAreListedThenCounted() {
        #expect(SaveAsPDFSummary.names(["A"]) == "“A”")
        #expect(SaveAsPDFSummary.names(["A", "B"]) == "“A” and “B”")
        #expect(SaveAsPDFSummary.names(["A", "B", "C"]) == "“A”, “B” and “C”")
        #expect(SaveAsPDFSummary.names(["A", "B", "C", "D", "E"]) == "“A”, “B”, “C” and 2 more")
    }

    // MARK: Names

    /// A name near the volume's limit is shortened a character at a time, so its PDF can exist.
    @Test func aLongNameIsShortenedToFit() {
        let long = String(repeating: "é", count: 200) + ".docx"
        let name = (SaveAsPDFName.firstChoice(for: "/f/" + long) as NSString).lastPathComponent
        #expect(name.hasSuffix(".pdf"))
        #expect(EditorPDFCopyName.nameLength(name) <= EditorPDFCopyName.longestName)
        #expect(EditorPDFCopyName.nameLength(name) > EditorPDFCopyName.longestName - 2, "shortened more than it had to be")
        #expect(SaveAsPDFName.firstChoice(for: "/f/Lease Renewal 2026.docx") == "/f/Lease Renewal 2026.pdf")
    }

    // MARK: The offer

    /// **Hidden, not greyed**: a folder, a PDF, a kind nothing converts, a lock file, a cloud-only
    /// file, and any selection holding one of them.
    @Test func whatNothingConvertsIsNotOffered() throws {
        let doc = path("Lease.docx"), md = path("Notes.md"), pdf = path("Statement.pdf"), png = path("Photo.png")
        let lock = path("~$Lease.docx"), cloud = path("Cloud.pptx"), sub = path("Sub")
        for file in [doc, md, pdf, png, lock, cloud] { try Data("x".utf8).write(to: URL(fileURLWithPath: file)) }
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        CloudOnlyBadgeCache.record(cloud, isCloudOnly: true)
        defer { CloudOnlyBadgeCache.forget(cloud) }

        let hidden: [(String, [FileNode])] = [
            ("nothing", []),
            ("a folder", [node(sub, isDirectory: true)]),
            ("a PDF", [node(pdf)]),
            ("a picture", [node(png)]),
            ("Word's lock file", [node(lock)]),
            ("a cloud-only deck", [node(cloud)]),
            ("a .docx with a PDF", [node(doc), node(pdf)]),
            ("a .docx with a folder", [node(doc), node(sub, isDirectory: true)]),
            ("a .docx with a picture", [node(doc), node(png)]),
            ("a .docx with a cloud-only deck", [node(doc), node(cloud)]),
        ]
        for (label, nodes) in hidden {
            #expect(SaveAsPDFOffer.forSelection(nodes) == nil, "\(label) is offered Save as PDF")
        }
        #expect(SaveAsPDFOffer.forSelection([node(doc)]) == .single(path: doc))
        #expect(SaveAsPDFOffer.forSelection([node(doc), node(md)]) == .several(paths: [doc, md]))
        #expect(SaveAsPDFOffer.several(paths: [doc, md, pdf]).title == "Save 3 as PDFs")
        #expect(SaveAsPDFOffer.single(path: doc).title == "Save as PDF")
    }

    // MARK: Where the item is drawn

    /// Every item of the row menu over `nodes` (the first is the row clicked), in drawn order, as
    /// widths — `PanePDFToolsTests`' drawn-row approach.
    private static func drawnRowWidths(_ nodes: [FileNode], delegate: FileActionDelegate) -> [CGFloat] {
        let menu = FileContextMenu(row: PaneRow(side: .left, version: 1, node: nodes[0], children: nil),
                                   selection: nodes.count > 1 ? Set(nodes.map(\.id)) : [],
                                   tree: PaneTree(side: .left, version: 1, nodes: nodes),
                                   otherTree: PaneTree(side: .right, version: 1, nodes: []),
                                   otherSelection: [], isLeft: true, currentPath: "/",
                                   delegate: delegate, otherPaneName: "Right", isSingleSource: false,
                                   onQuickLook: { _ in }, selectionResolver: PaneSelectionResolver())
        return rings(AnyView(VStack(alignment: .leading, spacing: 0) { menu }.frame(width: 260)), height: 900)
            .map(\.width)
    }

    private static func soloWidth<V: View>(_ item: V) -> CGFloat {
        rings(AnyView(VStack(alignment: .leading) { item }.frame(width: 260)), height: 80).first?.width ?? 0
    }

    private static func rings(_ view: AnyView, height: CGFloat) -> [CGRect] {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        host.layoutSubtreeIfNeeded()
        return FocusRings.frames(in: host).sorted { $0.minY < $1.minY }
    }

    /// **One convertible file draws Save as PDF in PDF Tools' section: after Quick Look, before
    /// Rename** — and clicking it hands the delegate that file.
    @Test func oneFileDrawsTheItemBetweenQuickLookAndRename() throws {
        let doc = path("Lease Renewal 2026.docx")
        try Data("x".utf8).write(to: URL(fileURLWithPath: doc))
        let delegate = SaveDelegate(box: SaveBox())
        let item = Self.soloWidth(SaveAsPDFMenuItem(offer: .single(path: doc), delegate: delegate))
        let quickLook = Self.soloWidth(Button(action: {}) { Label("Quick Look", systemImage: "doc.viewfinder") })
        let rename = Self.soloWidth(Button(action: {}) { Label("Rename", systemImage: "pencil") })
        #expect(Set([item, quickLook, rename]).count == 3, "two labels measure the same")

        let drawn = Self.drawnRowWidths([node(doc)], delegate: delegate)
        #expect(drawn.filter { $0 == item }.count == 1, "Save as PDF is drawn \(drawn.filter { $0 == item }.count) times")
        let at = try #require(drawn.firstIndex(of: item), "Save as PDF is not drawn: \(drawn)")
        let quickLookAt = try #require(drawn.firstIndex(of: quickLook))
        let renameAt = try #require(drawn.firstIndex(of: rename))
        #expect(quickLookAt < at && at < renameAt, "Save as PDF is at \(at), Quick Look \(quickLookAt), Rename \(renameAt)")
        // With no window behind the menu, it is not there at all.
        let baseline = Self.drawnRowWidths([node(doc)], delegate: SaveDelegate(box: SaveBox(), offersSave: false))
        #expect(drawn.count == baseline.count + 1)
    }

    /// **A PDF keeps PDF Tools and is never offered Save as PDF** — its whole menu is the menu with
    /// no Save as PDF at all.
    @Test func aPDFRowDrawsNoSaveAsPDF() {
        let pdf = path("Statement.pdf")
        PDFFixtures.write(pdf, pages: 1)
        let drawn = Self.drawnRowWidths([node(pdf)], delegate: SaveDelegate(box: SaveBox()))
        #expect(drawn == Self.drawnRowWidths([node(pdf)], delegate: SaveDelegate(box: SaveBox(), offersSave: false)))
        #expect(!drawn.contains(Self.soloWidth(SaveAsPDFMenuItem(offer: .single(path: pdf),
                                                                delegate: SaveDelegate(box: SaveBox())))))
    }

    /// **Several files draw "Save 3 as PDFs" first after Refresh**; a selection with a PDF in it
    /// draws none.
    @Test func severalFilesDrawTheBatchItemFirstAfterRefresh() throws {
        let paths = ["Lease.docx", "Deck.pptx", "Trip.md"].map(path)
        for file in paths { try Data("x".utf8).write(to: URL(fileURLWithPath: file)) }
        let box = SaveBox()
        let delegate = SaveDelegate(box: box)
        let item = Self.soloWidth(SaveAsPDFMenuItem(offer: .several(paths: paths), delegate: delegate))
        let drawn = Self.drawnRowWidths(paths.map { node($0) }, delegate: delegate)
        #expect(drawn.firstIndex(of: item) == 1, "Save 3 as PDFs is not first after Refresh: \(drawn)")

        let pdf = path("Statement.pdf")
        PDFFixtures.write(pdf, pages: 1)
        let mixed = (paths + [pdf]).map { node($0) }
        #expect(Self.drawnRowWidths(mixed, delegate: delegate)
                == Self.drawnRowWidths(mixed, delegate: SaveDelegate(box: SaveBox(), offersSave: false)),
                "a selection with a PDF in it draws Save as PDF")
    }
}
