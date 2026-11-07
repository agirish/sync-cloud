import AppKit
import Sync
import Testing
@testable import FileExplorer

/// File ▸ Print… opens its rendered pages in the PDFKit lane, one press at a time. Serialized,
/// because a test here holds the lane (see `PDFPreviewMountedTests`).
@MainActor
@Suite(.serialized) struct DocumentPrintingTests {

    /// What `prepare` handed over, if it has.
    @MainActor
    private final class Delivery {
        private(set) var operations: [NSPrintOperation?] = []
        func record(_ operation: NSPrintOperation?) { operations.append(operation) }
    }

    private let job = DocumentPDF.Job(name: "note.md", text: "# Heading\n\nProse.\n", isMarkdown: true)

    /// The parse waits for the lane, and a second ⌘P while it waits starts nothing. After the
    /// sleep, a parse on the main actor or one that bypassed the lane would already have
    /// delivered. Release the lane and exactly one operation arrives, named for the job.
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
        // Waited for in lane turns, not seconds ("The wait that hangs instead of failing" in
        // `docs/flaky-tests.md`). The lane runs in order, so once one turn of ours returns the
        // parse has run, and only its hop back to the main actor is left. Under load a seconds
        // budget runs out with the parse still queued behind other suites.
        await PDFKitSerialAccess.perform {}
        for _ in 0..<1000 where first.operations.isEmpty {
            await PDFKitSerialAccess.perform {}
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(first.operations.count == 1, "the operation never arrived once the lane was free")
        let operation = try #require(first.operations.first ?? nil, "the render produced no operation")
        #expect(operation.jobTitle == "note.md")
        #expect(second.operations.isEmpty)
        #expect(!DocumentPrinting.isPreparing, "the guard stayed up after the operation was handed over")
    }
}
