import AppKit
import Testing
@testable import FileExplorer

/// File ▸ Print… opens its rendered pages in the PDFKit lane, and one press at a time.
///
/// **Serialized, because a test here holds the lane** — see `PDFPreviewMountedTests`.
@MainActor
@Suite(.serialized) struct DocumentPrintingTests {

    /// What `prepare` handed over, if it has.
    @MainActor
    private final class Delivery {
        private(set) var operations: [NSPrintOperation?] = []
        func record(_ operation: NSPrintOperation?) { operations.append(operation) }
    }

    private let job = DocumentPDF.Job(name: "note.md", text: "# Heading\n\nProse.\n", isMarkdown: true)

    /// **The parse waits for the lane, and a second ⌘P while it waits starts nothing.** The render
    /// and the hop into the lane are one main-actor turn, so after the sleep below the first press
    /// has either queued its parse behind the hold or, parsing on the main actor, already
    /// delivered — and the sleep also gives a parse that went off the main actor but AROUND the
    /// lane time to land. Release the lane and exactly one operation arrives, named for the job.
    @Test func thePrintIsParsedInTheLaneAndPreparedOnce() async throws {
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        let first = Delivery(), second = Delivery()
        #expect(DocumentPrinting.prepare(job, then: first.record))
        #expect(DocumentPrinting.isPreparing)
        #expect(!DocumentPrinting.prepare(job, then: second.record),
                "a second ⌘P started a second print while the first was waiting for the lane")

        try await Task.sleep(for: .milliseconds(300))
        #expect(first.operations.isEmpty,
                "the operation was built while the lane was held — the PDF was parsed outside it")

        hold.release()
        let deadline = Date().addingTimeInterval(10)
        while first.operations.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.operations.count == 1, "the operation never arrived once the lane was free")
        let operation = try #require(first.operations.first ?? nil, "the render produced no operation")
        #expect(operation.jobTitle == "note.md")
        #expect(second.operations.isEmpty)
        #expect(!DocumentPrinting.isPreparing, "the guard stayed up after the operation was handed over")
    }
}
