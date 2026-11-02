import Testing
import Foundation
import PDFKit
import PDFToolkitCore
import Sync
import FileExplorerTestSupport
@testable import FileExplorer

/// **The PDF tools and Save as PDF, run from a request** (TE294 step 1) — what an Ask Claude card
/// will call: a whole tool with its options chosen, no sheet, no alert, and an ending handed back as
/// data with the stamp of every file written, never posted to the pane.
///
/// Serialized, because every run takes `PDFKitSerialAccess`'s one lane.
@MainActor
@Suite(.serialized) final class PDFRunRequestTests {
    let folder = NSTemporaryDirectory() + "pdf-run-request-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String, in sub: String? = nil) -> String {
        let base = sub.map { (folder as NSString).appendingPathComponent($0) } ?? folder
        return (base as NSString).appendingPathComponent(name)
    }

    private func files(in sub: String? = nil) -> [String] {
        let base = sub.map { (folder as NSString).appendingPathComponent($0) } ?? folder
        return ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted()
    }

    private func subfolder(_ name: String) throws -> String {
        let made = (folder as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        return made
    }

    private func stamp(_ file: String) -> EditorFileStore.Stamp? { EditorFileStore.stamp(ofPath: file) }

    /// The original's bytes, and its date set into the past so a write this second can't hide.
    private func pin(_ file: String) throws -> (Data, Date) {
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file)
        return (try Data(contentsOf: URL(fileURLWithPath: file)), past)
    }

    private func expectUntouched(_ file: String, _ original: (Data, Date), _ label: String) throws {
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == original.0, "\(label): the original's bytes changed")
        let modified = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
        #expect(modified == original.1, "\(label): the original's date moved")
    }

    /// Runs one tool from a request and hands back its ending, the model, and how often it asked.
    private func run(_ tool: EditorPDFTool, on file: String, folder: String? = nil,
                     expecting: EditorFileStore.Stamp?? = nil, allow: Bool = true,
                     model: PanePDFTools = PanePDFTools()) async -> (PDFRunResult?, PanePDFTools, Int) {
        var result: PDFRunResult?
        var asked = 0
        model.startFromChat(tool, path: file, folder: folder, expecting: expecting ?? stamp(file),
                            writer: "Ask Claude", allow: { _ in asked += 1; return allow },
                            completion: { result = $0 })
        await model.work?.value
        return (result, model, asked)
    }

    // MARK: One file

    enum Whole: String, CaseIterable {
        case rotateSome, extract, delete, reorder, compress, cleanMetadata, protect, removePassword

        var tool: EditorPDFTool {
            switch self {
            case .rotateSome: return .rotate(pages: [1], quarterTurns: 1)
            case .extract: return .extract([1, 2])
            case .delete: return .deletePages([0])
            case .reorder: return .reorder([2, 1, 0])
            case .compress: return .compress(.quality(0.35))
            case .cleanMetadata: return .cleanMetadata(.cleared)
            case .protect: return .protect(restrictEditing: false, password: EditorPDFSecret("pw"))
            case .removePassword: return .removePassword(EditorPDFSecret("pw"))
            }
        }

        /// None for a file locked to open: its pages aren't counted until it is unlocked.
        var pagesInCopy: Int? {
            switch self {
            case .extract, .delete: return 2
            case .removePassword: return nil
            default: return 3
            }
        }
    }

    /// **Each tool writes its copy under the menu's name, with the stamp of the file the writer
    /// made** — no sheet, no alert, nothing on the banner the pane would post, and the original
    /// as it was.
    @Test(arguments: Whole.allCases)
    func aToolFromARequestWritesItsCopyAndSaysExactlyWhat(_ whole: Whole) async throws {
        let file = path("\(whole.rawValue).pdf")
        switch whole {
        case .compress: PDFFixtures.writeScan(file, pages: 3)
        case .removePassword: PDFFixtures.writeLocked(file, password: "pw", pages: 3)
        default: PDFFixtures.write(file, pages: 3)
        }
        let original = try pin(file)
        var reread: [String] = []
        let model = PanePDFTools()
        model.host = PanePDFToolHost(didWrite: { reread.append($0) })
        let (result, _, _) = await run(whole.tool, on: file, model: model)

        let copy = EditorPDFCopyName.firstChoice(for: file, suffix: whole.tool.suffix)
        #expect(result?.outcome == .wrote, "\(whole): \(String(describing: result))")
        #expect(result?.written.map(\.path) == [copy], "\(whole): \(String(describing: result?.written))")
        #expect(result?.written.first?.stamp == stamp(copy), "\(whole): the stamp is not the written file's")
        #expect(result?.written.first?.source == file)
        #expect(result?.written.first?.pageCount == whole.pagesInCopy, "\(whole)")
        #expect(result?.message.hasPrefix("Saved “\((copy as NSString).lastPathComponent)”") == true,
                "\(whole): \(result?.message ?? "no message")")
        guard case .single(let tools)? = model.current else { Issue.record("\(whole): no single run"); return }
        #expect(tools.sheet == nil, "\(whole): a sheet was raised")
        #expect(tools.banner == nil, "\(whole): the ending is on the banner the pane posts")
        #expect(reread == [copy], "\(whole): the panes were not told about the copy")
        try expectUntouched(file, original, "\(whole)")
    }

    /// **A file that changed since it was chosen is left alone**, in words that promise no reload —
    /// it is not open anywhere.
    @Test func aFileChangedSinceItWasChosenIsLeftAlone() async throws {
        let file = path("Changed.pdf")
        PDFFixtures.write(file, pages: 2)
        _ = try pin(file)
        let chosen = stamp(file)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file)
        let (result, _, _) = await run(.rotate(pages: [0, 1], quarterTurns: 1), on: file, expecting: chosen)
        #expect(result?.outcome == .failed)
        #expect(result?.message == PanePDFTools.changedSinceAskedReason("Changed.pdf"), "\(result?.message ?? "")")
        #expect(!(result?.message.contains("reloads") ?? true))
        #expect(files() == ["Changed.pdf"], "a copy was written: \(files())")
    }

    /// **The menu's protection rules hold** — the run itself doesn't check them, so a request
    /// would otherwise reach the toolkit: Protect on a locked file, Clean Metadata on a protected one.
    @Test func theMenusProtectionRulesHold() async throws {
        let locked = path("Locked.pdf")
        PDFFixtures.writeLocked(locked, password: "pw")
        let (protect, _, _) = await run(.protect(restrictEditing: false, password: EditorPDFSecret("x")), on: locked)
        #expect(protect?.outcome == .failed)
        #expect(protect?.message == EditorPDFTools.lockedReason, "\(protect?.message ?? "")")

        let restricted = path("Restricted.pdf")
        PDFFixtures.writeRestricted(restricted)
        let (clean, _, _) = await run(.cleanMetadata(.cleared), on: restricted)
        #expect(clean?.outcome == .failed, "\(String(describing: clean))")
        #expect(files() == ["Locked.pdf", "Restricted.pdf"], "a copy was written: \(files())")
    }

    /// **The form question goes to `allow`, never an alert** — and a loss it doesn't accept
    /// writes nothing.
    @Test func aLossTheAskerDidNotAcceptWritesNothing() async throws {
        let form = path("Form.pdf")
        try PDFFixtures.writeAcroForm(form)
        let (declined, _, asked) = await run(.compress(.quality(0.35)), on: form, allow: false)
        #expect(asked == 1, "the form question was asked \(asked) times")
        #expect(declined?.outcome == .declined)
        #expect(files() == ["Form.pdf"], "a declined run wrote \(files())")

        let (accepted, _, _) = await run(.compress(.quality(0.35)), on: form, allow: true)
        #expect(accepted?.outcome == .wrote || accepted?.outcome == .nothingWritten,
                "\(String(describing: accepted))")
    }

    /// **A folder the asker chose takes the copy**, under the same name — for an original whose
    /// own folder can't be written to.
    @Test func aCopyGoesIntoTheFolderAskedFor() async throws {
        let file = path("Lease.pdf")
        PDFFixtures.write(file, pages: 2)
        let elsewhere = try subfolder("Elsewhere")
        let (result, _, _) = await run(.rotate(pages: [0, 1], quarterTurns: 2), on: file, folder: elsewhere)
        let copy = (elsewhere as NSString).appendingPathComponent("Lease (rotated).pdf")
        #expect(result?.written.map(\.path) == [copy], "\(String(describing: result?.written))")
        #expect(files() == ["Elsewhere", "Lease.pdf"])
    }

    /// **A menu click during a request's run is refused in the pane, as during any run** — and
    /// the request's own ending never replaces that note. A second request is told it's busy.
    @Test func aMenuClickDuringARequestsRunStillGetsItsNote() async throws {
        let file = path("Busy.pdf")
        PDFFixtures.write(file, pages: 2)
        let model = PanePDFTools()
        var first: PDFRunResult?, second: PDFRunResult?
        model.startFromChat(.rotate(pages: [0], quarterTurns: 1), path: file, expecting: stamp(file),
                            writer: "Ask Claude", allow: { _ in true }, completion: { first = $0 })
        model.start(.compress, paths: [file], writer: "PDF Tools in Browse")
        // What the pane's layer posts at once, as it does for a menu click during any run.
        guard case .single(let tools)? = model.current else { Issue.record("no single run"); return }
        #expect(tools.banner?.message == EditorPDFTools.busyMessage, "\(tools.banner?.message ?? "no note")")
        model.startFromChat(.extract([0]), path: file, expecting: stamp(file), writer: "Ask Claude",
                            allow: { _ in true }, completion: { second = $0 })
        #expect(second?.outcome == .busy)
        await model.work?.value
        #expect(first?.outcome == .wrote, "\(String(describing: first))")
        #expect(tools.banner?.message != first?.message, "the request's ending reached the pane's banner")
    }

    // MARK: Several files

    /// **A batch from a request keeps each copy's stamp, and leaves a file that changed since it
    /// was chosen alone** — the rest still run; nothing reaches the pane's banner.
    @Test func aBatchFromARequestKeepsEachStampAndSkipsAChangedFile() async throws {
        let paths = ["Jan.pdf", "Feb.pdf", "Mar.pdf"].map { path($0) }
        for file in paths { PDFFixtures.write(file, pages: 2) }
        for file in paths { _ = try pin(file) }
        var expected: [String: EditorFileStore.Stamp] = [:]
        for file in paths { expected[file] = stamp(file) }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: paths[1])

        let model = PanePDFTools()
        var result: PDFRunResult?
        model.startBatchFromChat(.rotate(quarterTurns: 1), paths: paths, expecting: expected,
                                 writer: "Ask Claude", allow: { _ in true }, completion: { result = $0 })
        await model.work?.value

        let copies = [paths[0], paths[2]].map { EditorPDFCopyName.firstChoice(for: $0, suffix: "rotated") }
        #expect(result?.outcome == .partlyWrote, "\(String(describing: result))")
        #expect(result?.written.map(\.path) == copies)
        #expect(result?.written.map(\.stamp) == copies.map { stamp($0) })
        #expect(result?.skipped == [PDFRunResult.Skipped(path: paths[1], reason: EditorPDFBatch.changedReason)])
        guard case .batch(let batch)? = model.current else { Issue.record("no batch"); return }
        #expect(batch.banner == nil, "the ending is on the banner the pane posts")
        #expect(!batch.showsSheet)
    }

    /// **A batch's copies go into the folder asked for**, and its form question goes to `allow`.
    @Test func aBatchsCopiesGoIntoTheFolderAskedFor() async throws {
        let paths = ["A.pdf", "B.pdf"].map { path($0) }
        for file in paths { PDFFixtures.write(file, pages: 1) }
        let elsewhere = try subfolder("Out")
        let model = PanePDFTools()
        var result: PDFRunResult?
        model.startBatchFromChat(.rotate(quarterTurns: 2), paths: paths, folder: elsewhere, expecting: [:],
                                 writer: "Ask Claude", allow: { _ in true }, completion: { result = $0 })
        await model.work?.value
        #expect(result?.outcome == .wrote)
        #expect(files(in: "Out") == ["A (rotated).pdf", "B (rotated).pdf"], "\(files(in: "Out"))")
    }

    // MARK: Combine and Split

    /// **Combine from a request: no sheet, the stamp of the file written, nothing on the banner.**
    @Test func combineFromARequestSaysExactlyWhatItWrote() async throws {
        let paths = ["A.pdf", "B.pdf"].map { path($0) }
        for file in paths { PDFFixtures.write(file, pages: 1) }
        var expected: [String: EditorFileStore.Stamp] = [:]
        for file in paths { expected[file] = stamp(file) }
        let model = PanePDFTools()
        var result: PDFRunResult?
        model.startCombineSplitFromChat(.combine(paths), name: "Both", expecting: expected, writer: "Ask Claude",
                                        completion: { result = $0 })
        guard case .combineSplit(let run)? = model.current else { Issue.record("no run"); return }
        await model.work?.value
        let combined = path("Both.pdf")
        #expect(result?.outcome == .wrote, "\(String(describing: result))")
        #expect(result?.written.map(\.path) == [combined])
        #expect(result?.written.first?.stamp == stamp(combined))
        #expect(result?.written.first?.pageCount == 2)
        #expect(!run.showsSheet && run.banner == nil)
    }

    /// **Split from a request writes each part, says which, and never raises its sheet.**
    @Test func splitFromARequestWritesEachPart() async throws {
        let file = path("Statement.pdf")
        PDFFixtures.write(file, pages: 3)
        let model = PanePDFTools()
        var result: PDFRunResult?
        var sheetSeen = false
        model.startCombineSplitFromChat(.split(file), splitAt: [2], expecting: [file: stamp(file)!], writer: "Ask Claude",
                                        completion: { result = $0 })
        guard case .combineSplit(let run)? = model.current else { Issue.record("no run"); return }
        let watch = run.$showsSheet.sink { if $0 { sheetSeen = true } }
        await model.work?.value
        watch.cancel()
        #expect(result?.outcome == .wrote, "\(String(describing: result))")
        #expect(result?.written.map(\.path) == ["Statement (page 1).pdf", "Statement (pages 2–3).pdf"].map { path($0) })
        #expect(!sheetSeen, "a request's split raised its sheet")
        #expect(run.banner == nil)
    }

    /// A file changed since the asker read it is not split, and its sentence says why.
    @Test func splitFromARequestLeavesAChangedFileAlone() async throws {
        let file = path("Moved.pdf")
        PDFFixtures.write(file, pages: 3)
        let chosen = EditorFileStore.Stamp(modifiedAt: .distantPast, size: 1)
        let model = PanePDFTools()
        var result: PDFRunResult?
        model.startCombineSplitFromChat(.split(file), splitAt: [2], expecting: [file: chosen], writer: "Ask Claude",
                                        completion: { result = $0 })
        await model.work?.value
        #expect(result?.outcome == .failed)
        #expect(result?.message == PanePDFTools.changedSinceAskedReason("Moved.pdf"), "\(result?.message ?? "")")
        #expect(files() == ["Moved.pdf"])
    }
}

