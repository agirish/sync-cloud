import Testing
import Foundation
import os
import PDFKit
import Sync
@testable import FileExplorer

/// **What an Ask Claude PDF card says before the click** (TE294 step 3): a file's pages, size,
/// protection and fields, a tool's losses for that file only, a bounded wait on the PDF lane, and
/// the pages a card draws.
///
/// Serialized, because the reads take `PDFKitSerialAccess`'s one lane, and one test holds it.
extension PDFFixtures {
    /// One page whose catalog has an `/AcroForm` naming no fields — a form to the toolkit, with
    /// nothing in it to fill.
    static func writeEmptyAcroForm(_ path: String) throws {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ]
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
@Suite(.serialized) final class PDFCardFactsTests {
    let folder = NSTemporaryDirectory() + "pdf-card-facts-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    /// Long enough for any load: another suite in this process may hold the lane for seconds. The
    /// app's own 5 s bound is pinned on its own, by ``theAppWaitsFiveSecondsOnTheLane()``; that
    /// a held lane answers busy at all, by ``aHeldLaneAnswersBusyWhileItIsHeld()``.
    static let wait: Duration = .seconds(120)

    /// The bound the app's cards and thumbnails wait on, as decided: long enough for a turn under
    /// load, short enough not to hold Claude's turn behind a scan.
    @Test func theAppWaitsFiveSecondsOnTheLane() {
        #expect(PDFCardFactsReader.laneWait == .seconds(5))
    }

    private func facts(_ read: PDFCardRead) -> PDFCardFacts? {
        if case .facts(let facts) = read { return facts }
        return nil
    }

