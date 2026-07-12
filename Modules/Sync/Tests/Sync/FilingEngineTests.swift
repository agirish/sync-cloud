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
        let rels = FilingEngine.relativeFolderPaths(of: taxonomy, providerRoot: "/root")
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
