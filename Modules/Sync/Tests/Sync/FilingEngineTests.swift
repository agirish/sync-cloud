import Foundation
import Testing
@testable import Sync

@Suite struct FilingEngineTests {

    // Mid-2024 so the year is 2024 in every timezone.
    private let y2024 = Date(timeIntervalSince1970: 1_720_000_000)

    private func file(_ path: String, size: Int = 8192, modified: Date? = nil) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                 modificationDate: modified, fileSize: size)
    }
    private func dir(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
    }

    // MARK: Flagship — Tesla insurance into an existing Vehicles folder

    @Test func teslaInsuranceProposesNewSubPathUnderVehicles() throws {
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Vehicles", [])])]
        let loose = [file("/root/Downloads/Tesla — Auto Policy 2024.pdf", modified: y2024)]

        let suggestions = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        #expect(suggestions.count == 1)
        let best = try #require(suggestions[0].best)
        #expect(best.path == "/root/Documents/Vehicles/Tesla/Insurance")
        #expect(best.newSegments == ["Tesla", "Insurance"])   // created only on apply
        #expect(best.isNew)
        #expect(best.confidence == .medium)
    }

    // MARK: Taxonomy match into an existing folder wins (high confidence, no new folders)

    @Test func matchesAnExistingFolderByName() throws {
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Vehicles",
                          [dir("/root/Documents/Vehicles/Tesla", [])])])]
        let loose = [file("/root/Downloads/tesla registration card.pdf", modified: y2024)]

        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Vehicles/Tesla")
        #expect(best.newSegments.isEmpty)
        #expect(best.confidence == .high)
    }

    // MARK: Universal rules

    @Test func photoIsFiledByYearUnderExistingPhotos() throws {
        let taxonomy = [dir("/root/Photos", [])]
        let loose = [file("/root/Downloads/IMG_2831.HEIC", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Photos/2024")
        #expect(best.newSegments == ["2024"])
        #expect(best.confidence == .high)
    }

    @Test func photoWithoutAPhotosFolderProposesOneAtRoot() throws {
        let loose = [file("/root/Downloads/IMG_9.HEIC", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: [], providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Photos/2024")
        #expect(best.newSegments == ["Photos", "2024"])   // both proposed
        #expect(best.confidence == .medium)
    }

    @Test func receiptIsFiledByYearUnderExistingReceipts() throws {
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Receipts", [])])]
        let loose = [file("/root/Downloads/amazon order 114.pdf", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Receipts/2024")
        #expect(best.confidence == .high)
    }

    @Test func taxDocProposesTaxesUnderFinanceWhenNoTaxesFolder() throws {
        let taxonomy = [dir("/root/Finance", [])]
        let loose = [file("/root/Downloads/1099-INT 2024.pdf", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Finance/Taxes/2024")
        #expect(best.newSegments == ["Taxes", "2024"])
    }

    // MARK: Content signals (F2)

    @Test func contentTokensUpgradeAFileWhoseNameSaysNothing() throws {
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Vehicles", [])])]
        let loose = [file("/root/Downloads/scan0012.pdf", modified: y2024)]

        // Filename alone → no confident home.
        let byName = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        #expect(byName[0].candidates.isEmpty)

        // Content extraction found the entities; now it lands the same place F1 does by name.
        let content = ["/root/Downloads/scan0012.pdf": Set(["tesla", "policy", "geico"])]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                     providerRoot: "/root", contentTokens: content).first?.best)
        #expect(best.path == "/root/Documents/Vehicles/Tesla/Insurance")
        #expect(best.reasons.first?.contains("read from the file") == true)
    }

    @Test func contentTokensImproveAnExistingFolderMatch() throws {
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Invoices", [])])]
        let loose = [file("/root/Downloads/scan.pdf", modified: y2024)]
        let content = ["/root/Downloads/scan.pdf": Set(["invoices", "acme"])]

        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                     providerRoot: "/root", contentTokens: content).first?.best)
        #expect(best.path == "/root/Documents/Invoices")
        #expect(best.confidence == .medium)   // content-derived matches are capped to medium
        #expect(best.reasons.first?.contains("read from the file") == true)
    }

    @Test func contentDerivedMatchIsMediumAndNotBatchEligible() throws {
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Invoices", [])])]
        let loose = [file("/root/Downloads/scan.pdf", modified: y2024)]
        let content = ["/root/Downloads/scan.pdf": Set(["invoices"])]
        let s = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                  providerRoot: "/root", contentTokens: content).first)
        #expect(s.best?.confidence == .medium)
        #expect(s.hasConfidentHome)            // still offers a per-file "File here"
        #expect(s.isBatchEligible == false)    // but never auto-filed by the batch
        #expect(s.best?.fromContent == true)
    }

    @Test func reasonIsNotContentWhenTokenIsAlsoInTheName() throws {
        let taxonomy = [dir("/root/Insurance", [])]
        let loose = [file("/root/Downloads/insurance.pdf", modified: y2024)]
        let content = ["/root/Downloads/insurance.pdf": Set(["insurance"])]   // also in the name
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                     providerRoot: "/root", contentTokens: content).first?.best)
        #expect(best.confidence == .high)                                     // name-derived → not capped
        #expect(best.reasons.first?.contains("read from the file") == false)
    }

    @Test func rankPrefersTheShallowerNamesakeFolder() throws {
        // A generic doc should land in top-level /Insurance, not a nested /Health/Insurance namesake.
        let taxonomy = [dir("/root/Insurance", []),
                        dir("/root/Health", [dir("/root/Health/Insurance", [])])]
        let loose = [file("/root/Downloads/insurance renewal.pdf", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Insurance")
    }

    @Test func returnIsNoLongerATaxSignal() {
        let taxonomy = [dir("/root/Taxes", [])]
        let loose = [file("/root/Downloads/product return form.pdf", modified: y2024)]
        let s = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        #expect(!(s.first?.candidates.contains { $0.path.contains("Taxes") } ?? false))
    }

    // MARK: No confident home

    @Test func unrecognizedFileGetsNoConfidentHome() {
        let taxonomy = [dir("/root/Documents", [])]
        let loose = [file("/root/Downloads/zxqw.bin", modified: y2024)]
        let s = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        #expect(s.count == 1)
        #expect(s[0].candidates.isEmpty)
        #expect(s[0].hasConfidentHome == false)
    }

    @Test func directoriesAndIgnoredFilesAreSkipped() {
        let loose = [dir("/root/Downloads/SomeFolder", []),
                     file("/root/Downloads/.DS_Store", modified: y2024)]
        let s = FilingEngine.suggest(looseFiles: loose, taxonomy: [], providerRoot: "/root")
        #expect(s.isEmpty)
    }

    // MARK: Tokenization

    @Test func tokenizationSplitsAndFiltersSensibly() {
        #expect(FilingEngine.fileTokens("Q3 Report-Final.docx") == ["q3", "report"])   // "final" is a stopword
        #expect(FilingEngine.fileTokens("Tesla — Auto Policy 2024.pdf") == ["tesla", "auto", "policy", "2024"])
        #expect(FilingEngine.nameTokens("bankStatement") == ["bank", "statement"])     // camelCase split
        #expect(!FilingEngine.fileTokens("order 114").contains("114"))                 // non-year number dropped
        #expect(FilingEngine.fileTokens("photos from 2001").contains("2001"))          // year kept
    }
}
