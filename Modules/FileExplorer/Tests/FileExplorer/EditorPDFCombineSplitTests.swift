import Testing
import Foundation
import PDFKit
import Sync
@testable import FileExplorer

/// **Combine and Split** (TE294, decision IC) — from a pane's menu: the sheet's rules, the files
/// they write and what they say.
///
/// Serialized, because every run takes `PDFKitSerialAccess`'s one lane.
@MainActor
@Suite(.serialized) final class EditorPDFCombineSplitTests {
    let folder = NSTemporaryDirectory() + "combine-split-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String, in sub: String? = nil) -> String {
        var base = folder
        if let sub {
            base = (folder as NSString).appendingPathComponent(sub)
            try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        }
        return (base as NSString).appendingPathComponent(name)
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    private func pages(_ file: String) -> Int { PDFDocument(url: URL(fileURLWithPath: file))?.pageCount ?? -1 }

    private func width(_ file: String, page: Int) -> CGFloat {
        PDFDocument(url: URL(fileURLWithPath: file))?.page(at: page)?.bounds(for: .mediaBox).width ?? -1
    }

    // MARK: Split's parts

    /// **"4, 9" on 12 pages: pages 1–3, 4–8, 9–12** — each start is the first page of a new file.
    @Test func splitsAtThePagesTyped() throws {
        #expect(try EditorPDFCombineSplit.parts("4, 9", pageCount: 12).get()
                == [[0, 1, 2], [3, 4, 5, 6, 7], [8, 9, 10, 11]])
        #expect(try EditorPDFCombineSplit.parts("2", pageCount: 2).get() == [[0], [1]])
        #expect(try EditorPDFCombineSplit.parts(" 3;5 ", pageCount: 6).get() == [[0, 1], [2, 3], [4, 5]])
    }

    /// Every start that can't be one is refused with a sentence of its own.
    @Test func refusesStartsThatCantBe() {
        typealias P = EditorPDFCombineSplit.SplitProblem
        func problem(_ typed: String, _ count: Int = 12) -> P? {
            if case .failure(let p) = EditorPDFCombineSplit.parts(typed, pageCount: count) { return p }
            return nil
        }
        #expect(problem("") == .empty)
        #expect(problem("four") == .notANumber("four"))
        #expect(problem("1, 4") == .outOfRange(1, 12), "page 1 starts the first file anyway")
        #expect(problem("13") == .outOfRange(13, 12))
        #expect(problem("9, 4") == .notIncreasing)
        #expect(problem("4, 4") == .notIncreasing)
        let nineteen = (2...20).map(String.init).joined(separator: ",")
        #expect(problem(nineteen, 25) == nil, "20 parts is the most, and allowed")
        let twenty = (2...21).map(String.init).joined(separator: ",")
        #expect(problem(twenty, 25) == .tooMany)
        #expect(P.outOfRange(13, 12).sentence == "Page 13 is past the end: this PDF has 12 pages.")
    }

    // MARK: Combine's name

    /// The first file's name with "(combined)", and a typed name checked as the writer counts it.
    @Test func combinesUnderACheckedName() throws {
        #expect(EditorPDFCombineSplit.defaultName("/x/Receipt Hilton.pdf") == "Receipt Hilton (combined).pdf")
        #expect(try EditorPDFCombineSplit.fileName(" Trip ").get() == "Trip.pdf")
        #expect(try EditorPDFCombineSplit.fileName("Trip.PDF").get() == "Trip.PDF")
        #expect(EditorPDFCombineSplit.fileName("  ") == .failure(.empty))
        #expect(EditorPDFCombineSplit.fileName("a/b") == .failure(.separator))
        #expect(EditorPDFCombineSplit.fileName("a:b") == .failure(.separator))
        #expect(EditorPDFCombineSplit.fileName(".hidden") == .failure(.dot))
        #expect(EditorPDFCombineSplit.fileName(String(repeating: "é", count: 130)) == .failure(.tooLong),
                "counted as typed, 130 fits; decomposed, as the write sends it, it doesn't")
    }

    // MARK: Combine

    /// **The files in the order the sheet set, into one new file where the first one is** — the
    /// originals as they were, and the banner saying what it made.
    @Test func combinesInTheOrderSet() async throws {
        let a = path("A.pdf"), b = path("B.pdf"), c = path("C.pdf")
        PDFFixtures.write(a, pages: 1, size: CGSize(width: 300, height: 400))
        PDFFixtures.write(b, pages: 2, size: CGSize(width: 400, height: 400))
        PDFFixtures.write(c, pages: 1, size: CGSize(width: 500, height: 400))
        let before = try [a, b, c].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let model = PanePDFTools()
        var reread: [String] = []
        model.host = PanePDFToolHost(didWrite: { reread.append($0) })
        model.start(.combine, paths: [a, b, c], writer: "PDF Tools in Browse")
        guard case .combineSplit(let run)? = model.current else { Issue.record("no combine run"); return }
        #expect(run.showsSheet && model.isBusy, "the sheet isn't up, or the window doesn't count it busy")
        run.move(2, by: -1)
        #expect(run.order == [a, c, b])
        await run.run()

        let combined = path("A (combined).pdf")
        #expect(files() == ["A (combined).pdf", "A.pdf", "B.pdf", "C.pdf"])
        #expect(pages(combined) == 4)
        #expect([0, 1, 2, 3].map { width(combined, page: $0) } == [300, 500, 400, 400], "the order isn't the sheet's")
        #expect(run.banner?.message == "Saved “A (combined).pdf” — 4 pages from 3 PDFs")
        #expect(run.banner?.kind == .wrote(combined))
        #expect(reread == [combined])
        #expect(try [a, b, c].map { try Data(contentsOf: URL(fileURLWithPath: $0)) } == before, "an original changed")
        #expect(!model.isBusy)
    }

    /// **A name that's taken gets the next number**, and a typed name is used as typed.
    @Test func aTakenNameGetsTheNextNumber() async throws {
        let a = path("A.pdf"), b = path("B.pdf")
        PDFFixtures.write(a, pages: 1)
        PDFFixtures.write(b, pages: 1)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: path("Trip.pdf")))
        let run = EditorPDFCombineSplit(job: .combine([a, b]), writer: "PDF Tools in Browse")
        run.name = "Trip"
        await run.run()
        #expect(run.banner?.kind == .wrote(path("Trip 2.pdf")), "\(String(describing: run.banner))")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path("Trip.pdf"))) == Data("mine".utf8))
    }

    /// **A file locked to open stops the run with its name** — the merge can't open it — and
    /// nothing is written.
    @Test func aLockedFileStopsCombineByName() async throws {
        let a = path("A.pdf"), locked = path("Locked.pdf")
        PDFFixtures.write(a, pages: 1)
        PDFFixtures.writeLocked(locked, password: "pw")
        let run = EditorPDFCombineSplit(job: .combine([a, locked]), writer: "PDF Tools in Browse")
        await run.run()
        #expect(run.banner?.message == "“Locked.pdf” is locked with a password. Remove it first, then combine.")
        #expect(run.banner?.kind == .failure)
        #expect(files() == ["A.pdf", "Locked.pdf"])
    }

    /// The rows name their folders only when the files are in more than one — two "Receipt.pdf"
    /// in two places must never look alike.
    @Test func rowsShowTheirFoldersOnlyWhenTheyDiffer() {
        let same = EditorPDFCombineSplit(job: .combine([path("A.pdf"), path("B.pdf")]), writer: "")
        #expect(!same.rowsShowFolders)
        let apart = EditorPDFCombineSplit(job: .combine([path("Receipt.pdf"), path("Receipt.pdf", in: "Downloads")]),
                                          writer: "")
        #expect(apart.rowsShowFolders)
    }

    /// **While Combine runs it is in the capsule**, in the PDF tools' slot — not while its sheet is up.
    @Test func combineIsInTheCapsuleOnceItsSheetGoes() async throws {
        let a = path("A.pdf"), b = path("B.pdf")
        PDFFixtures.write(a, pages: 1)
        PDFFixtures.write(b, pages: 1)
        let run = EditorPDFCombineSplit(job: .combine([a, b]), writer: "PDF Tools in Browse")
        run.showsSheet = true
        #expect(RunCapsuleEntry.combineSplit(run) == nil, "a run still asking its question is in the capsule")
        var seen: String?
        run.host = PanePDFToolHost(didWrite: { [weak run] _ in
            guard let run, let entry = RunCapsuleEntry.combineSplit(run) else { return }
            seen = entry.snapshot().title
            #expect(entry.kind == .pdfTool)
        })
        await run.run()
        #expect(seen == "Combining 2 PDFs")
    }

    // MARK: Split

    /// **Split is Extract per part**: each part named and written as an extract of its pages is,
    /// next to the original — after the sheet, which the lane's read readies.
    @Test func splitsIntoExtractsNamedForTheirPages() async throws {
        let file = path("Statement.pdf")
        PDFFixtures.write(file, pages: 4)
        let before = try Data(contentsOf: URL(fileURLWithPath: file))
        let model = PanePDFTools()
        model.start(.split, paths: [file], writer: "PDF Tools in Browse")
        await model.work?.value
        guard case .combineSplit(let run)? = model.current else { Issue.record("no split run"); return }
        #expect(run.showsSheet && run.pageCount == 4)
        run.splitAt = "2, 3"
        await run.run()

        let parts = ["Statement (page 1).pdf", "Statement (page 2).pdf", "Statement (pages 3–4).pdf"]
        #expect(files() == ["Statement (page 1).pdf", "Statement (page 2).pdf", "Statement (pages 3–4).pdf", "Statement.pdf"])
        #expect(parts.map { pages(path($0)) } == [1, 1, 2])
        #expect(run.banner?.message == "Saved 3 files from “Statement.pdf”")
        #expect(run.banner?.kind == .wroteSeveral(parts.map { path($0) }))
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == before)
    }

    /// **Stop ends Split after the part in hand**; the parts written stay, and the banner says how many.
    @Test func stopKeepsThePartsWritten() async throws {
        let file = path("Long.pdf")
        PDFFixtures.write(file, pages: 3)
        let run = EditorPDFCombineSplit(job: .split(file), writer: "PDF Tools in Browse")
        run.prepare()
        await run.work?.value
        run.splitAt = "2, 3"
        run.host = PanePDFToolHost(didWrite: { [weak run] _ in run?.stop() })
        await run.run()
        #expect(files() == ["Long (page 1).pdf", "Long.pdf"])
        #expect(run.banner?.message == "Stopped. Saved 1 of 3 files from “Long.pdf”.")
    }

    /// What Split can't take is said in the banner, and no sheet opens: one page, a file locked to open.
    @Test func whatCantBeSplitIsSaidAndNoSheetOpens() async throws {
        let one = path("One.pdf"), locked = path("Locked.pdf")
        PDFFixtures.write(one, pages: 1)
        PDFFixtures.writeLocked(locked, password: "pw")
        for (file, said) in [(one, "“One.pdf” has one page, so there’s nothing to split."),
                             (locked, EditorPDFTools.lockedReason)] {
            let run = EditorPDFCombineSplit(job: .split(file), writer: "PDF Tools in Browse")
            run.prepare()
            await run.work?.value
            #expect(!run.showsSheet, "\(file): a sheet opened")
            #expect(run.banner?.message == said)
        }
    }

    /// **A file changed since the sheet read it is not split by its old page numbers.**
    @Test func aFileChangedSinceTheSheetIsNotSplit() async throws {
        let file = path("Moving.pdf")
        PDFFixtures.write(file, pages: 3)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                              ofItemAtPath: file)
        let run = EditorPDFCombineSplit(job: .split(file), writer: "PDF Tools in Browse")
        run.prepare()
        await run.work?.value
        run.splitAt = "2"
        PDFFixtures.write(file, pages: 5)
        await run.run()
        #expect(run.banner?.message == PanePDFTools.changedSinceAskedReason("Moving.pdf"), "\(String(describing: run.banner))")
        #expect(files() == ["Moving.pdf"])
    }

    /// A second request while Combine's sheet is up is refused in the running one's banner, and
    /// the sheet stays.
    @Test func aSecondRequestLeavesTheSheetUp() async throws {
        let a = path("A.pdf"), b = path("B.pdf")
        PDFFixtures.write(a, pages: 1)
        PDFFixtures.write(b, pages: 1)
        let model = PanePDFTools()
        model.start(.combine, paths: [a, b], writer: "PDF Tools in Browse")
        guard case .combineSplit(let run)? = model.current else { Issue.record("no combine run"); return }
        model.start(.compress, paths: [a], writer: "PDF Tools in Browse")
        guard case .combineSplit(let still)? = model.current else { Issue.record("the run went"); return }
        #expect(still === run)
        #expect(run.showsSheet)
        #expect(run.banner?.message == EditorPDFTools.busyMessage)
    }
}
