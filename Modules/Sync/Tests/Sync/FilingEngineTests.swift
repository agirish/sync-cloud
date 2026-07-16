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

    // MARK: A bare year must not stand up a batch-eligible taxonomy home

    @Test func bareYearMatchIsNotBatchEligible() throws {
        // Two same-year folders and a file whose only taxonomy overlap is the year. Filing on the
        // year alone would blindly move it into whichever folder sorts first (Archive < Projects) —
        // so it must NOT be a confident, batch-eligible home.
        let taxonomy = [dir("/root/Archive", [dir("/root/Archive/2024", [])]),
                        dir("/root/Projects", [dir("/root/Projects/2024", [])])]
        let loose = [file("/root/Downloads/2024-overview.pdf", modified: y2024)]

        let suggestion = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first)
        #expect(!suggestion.isBatchEligible)
        #expect(!suggestion.candidates.contains { $0.path.hasSuffix("/2024") })
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

    @Test func cameraSequenceYearIsAShotCounterNotAFilingYear() throws {
        // IMG_2023.jpg is shot #2023 off a camera, not a 2023 photo — reading its digits as the
        // filename year filed whole camera rolls into Photos/2023 at high confidence AND batch
        // eligible (mtime 2024 here). Same for DSC_1995 ("dsc" is not a stopword, so the token
        // guard alone can't catch it). A real year in a real name ("Wedding 2023") still wins.
        let taxonomy = [dir("/root/Photos", [])]
        let loose = [
            file("/root/Downloads/IMG_2023.jpg", modified: y2024),
            file("/root/Downloads/DSC_1995.jpg", modified: y2024),
            file("/root/Downloads/Wedding 2023.jpg", modified: y2024),
        ]
        let suggestions = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        #expect(suggestions[0].best?.path == "/root/Photos/2024")   // IMG_2023 → mtime year
        #expect(suggestions[1].best?.path == "/root/Photos/2024")   // DSC_1995 → mtime year
        #expect(suggestions[2].best?.path == "/root/Photos/2023")   // Wedding 2023 → filename year
    }

    @Test func cameraSequenceStemDetectionMatchesDeviceNamesOnly() {
        #expect(FilingEngine.isCameraSequenceStem("IMG_2023"))
        #expect(FilingEngine.isCameraSequenceStem("img 2023"))
        #expect(FilingEngine.isCameraSequenceStem("DSC-1995"))
        #expect(FilingEngine.isCameraSequenceStem("DSCN0042"))
        #expect(FilingEngine.isCameraSequenceStem("DSCF123456"))
        #expect(FilingEngine.isCameraSequenceStem("DCIM0424"))
        #expect(FilingEngine.isCameraSequenceStem("PXL_0421"))
        #expect(FilingEngine.isCameraSequenceStem("MVIMG_2020"))
        #expect(FilingEngine.isCameraSequenceStem("GOPR0042"))
        #expect(!FilingEngine.isCameraSequenceStem("Wedding 2023"))
        #expect(!FilingEngine.isCameraSequenceStem("2023"))            // bare year, no device prefix
        #expect(!FilingEngine.isCameraSequenceStem("IMG_12"))          // counter too short
        #expect(!FilingEngine.isCameraSequenceStem("IMG_1234567"))     // counter too long
        #expect(!FilingEngine.isCameraSequenceStem("IMG_2023 edit"))   // trailing words = a real name
        #expect(!FilingEngine.isCameraSequenceStem("screenshot 2023"))
    }

    @Test func cameraSequenceTokensDropTheYearShapedCounter() {
        // The guard lives in fileTokens (the one shared entry point), so the heuristic year,
        // the automations' {year} template, and mentionsAll matching all agree.
        #expect(!FilingEngine.fileTokens("IMG_2023.jpg").contains("2023"))
        #expect(!FilingEngine.fileTokens("DSC_1995.jpg").contains("1995"))
        #expect(FilingEngine.fileTokens("Wedding 2023.jpg").contains("2023"))
        #expect(FilingEngine.filenameYear(in: FilingEngine.fileTokens("IMG_2023.jpg"),
                                          now: Date(timeIntervalSince1970: 1_720_000_000)) == nil)
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

    // MARK: Filename year beats modification date for the year segment

    @Test func filenameYearWinsOverMtimeForTheYearSegment() throws {
        // A 2022 receipt downloaded (mtime) in 2024 belongs in Receipts/2022 — the filename names
        // the document's year; the mtime only says when the bytes last changed.
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Receipts", [])])]
        let loose = [file("/root/Downloads/amazon invoice 2022.pdf", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Receipts/2022")
    }

    @Test func taxFormFilenameYearWinsOverMtime() throws {
        let taxonomy = [dir("/root/Taxes", [])]
        let loose = [file("/root/Downloads/1099-INT 2023.pdf", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Taxes/2023")
    }

    @Test func multipleFilenameYearsFallBackToMtime() throws {
        // A range names no single year — the mtime year stands.
        let taxonomy = [dir("/root/Statements", [])]
        let loose = [file("/root/Downloads/statement 2021-2022.pdf", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Statements/2024")
    }

    @Test func implausibleFilenameYearFallsBackToMtime() throws {
        // "2098" passes the tokenizer's year net (1900–2099) but is not a plausible filing year.
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Receipts", [])])]
        let loose = [file("/root/Downloads/receipt 2098.pdf", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Receipts/2024")
    }

    @Test func filenameYearHelperRequiresExactlyOnePlausibleYear() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)   // mid-2024
        #expect(FilingEngine.filenameYear(in: ["tax", "2023"], now: now) == "2023")
        #expect(FilingEngine.filenameYear(in: ["report", "2025"], now: now) == "2025")   // current+1 ok
        #expect(FilingEngine.filenameYear(in: ["report", "2026"], now: now) == nil)      // beyond current+1
        #expect(FilingEngine.filenameYear(in: ["scan", "1989"], now: now) == nil)        // before 1990
        #expect(FilingEngine.filenameYear(in: ["fy", "2021", "2022"], now: now) == nil)  // ambiguous range
        #expect(FilingEngine.filenameYear(in: ["notes"], now: now) == nil)               // no year at all
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
        #expect(best.evidenceToken == "Invoices")   // G4: the read-from-content word is surfaced for highlighting
        #expect(best.neighborMatches == 0)          // the target has no files, so no neighbor corroboration
    }

    // MARK: Content evidence (G4)

    @Test func contentMatchSurfacesEvidenceTokenAndSimilarNeighbors() throws {
        // The target already holds three invoices; a content-detected invoice should name the
        // evidence word AND how many similar files already live there.
        let invoiceFolder = dir("/root/Documents/Invoice", [
            file("/root/Documents/Invoice/Invoice-Jan.pdf"),
            file("/root/Documents/Invoice/Invoice-Feb.pdf"),
            file("/root/Documents/Invoice/Invoice-Mar.pdf"),
        ])
        let taxonomy = [dir("/root/Documents", [invoiceFolder])]
        let loose = [file("/root/Downloads/scan0003.pdf", modified: y2024)]   // name says nothing
        let content = ["/root/Downloads/scan0003.pdf": Set(["invoice"])]      // read from the file

        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                     providerRoot: "/root", contentTokens: content).first?.best)
        #expect(best.path == "/root/Documents/Invoice")
        #expect(best.fromContent == true)
        #expect(best.evidenceToken == "Invoice")            // display-ready highlight token
        #expect(best.neighborMatches == 3)                  // three similar files already in the target
        #expect(best.reasons.first?.contains("3 similar files") == true)
        #expect(best.reasons.first?.contains("read from the file") == true)
    }

    @Test func nameMatchHasNoEvidenceToken() throws {
        // A plain filename match must NOT carry an evidence token — that decoration is reserved for
        // the stronger, less-obvious content signal.
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Vehicles",
                          [dir("/root/Documents/Vehicles/Tesla", [])])])]
        let loose = [file("/root/Downloads/tesla registration card.pdf", modified: y2024)]
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.fromContent == false)
        #expect(best.evidenceToken == nil)
        #expect(best.neighborMatches == 0)
    }

    // MARK: Provider-relative breadcrumb (G10)

    @Test func suggestionCarriesProviderRootForRelativeDisplay() throws {
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Vehicles", [])])]
        let loose = [file("/root/Downloads/Tesla Policy 2024.pdf", modified: y2024)]
        let s = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root").first)
        #expect(s.providerRoot == "/root")   // the UI strips this to render "Root › …" instead of the home prefix
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

    // MARK: Remembered rules (F3)

    @Test func rememberedRuleFilesAMatchingFileTheHeuristicsWouldMiss() throws {
        // No Vehicles folder, so the heuristics give this no confident home…
        let taxonomy = [dir("/root/Documents", [])]
        let loose = [file("/root/Downloads/Tesla renewal.pdf", modified: y2024)]
        #expect(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")[0].candidates.isEmpty)

        // …but a remembered rule keyed on "tesla" files it, high-confidence and batch-eligible.
        let rule = FilingRule(tokens: ["tesla"], destinationPath: "/root/Documents/Vehicles/Tesla")
        let s = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                  providerRoot: "/root", rules: [rule]).first)
        #expect(s.best?.path == "/root/Documents/Vehicles/Tesla")
        #expect(s.best?.confidence == .high)
        #expect(s.best?.remembered == true)
        #expect(s.isBatchEligible)
        #expect(s.best?.reasons.first?.contains("Remembered") == true)
    }

    @Test func rememberedRuleOutranksAHeuristicMatchOfEqualConfidence() throws {
        // Heuristic would send "tesla registration" into the existing Tesla folder (high). A rule
        // that says these go somewhere else must win.
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Vehicles",
                          [dir("/root/Documents/Vehicles/Tesla", [])])])]
        let loose = [file("/root/Downloads/tesla registration.pdf", modified: y2024)]
        let rule = FilingRule(tokens: ["tesla"], destinationPath: "/root/Archive/Cars")
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                     providerRoot: "/root", rules: [rule]).first?.best)
        #expect(best.path == "/root/Archive/Cars")
        #expect(best.remembered)
    }

    @Test func ruleMatchesOnlyWhenAllTriggerTokensPresent() {
        let taxonomy = [dir("/root/Documents", [])]
        let rule = FilingRule(tokens: ["geico", "policy"], destinationPath: "/root/Insurance/Geico")
        // Has "geico" but not "policy" → no match.
        let miss = FilingEngine.suggest(looseFiles: [file("/root/Downloads/geico letter.pdf", modified: y2024)],
                                        taxonomy: taxonomy, providerRoot: "/root", rules: [rule])
        #expect(!(miss.first?.candidates.contains { $0.remembered } ?? false))
        // Has both (plus extras) → matches.
        let hit = FilingEngine.suggest(looseFiles: [file("/root/Downloads/geico policy renewal.pdf", modified: y2024)],
                                       taxonomy: taxonomy, providerRoot: "/root", rules: [rule])
        #expect(hit.first?.best?.path == "/root/Insurance/Geico")
    }

    @Test func rememberedRuleRecreatesAMissingFolder() throws {
        let taxonomy = [dir("/root/Documents", [])]   // the remembered folder no longer exists
        let loose = [file("/root/Downloads/tesla.pdf", modified: y2024)]
        let rule = FilingRule(tokens: ["tesla"], destinationPath: "/root/Documents/Vehicles/Tesla")
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                     providerRoot: "/root", rules: [rule]).first?.best)
        #expect(best.newSegments == ["Vehicles", "Tesla"])   // Documents exists; the tail is recreated on apply
        #expect(best.isNew)
    }

    @Test func rememberedRuleMissingTailIsRelativeToARealMultiSegmentRoot() throws {
        // A realistic root ("/Users/x/Dropbox") whose own ancestors are never in the walked
        // taxonomy: only the tail past the deepest existing folder is NEW, not the whole path.
        let root = "/Users/x/Dropbox"
        let taxonomy = [dir("\(root)/Documents", [])]
        let loose = [file("\(root)/Downloads/tesla.pdf", modified: y2024)]
        let rule = FilingRule(tokens: ["tesla"], destinationPath: "\(root)/Documents/Vehicles/Tesla")
        let best = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                     providerRoot: root, rules: [rule]).first?.best)
        #expect(best.newSegments == ["Vehicles", "Tesla"])
    }

    @Test func contentOnlyRuleMatchIsCappedToMedium() throws {
        let taxonomy = [dir("/root/Documents", [])]
        let loose = [file("/root/Downloads/scan0007.pdf", modified: y2024)]   // name says nothing
        let rule = FilingRule(tokens: ["tesla"], destinationPath: "/root/Vehicles/Tesla")
        let content = ["/root/Downloads/scan0007.pdf": Set(["tesla"])]        // only content carries "tesla"
        let s = try #require(FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                                  providerRoot: "/root", contentTokens: content, rules: [rule]).first)
        #expect(s.best?.remembered == true)
        #expect(s.best?.confidence == .medium)       // content-only → capped
        #expect(s.isBatchEligible == false)          // …and kept out of the blind batch
    }

    // MARK: Rule construction

    @Test func ruleBuilderPicksTheDistinctiveAnchor() throws {
        // Tesla insurance filed into …/Vehicles/Tesla/Insurance → the rule keys on the single token
        // the filename shares with the destination folders ("tesla"), so it generalizes to the next
        // Tesla document without keying on incidental words ("auto", "policy") or the year.
        let rule = try #require(FilingEngine.rule(forFileNamed: "Tesla — Auto Policy 2024.pdf",
                                                  filedInto: "/root/Documents/Vehicles/Tesla/Insurance"))
        #expect(rule.tokens == ["tesla"])
        #expect(!rule.tokens.contains("2024"))           // the year is never a trigger
        #expect(rule.destinationPath == "/root/Documents/Vehicles/Tesla/Insurance")
    }

    @Test func ruleBuilderFallsBackToSalientNameTokens() throws {
        // The folder name shares nothing with the file, so the rule keys on the single salient token.
        let rule = try #require(FilingEngine.rule(forFileNamed: "paystub.pdf", filedInto: "/root/Finance/Pay"))
        #expect(rule.tokens == ["paystub"])
    }

    @Test func ruleBuilderReturnsNilForANamelessFile() {
        // "IMG_0007" tokenizes to nothing (img = stopword, 0007 = non-year number), so no rule.
        #expect(FilingEngine.rule(forFileNamed: "IMG_0007.pdf", filedInto: "/root/Documents/Medical") == nil)
        #expect(FilingEngine.canRemember(fileName: "IMG_0007.pdf") == false)
        #expect(FilingEngine.canRemember(fileName: "Tesla Policy.pdf") == true)
    }

    // MARK: Intelligent classification overlay (AI)

    @Test func relativeFolderPathsAreRootRelativeAndShallowFirst() {
        let taxonomy = [dir("/root/Documents", [
            dir("/root/Documents/Family", [dir("/root/Documents/Family/Divit", [])]),
            dir("/root/Documents/Health", []),
        ])]
        let rels = FilingEngine.relativeFolderPaths(of: taxonomy)
        #expect(rels.contains("Documents"))
        #expect(rels.contains("Documents/Family/Divit"))
        #expect(!rels.contains { $0.hasPrefix("/") })              // relative, no leading slash
        #expect(rels.first == "Documents")                          // shallowest first
    }

    @Test func verdictOverridesTheHeuristicSuggestion() throws {
        // The keyword engine can't reason "Divit is a person"; the classifier can.
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Family",
                          [dir("/root/Documents/Family/Divit", [])])])]
        let loose = [file("/root/Downloads/Physician's Report - Divit.pdf", modified: y2024)]
        let base = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")

        let verdicts = ["/root/Downloads/Physician's Report - Divit.pdf":
            FilingVerdict(relativePath: "Documents/Family/Divit", confidence: .high, reason: "Divit’s medical record")]
        let out = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: taxonomy, providerRoot: "/root")
        let best = try #require(out.first?.best)
        #expect(best.path == "/root/Documents/Family/Divit")
        #expect(best.fromAI)
        #expect(best.confidence == .high)
        #expect(out.first?.hasConfidentHome == true)
        #expect(out.first?.isBatchEligible == false)                // AI picks need a per-file glance
        #expect(out.first?.providerRoot == "/root")                 // overlay preserves the provider root
    }

    @Test func verdictSanitizesModelPathAndProposesNewFolders() throws {
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Vehicles", [])])]
        let loose = [file("/root/Downloads/tesla.pdf", modified: y2024)]
        let base = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        // Model echoed the absolute path with a trailing slash — sanitize back to relative.
        let verdicts = ["/root/Downloads/tesla.pdf":
            FilingVerdict(relativePath: "/root/Documents/Vehicles/Tesla/", confidence: .medium, reason: "Vehicle doc")]
        let best = try #require(FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Vehicles/Tesla")
        #expect(best.newSegments == ["Tesla"])                      // created on apply
    }

    @Test func verdictEchoingASiblingOfTheRootIsNotStrippedIntoASubfolder() {
        // providerRoot "/root"; the model echoes "/rootArchive/Foo" — a SIBLING that shares the
        // string prefix but is NOT under the root. Stripping on a raw-string boundary would rewrite
        // it to "/root/Archive/Foo" and misfile the document into a real subfolder. The root prefix
        // is stripped only on a path-component boundary, so this can't happen.
        let taxonomy = [dir("/root/Archive", [])]
        let loose = [file("/root/Downloads/x.pdf", modified: y2024)]
        let base = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        let v = ["/root/Downloads/x.pdf": FilingVerdict(relativePath: "/rootArchive/Foo", confidence: .high, reason: "x")]
        let best = FilingEngine.applyVerdicts(v, to: base, taxonomy: taxonomy, providerRoot: "/root").first?.best
        #expect(best?.path != "/root/Archive/Foo")
    }

    @Test func verdictWithNoUsablePathIsIgnored() {
        let taxonomy = [dir("/root/Documents", [])]
        let loose = [file("/root/Downloads/tesla.pdf", modified: y2024)]
        let base = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        // Empty and traversal paths must never produce a destination.
        for bad in ["", "  ", "../../etc", "/root"] {
            let v = ["/root/Downloads/tesla.pdf": FilingVerdict(relativePath: bad, confidence: .high, reason: "x")]
            let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: taxonomy, providerRoot: "/root")
            #expect(!(out.first?.candidates.contains { $0.fromAI } ?? false), "should ignore bad path: “\(bad)”")
        }
    }

    // MARK: Rejections ("Try another")

    @Test func rejectedFolderIsDroppedFromCandidates() throws {
        let taxonomy = [dir("/root/Insurance", []),
                        dir("/root/Health", [dir("/root/Health/Insurance", [])])]
        let loose = [file("/root/Downloads/insurance renewal.pdf", modified: y2024)]
        // Baseline: shallower /root/Insurance leads, with /root/Health/Insurance as an alternate.
        let base = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        #expect(base.first?.best?.path == "/root/Insurance")

        // Reject /root/Insurance → it's gone and the next candidate leads.
        let rejected = ["/root/Downloads/insurance renewal.pdf": Set(["/root/Insurance"])]
        let out = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                       providerRoot: "/root", rejectedByFile: rejected)
        #expect(out.first?.candidates.allSatisfy { $0.path != "/root/Insurance" } == true)
        #expect(out.first?.best?.path == "/root/Health/Insurance")
    }

    @Test func rejectionIsAppliedBeforeCappingSoAValidCandidateSurvives() throws {
        // R-T2: with the cap pressed to 1, the top-ranked folder is the ONLY candidate that
        // survives ranking. If the user has rejected it, filtering after the cap would strip that
        // sole survivor and leave the file with no home at all — even though a valid deeper folder
        // exists. Filtering the pool BEFORE the cap keeps the deeper folder as the suggestion.
        let taxonomy = [dir("/root/Insurance", []),
                        dir("/root/Health", [dir("/root/Health/Insurance", [])])]
        let loose = [file("/root/Downloads/insurance renewal.pdf", modified: y2024)]
        // /root/Insurance ranks first (shallower); reject it, and cap the suggestions to one.
        let rejected = ["/root/Downloads/insurance renewal.pdf": Set(["/root/Insurance"])]
        let out = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root",
                                       rejectedByFile: rejected,
                                       options: FilingOptions(maxCandidates: 1))
        // Pre-fix (filter after cap) this would be empty; the deeper valid folder must survive.
        #expect(out.first?.candidates.count == 1)
        #expect(out.first?.best?.path == "/root/Health/Insurance")
    }

    @Test func aVerdictToARejectedFolderIsIgnored() throws {
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Family", [])])]
        let loose = [file("/root/Downloads/report.pdf", modified: y2024)]
        let base = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")
        let verdicts = ["/root/Downloads/report.pdf":
            FilingVerdict(relativePath: "Documents/Family", confidence: .high, reason: "x")]

        // Normally the model verdict applies…
        let applied = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: taxonomy, providerRoot: "/root")
        #expect(applied.first?.best?.path == "/root/Documents/Family")
        // …but not when that folder was rejected for this file.
        let rejected = ["/root/Downloads/report.pdf": Set(["/root/Documents/Family"])]
        let out = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: taxonomy,
                                             providerRoot: "/root", rejectedByFile: rejected)
        #expect(out.first?.best?.path != "/root/Documents/Family")
    }

    @Test func rejectedPathsMatchBySalientTokenSignature() {
        let rejections = [FilingRejection(tokens: ["policy", "tesla"], path: "/p/Wrong")]
        // A file sharing all the trigger tokens matches; one missing a token does not.
        #expect(FileSyncManager.rejectedPaths(forFileNamed: "Tesla Policy Renewal.pdf", in: rejections).contains("/p/Wrong"))
        #expect(FileSyncManager.rejectedPaths(forFileNamed: "Tesla Insurance.pdf", in: rejections).isEmpty)
    }

    @Test func aVerdictNeverOverridesARememberedRule() throws {
        // A remembered rule is an explicit user correction — the model must not displace it.
        let taxonomy = [dir("/root/Documents", [dir("/root/Documents/Vehicles",
                          [dir("/root/Documents/Vehicles/Tesla", [])])])]
        let loose = [file("/root/Downloads/tesla.pdf", modified: y2024)]
        let rule = FilingRule(tokens: ["tesla"], destinationPath: "/root/Documents/Vehicles/Tesla")
        let base = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root", rules: [rule])
        #expect(base.first?.best?.remembered == true)

        let v = ["/root/Downloads/tesla.pdf": FilingVerdict(relativePath: "Documents/Elsewhere", confidence: .high, reason: "x")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: taxonomy, providerRoot: "/root").first?.best)
        #expect(best.remembered)                                    // still the user's rule
        #expect(best.path == "/root/Documents/Vehicles/Tesla")
    }
}