    /// **A plain PDF: its pages, size, stamp — and nothing lost by Rotate.**
    @Test func readsAPlainFile() async throws {
        let file = path("Plain.pdf")
        PDFFixtures.write(file, pages: 3)
        let read = try #require(facts(await PDFCardFactsReader.read(file, for: .rotate(pages: [0], quarterTurns: 1),
                                                                 timeout: Self.wait, isCloudOnly: { _ in false })))
        #expect(read.pageCount == 3)
        #expect(read.protection == .none)
        #expect(read.fieldCount == 0)
        #expect(read.losses.isEmpty, "\(read.losses)")
        #expect(read.stamp == EditorFileStore.stamp(ofPath: file))
        #expect(read.bytes == EditorFileStore.stamp(ofPath: file)?.size)
        #expect(read.folderIsWritable)
    }

    /// **Compress always says its pages become pictures** — every file has text to lose — and a
    /// form's loss is said only for a file with one, in the tool's own kind of loss.
    @Test func saysEachToolsLossesForThisFileOnly() async throws {
        let plain = path("Plain.pdf"), form = path("Form.pdf")
        PDFFixtures.write(plain, pages: 2)
        try PDFFixtures.writeAcroForm(form)
        let compressPlain = try #require(facts(await PDFCardFactsReader.read(plain, for: .compress(.quality(0.6)),
                                                                          timeout: Self.wait, isCloudOnly: { _ in false })))
        #expect(compressPlain.losses.first == PDFCardFactsReader.compressRedraw)
        #expect(!compressPlain.losses.contains(PDFCardFactsReader.formFlattened))

        let compressForm = try #require(facts(await PDFCardFactsReader.read(form, for: .compress(.quality(0.6)),
                                                                         timeout: Self.wait, isCloudOnly: { _ in false })))
        #expect(compressForm.fieldCount > 0)
        #expect(compressForm.losses.contains(PDFCardFactsReader.formFlattened), "\(compressForm.losses)")

        let extractForm = try #require(facts(await PDFCardFactsReader.read(form, for: .extract([0]),
                                                                        timeout: Self.wait, isCloudOnly: { _ in false })))
        #expect(extractForm.losses.contains(PDFCardFactsReader.formStopsWorking), "\(extractForm.losses)")

        let rotateForm = try #require(facts(await PDFCardFactsReader.read(form, for: .rotate(pages: [0], quarterTurns: 1),
                                                                       timeout: Self.wait, isCloudOnly: { _ in false })))
        #expect(!rotateForm.losses.contains { $0 == PDFCardFactsReader.formFlattened || $0 == PDFCardFactsReader.formStopsWorking },
                "Rotate keeps a form: \(rotateForm.losses)")
    }

    /// **A form with no named fields is a form, as the run asks it** — a catalog `/AcroForm` with
    /// an empty `/Fields`, as some generators write. The card said no loss while the run found
    /// one, so the click was declined as "changed since the card said", every time.
    @Test func aFormWithNoFieldsLosesWhatTheRunSays() async throws {
        let file = path("Empty form.pdf")
        try PDFFixtures.writeEmptyAcroForm(file)
        let url = URL(fileURLWithPath: file)
        for tool: EditorPDFTool in [.extract([0]), .reorder([0]), .compress(.quality(0.6)), .removePassword(EditorPDFSecret(""))] {
            let read = try #require(facts(await PDFCardFactsReader.read(file, for: tool, timeout: Self.wait,
                                                                     isCloudOnly: { _ in false })))
            #expect(read.fieldCount == 0, "the fixture has a named field, so this proves nothing")
            let runAsks = await EditorPDFToolEngine.fidelityWarning(for: tool, input: url) != nil
            try #require(runAsks, "the run finds no form either, so this proves nothing")
            let said = read.losses.contains { $0 == PDFCardFactsReader.formFlattened || $0 == PDFCardFactsReader.formStopsWorking }
            #expect(said, "\(tool.logDetail): the card said \(read.losses), the run will ask about the form")
        }
        // Clean Metadata cleans such a file in place, as the toolkit decides it: by the form, not its fields.
        let lane = try #require(await PDFKitSerialAccess.perform { PDFCardFactsReader.laneRead(url, tool: .cleanMetadataCleared) })
        #expect(lane.hasForm)
    }

    /// **Protection, as the card needs it**: restricted opens and counts its pages, and a copy that
    /// rebuilds it says the restrictions go; locked has no pages to count.
    @Test func readsProtection() async throws {
        let restricted = path("Restricted.pdf"), locked = path("Locked.pdf")
        PDFFixtures.writeRestricted(restricted)
        PDFFixtures.writeLocked(locked, password: "pw")
        let open = try #require(facts(await PDFCardFactsReader.read(restricted, for: .extract([0]),
                                                                 timeout: Self.wait, isCloudOnly: { _ in false })))
        #expect(open.protection == .restricted)
        #expect(open.pageCount == 3)
        #expect(open.losses.contains(PDFCardFactsReader.restrictionsGo), "\(open.losses)")
        let shut = try #require(facts(await PDFCardFactsReader.read(locked, for: .removePassword(EditorPDFSecret("pw")),
                                                                 timeout: Self.wait, isCloudOnly: { _ in false })))
        #expect(shut.protection == .locked)
        #expect(shut.pageCount == 0)
    }

    /// Nothing reads a file only in the cloud; a file that's gone, or isn't a PDF, says so.
    @Test func saysWhyItCantRead() async throws {
        let file = path("Cloud.pdf"), junk = path("Junk.pdf")
        PDFFixtures.write(file, pages: 1)
        try Data("not a pdf".utf8).write(to: URL(fileURLWithPath: junk))
        #expect(await PDFCardFactsReader.read(file, for: .compress(.quality(0.6)), timeout: Self.wait, isCloudOnly: { _ in true }) == .cloudOnly)
        #expect(await PDFCardFactsReader.read(path("Gone.pdf"), for: .compress(.quality(0.6)), timeout: Self.wait, isCloudOnly: { _ in false }) == .gone)
        #expect(await PDFCardFactsReader.read(junk, for: .compress(.quality(0.6)), timeout: Self.wait, isCloudOnly: { _ in false }) == .unreadable)
    }

    /// **A lane held by other work answers "busy" while it is still held, not after.** Said
    /// without a clock: on a loaded
    /// 3-core runner even the 200 ms timer can take seconds to fire, so the claim is that the
    /// answer came back before the lane was let go, which a read that waited for it can't do.
    @Test func aHeldLaneAnswersBusyWhileItIsHeld() async throws {
        let file = path("Held.pdf")
        PDFFixtures.write(file, pages: 1)
        let release = DispatchSemaphore(value: 0)
        let held = OSAllocatedUnfairLock(initialState: false), freed = OSAllocatedUnfairLock(initialState: false)
        let holder = Task.detached {
            await PDFKitSerialAccess.perform {
                held.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 120)
                freed.withLock { $0 = true }
            }
        }
        // The holder's turn first: a read queued ahead of it would never meet a held lane.
        let deadline = Date().addingTimeInterval(60)
        while !held.withLock({ $0 }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(held.withLock { $0 }, "the holder never got the lane")
        let read = await PDFCardFactsReader.read(file, for: .compress(.quality(0.6)), timeout: .milliseconds(200),
                                                 isCloudOnly: { _ in false })
        let freedFirst = freed.withLock { $0 }
        release.signal()
        await holder.value
        #expect(read == .busy)
        #expect(!freedFirst, "the read came back only once the lane was let go")
    }

    // MARK: Thumbnails

    /// **The pages a card draws: each one acted on, one either side, and a gap for the rest.**
    @Test func showsEachPageWithOneEitherSide() {
        #expect(PDFCardThumbnails.shown([5], pageCount: 300) == [4, 5, 6])
        #expect(PDFCardThumbnails.shown([0, 299], pageCount: 300) == [0, 1, nil, 298, 299])
        #expect(PDFCardThumbnails.shown([3, 4], pageCount: 10) == [2, 3, 4, 5])
        #expect(PDFCardThumbnails.shown([2, 6], pageCount: 10) == [1, 2, 3, nil, 5, 6, 7])
        #expect(PDFCardThumbnails.shown([10], pageCount: 10) == [], "a page past the end draws nothing")
    }

    /// The pages asked for come back drawn at the height asked, as `CGImage`s.
    @Test func drawsThePagesAskedFor() async throws {
        let file = path("Drawn.pdf")
        PDFFixtures.write(file, pages: 3)
        let images = try #require(await PDFCardThumbnails.render(file, pages: [0, 2], height: 40, timeout: Self.wait))
        #expect(Set(images.keys) == [0, 2])
        // Points, drawn at the screen's scale: 40 tall, or 80 on a Retina backing.
        #expect(images[0].map { [40, 80].contains($0.height) } == true, "\(images[0].map(\.height) ?? -1) px tall")
    }

    /// **A page turned a quarter is drawn on its side**, not squeezed into the unturned box.
    @Test func drawsATurnedPageTurned() async throws {
        let file = path("Turned.pdf")
        PDFFixtures.write(file, pages: 1)
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        document.page(at: 0)?.rotation = 90
        try #require(document.write(to: URL(fileURLWithPath: file)))
        let images = try #require(await PDFCardThumbnails.render(file, pages: [0], height: 40, timeout: Self.wait))
        let image = try #require(images[0])
        #expect(image.width > image.height, "a turned letter page drew \(image.width) × \(image.height)")
    }

    /// Nothing reads a file only in the cloud for its pictures either.
    @Test func drawsNothingForAFileOnlyInTheCloud() async {
        let file = path("Cloud.pdf")
        PDFFixtures.write(file, pages: 1)
        #expect(await PDFCardThumbnails.render(file, pages: [0], height: 40, isCloudOnly: { _ in true }) == nil)
    }

    // MARK: Planned names

    /// **The name a card shows is the name the menus give** — before the keep-both rule's number.
    @Test func plansTheMenusNames() {
        #expect(PDFPlannedName.copy(of: "/d/Scan.pdf", tool: .compress(.quality(0.6))) == "Scan (compressed).pdf")
        #expect(PDFPlannedName.copy(of: "/d/Statement.pdf", tool: .extract([2, 3, 4])) == "Statement (pages 3–5).pdf")
        #expect(PDFPlannedName.copy(of: "/d/Statement.pdf", tool: .deletePages([0])) == "Statement (page removed).pdf")
        #expect(PDFPlannedName.copy(of: "/d/Lease (signed).pdf", tool: .compress(.quality(0.6))) == "Lease (signed) (compressed).pdf")
        #expect(PDFPlannedName.saveAsPDF("/d/Lease 2026.docx") == "Lease 2026.pdf")
        #expect(PDFPlannedName.splitParts(of: "/d/S.pdf", at: [2, 4], pageCount: 5)
                == ["S (page 1).pdf", "S (pages 2–3).pdf", "S (pages 4–5).pdf"])
        #expect(PDFPlannedName.splitParts(of: "/d/S.pdf", at: [9], pageCount: 5).isEmpty, "a start past the end plans nothing")
    }

    // MARK: Pages typed

    /// **Pages typed on a card read as Edit's sheet reads them** — an en dash, the order kept for
    /// Extract, and every page refused for Delete.
    @Test func readsTypedPagesAsEditDoes() throws {
        #expect(try PDFCardPages.parse("3–5, 1", extract: true, pageCount: 8).get() == [2, 3, 4, 0])
        #expect(PDFCardPages.label([2, 3, 4, 0]) == "3–5, 1")
        if case .failure(let problem) = PDFCardPages.parse("1-3", extract: false, pageCount: 3) {
            #expect(!problem.sentence.isEmpty)
        } else {
            Issue.record("deleting every page was allowed")
        }
        if case .failure(let problem) = PDFCardPages.parse("9", extract: true, pageCount: 3) {
            #expect(problem.sentence.contains("no page 9"), "\(problem.sentence)")
        } else {
            Issue.record("a page past the end was allowed")
        }
    }
}
