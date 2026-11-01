import Testing
@testable import Design

/// Read Documents' sheet for a source (mockup 52b6b1ed): the count, what downloads (GO: and stays),
/// what cannot be read, and the cost — with his two Google Drives' real counts of 2026-10-31.
@Suite struct SourceDocumentsTextTests {

    @Test func nothingCloudOnlySaysNothingDownloads() {
        let personal = SourceDocumentsFacts(sourceName: "Google Drive", documents: 12_825, toDownload: 0,
                                            unreadableTypes: 1_498)
        #expect(SourceDocumentsText.title(personal) == "Read Google Drive’s documents?")
        #expect(SourceDocumentsText.lead(personal) == "To File reads page 1 of 12,825 documents to learn what each folder holds.")
        let points = SourceDocumentsText.points(personal)
        #expect(points.first == "Every one is on this Mac already, so nothing downloads.")
        #expect(points.contains("1,498 Word, Excel and PowerPoint files can’t be read."))
        #expect(points.last?.hasPrefix("About 6 h, in the background.") == true, "\(points.last ?? "")")
    }

    @Test func cloudOnlyDocumentsDownloadFirstAndStay() {
        let hpe = SourceDocumentsFacts(sourceName: "Google Drive", documents: 1_768, toDownload: 1_410,
                                       unreadableTypes: 1_089)
        let points = SourceDocumentsText.points(hpe)
        #expect(points.first == "1,410 are in the cloud only. They download first and stay on this Mac.")
        #expect(points.last?.hasPrefix("About 50 min plus downloads, in the background.") == true, "\(points.last ?? "")")
        let one = SourceDocumentsFacts(sourceName: "Box", documents: 3, toDownload: 1, unreadableTypes: 0)
        #expect(SourceDocumentsText.points(one).first == "1 is in the cloud only. It downloads first and stays on this Mac.")
        #expect(SourceDocumentsText.points(one).count == 2, "no unreadable line when there are none")
    }

    /// Carrying on a stopped reading prices only what is left.
    @Test func aStoppedReadingIsPricedForWhatIsLeft() {
        let resumed = SourceDocumentsFacts(sourceName: "Dropbox", documents: 6_140, toDownload: 0,
                                           unreadableTypes: 0, alreadyRead: 6_000)
        let points = SourceDocumentsText.points(resumed)
        #expect(SourceDocumentsText.title(resumed) == "Read Dropbox’s documents?")
        #expect(points.contains("6,000 were read before it stopped. Carrying on reads only the rest."))
        #expect(points.last?.hasPrefix("A few minutes, in the background.") == true)
    }
}