/// **Save as PDF from a request** (TE294 step 1): nothing asks where to save, a chosen folder gets
/// the keep-both rule, and the ending comes back as data with each PDF's stamp.
@MainActor
@Suite(.serialized) final class SaveAsPDFRequestTests {
    let folder = NSTemporaryDirectory() + "save-as-pdf-request-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func write(_ text: String, _ name: String) throws -> String {
        let file = path(name)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    private func model(asked: @escaping () -> Void = {}) -> PaneSaveAsPDF {
        let model = PaneSaveAsPDF()
        model.host = PaneSaveAsPDFHost(chooseDestination: { _, _ in asked(); return nil })
        model.isCloudOnly = { _ in false }
        model.geometry = { .letter }
        return model
    }

    private func run(_ model: PaneSaveAsPDF, _ paths: [String], folders: [String: String] = [:],
                     expecting: [String: EditorFileStore.Stamp] = [:]) async -> PDFRunResult? {
        var result: PDFRunResult?
        model.startFromChat(paths: paths, folders: folders, expecting: expecting, writer: "Ask Claude",
                            completion: { result = $0 })
        await model.work?.value
        return result
    }

    /// **Beside the original, with the written file's stamp, and nothing on the banner.**
    @Test func savesBesideTheOriginalAndSaysExactlyWhat() async throws {
        let note = try write("# Trip\n", "Trip.md")
        let model = model()
        let result = await run(model, [note], expecting: [note: EditorFileStore.stamp(ofPath: note)!])
        let pdf = path("Trip.pdf")
        #expect(result?.outcome == .wrote, "\(String(describing: result))")
        #expect(result?.written == [PDFWrittenFile(source: note, path: pdf, stamp: EditorFileStore.stamp(ofPath: pdf)!,
                                                   bytes: (try? Data(contentsOf: URL(fileURLWithPath: pdf)).count) ?? -1,
                                                   pageCount: 1)])
        #expect(result?.message == "Saved “Trip.pdf” · 1 page")
        #expect(model.banner == nil, "the ending is on the banner the pane posts")
    }

    /// **A chosen folder that already holds the name gets “Name 2.pdf”** — the menu's save panel
    /// can replace a file; a request never does. Nobody is asked where.
    @Test func aChosenFolderGetsTheKeepBothRule() async throws {
        let note = try write("Body\n", "Note.txt")
        let out = (folder as NSString).appendingPathComponent("Out")
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let taken = (out as NSString).appendingPathComponent("Note.pdf")
        try Data("not mine".utf8).write(to: URL(fileURLWithPath: taken))
        var asked = 0
        let model = model(asked: { asked += 1 })
        model.folderIsWritable = { _ in false }
        let result = await run(model, [note], folders: [note: out])
        #expect(result?.written.map(\.path) == [(out as NSString).appendingPathComponent("Note 2.pdf")],
                "\(String(describing: result))")
        #expect(try Data(contentsOf: URL(fileURLWithPath: taken)) == Data("not mine".utf8), "the file there was replaced")
        #expect(asked == 0, "the save panel was asked for")
    }

    /// **A folder that can't be written to, with no folder chosen, fails the file** — nobody is
    /// asked mid-run.
    @Test func anUnwritableFolderWithNoChoiceFailsTheFile() async throws {
        let note = try write("Body\n", "Locked.txt")
        var asked = 0
        let model = model(asked: { asked += 1 })
        model.folderIsWritable = { _ in false }
        let result = await run(model, [note])
        #expect(result?.outcome == .failed)
        #expect(result?.message == "Couldn’t save “Locked.txt” as PDF: its folder can’t be written to.",
                "\(result?.message ?? "")")
        #expect(asked == 0)
    }

    /// **A file that changed since it was chosen is left alone; the others are saved.**
    @Test func aFileChangedSinceItWasChosenIsLeftAlone() async throws {
        let one = try write("One\n", "One.txt"), two = try write("Two\n", "Two.txt")
        let chosen = [one: EditorFileStore.stamp(ofPath: one)!,
                      two: EditorFileStore.Stamp(modifiedAt: .distantPast, size: 1)]
        let result = await run(model(), [one, two], expecting: chosen)
        #expect(result?.outcome == .partlyWrote, "\(String(describing: result))")
        #expect(result?.written.map(\.path) == [path("One.pdf")])
        #expect(result?.skipped == [PDFRunResult.Skipped(path: two, reason: "it changed since it was chosen")])
    }
}
