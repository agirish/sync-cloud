import Foundation
import Testing
@testable import Sync

/// What the classifier is allowed to answer with, and what a verdict is allowed to override.
///
/// Both rules exist because of one card. A visa foil in `TODO` was suggested for
/// `Immigration/Form I-94/Abhishek` at High confidence, with the reason "the file name clearly
/// matches the name of the Form I-94" — a name match that does not exist. The model was not
/// reasoning badly: the folder the file belonged in, `Immigration/Visa/US/H-1B Visa/2024-2026`, was
/// 1,344th in the depth-ordered list that gets truncated at 250, so neither it nor any folder under
/// `Visa/US` was in the prompt at all. And the file's page-1 text — which names the consulate, the
/// visa class and the expiry — was withheld because its filename was "meaningful enough".
@Suite struct FilingClassifierMenuTests {

    // MARK: - classifierFolders

    @Test func aDeepFolderTheRouterWantsSurvivesACapThatWouldDropItByDepth() {
        let shallow = (0..<400).map { "Folder\(String(format: "%03d", $0))" }
        let deep = "Immigration/Visa/US/H-1B Visa/2024-2026"
        // The structural list alone: 250 shallowest, and the deep one is nowhere near them.
        #expect(!Array(shallow.prefix(250)).contains(deep))
        let menu = FilingEngine.classifierFolders(preferred: [deep], fallback: shallow)
        #expect(menu.contains(deep))
        #expect(menu.count == 250)
    }

    @Test func theFallbackKeepsItsReservedRoomSoTheTreeStillHasAShape() {
        let preferred = (0..<400).map { "Deep/A/B/C/leaf\($0)" }
        let fallback = (0..<400).map { "Top\($0)" }
        let menu = FilingEngine.classifierFolders(preferred: preferred, fallback: fallback,
                                                  limit: 250, reservedForFallback: 100)
        #expect(menu.count == 250)
        #expect(menu.filter { $0.hasPrefix("Deep/") }.count == 150)
        #expect(menu.filter { $0.hasPrefix("Top") }.count == 100)
        #expect(menu.first == "Deep/A/B/C/leaf0")            // most-deserving first
    }

    /// Room the fallback cannot fill goes back to `preferred` rather than shortening the menu — a
    /// small tree must not cost the classifier its budget.
    @Test func slackTheFallbackDoesNotUseGoesBackToPreferred() {
        let preferred = (0..<400).map { "Deep/leaf\($0)" }
        let menu = FilingEngine.classifierFolders(preferred: preferred, fallback: ["Top"],
                                                  limit: 250, reservedForFallback: 100)
        #expect(menu.count == 250)
        #expect(menu.contains("Top"))
        #expect(menu.filter { $0.hasPrefix("Deep/") }.count == 249)
    }

    @Test func theMenuIsDedupedAndOrderedAndNeverExceedsTheLimit() {
        let menu = FilingEngine.classifierFolders(preferred: ["A", "B", "A"], fallback: ["B", "C"],
                                                  limit: 3, reservedForFallback: 1)
        #expect(menu == ["A", "B", "C"])
        #expect(FilingEngine.classifierFolders(preferred: ["A"], fallback: ["B"], limit: 0).isEmpty)
    }

    // MARK: - preferredFolders

    private func candidate(_ path: String) -> FilingDestination {
        FilingDestination(path: path, confidence: .low, reasons: [], newSegments: [],
                          fromContent: false, remembered: false, fromAI: false)
    }

    private func suggestion(_ path: String, candidates: [String] = []) -> FilingSuggestion {
        FilingSuggestion(filePath: path, fileName: (path as NSString).lastPathComponent, size: 10,
                         modificationDate: nil, candidates: candidates.map(candidate),
                         providerRoot: "/root")
    }

    private func candidateFile(_ path: String) -> FilingCandidateFile {
        FilingCandidateFile(filePath: path, fileName: (path as NSString).lastPathComponent,
                            ext: "pdf", year: nil, contentSnippet: nil)
    }

    /// **Round-robin, not concatenated.** With more files than budget, taking each file's list in
    /// turn spends the menu on every file's best guess; taking them in file order would spend the
    /// whole thing on the first few and leave the rest a menu that says nothing about them.
    @Test func everyFilesFirstChoiceSurvivesABudgetSmallerThanTheShortlists() {
        let files = (0..<80).map { candidateFile("/root/TODO/f\($0).pdf") }
        let shortlists = Dictionary(uniqueKeysWithValues: files.map { f in
            (f.filePath, (0..<8).map { "Rank\($0)/for-\((f.fileName as NSString).deletingPathExtension)" })
        })
        let preferred = FileSyncManager.preferredFolders(for: files, shortlists: shortlists,
                                                         in: [], providerRoot: "/root")
        let menu = FilingEngine.classifierFolders(preferred: preferred, fallback: [])
        for f in files {
            let stem = (f.fileName as NSString).deletingPathExtension
            #expect(menu.contains("Rank0/for-\(stem)"), "\(stem) lost its first choice to another file")
        }
    }

    /// A file phase 2.5 skipped — it already had a confident home, so the router never ranked it —
    /// still contributes what the earlier phases proposed for it. Otherwise the menu says nothing
    /// about the very files the model is being asked to reconsider.
    @Test func aFileTheRouterNeverRankedFallsBackToItsOwnCandidates() {
        let files = [candidateFile("/root/TODO/receipt.pdf")]
        let suggestions = [suggestion("/root/TODO/receipt.pdf",
                                      candidates: ["/root/Finance/US/Receipts/2024"])]
        let preferred = FileSyncManager.preferredFolders(for: files, shortlists: [:],
                                                         in: suggestions, providerRoot: "/root")
        #expect(preferred == ["Finance/US/Receipts/2024"])   // relative to the provider root
    }

    // MARK: - contentBlind

    private static func dir(_ path: String, _ children: [FileNode] = []) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true,
                 children: children)
    }

    private static let taxonomy: [FileNode] = [
        dir("/root/Documents", [dir("/root/Documents/Visa"), dir("/root/Documents/I-94")]),
    ]

    /// A home the router read out of the document, exactly as `FileSyncManager.route` builds one.
    private func routed(_ path: String, to folder: String) -> FilingSuggestion {
        let dest = FilingDestination(path: folder, confidence: .medium, reasons: ["Matched “chennai”"],
                                     newSegments: [], fromContent: true, remembered: false,
                                     fromAI: false, evidenceToken: "Chennai", neighborMatches: 0)
        return FilingSuggestion(filePath: path, fileName: (path as NSString).lastPathComponent,
                                size: 10, modificationDate: nil, candidates: [dest],
                                providerRoot: "/root")
    }

    @Test func aBlindVerdictCannotDemoteAHomeReadOutOfTheDocument() throws {
        let path = "/root/TODO/H1B Visa - Nov 2026.pdf"
        let base = [routed(path, to: "/root/Documents/Visa")]
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high,
                                            reason: "The file name clearly matches the Form I-94")]
        let out = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                             providerRoot: "/root", contentBlind: [path])
        let best = try #require(out.first?.best)
        #expect(best.path == "/root/Documents/Visa", "a name-only High outranked a home read from page 1")
        #expect(best.fromContent)
    }

    /// The same verdict, from a backend that DID see the text, still leads — otherwise the test
    /// above passes because verdicts never apply rather than because blindness is what stopped it.
    @Test func theSameVerdictLeadsOnceTheBackendHasSeenTheText() throws {
        let path = "/root/TODO/H1B Visa - Nov 2026.pdf"
        let base = [routed(path, to: "/root/Documents/Visa")]
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high,
                                            reason: "It is an I-94 printout")]
        let out = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                             providerRoot: "/root", contentBlind: [])
        #expect(out.first?.best?.path == "/root/Documents/I-94")
        #expect(out.first?.best?.fromAI == true)
    }

    /// **A backend that has not read the document may not invent folders for it.** Naming an
    /// existing folder from a filename is a guess the user checks at a glance; naming one that does
    /// not exist yet asks them to accept a new shape for their tree on the same evidence.
    @Test func aBlindVerdictMayNotProposeANewFolder() throws {
        let path = "/root/TODO/DetailedBillApr2025.pdf"
        let dest = FilingDestination(path: "/root/Documents/Visa", confidence: .low, reasons: ["name"],
                                     newSegments: [], fromContent: false, remembered: false, fromAI: false)
        let base = [FilingSuggestion(filePath: path, fileName: "DetailedBillApr2025.pdf", size: 10,
                                     modificationDate: nil, candidates: [dest], providerRoot: "/root")]
        let invent = [path: FilingVerdict(relativePath: "Finance/US/Accounts", confidence: .high,
                                          reason: "common for financial statements")]
        #expect(FilingEngine.applyVerdicts(invent, to: base, taxonomy: Self.taxonomy,
                                           providerRoot: "/root", contentBlind: [path])
                    .first?.best?.path == "/root/Documents/Visa")
        // Sighted, the same verdict is allowed to create it — otherwise this passes because new
        // folders never apply rather than because blindness stopped it.
        #expect(FilingEngine.applyVerdicts(invent, to: base, taxonomy: Self.taxonomy,
                                           providerRoot: "/root", contentBlind: [])
                    .first?.best?.path == "/root/Finance/US/Accounts")
    }

    /// **A folder is never the file itself.** The model answered with the full path *including the
    /// file*, so the card offered to create a folder called `DetailedBillApr2025.pdf` and put
    /// `DetailedBillApr2025.pdf` in it.
    @Test func aVerdictEndingInTheFilesOwnNameKeepsTheParent() throws {
        let path = "/root/TODO/DetailedBillApr2025.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "DetailedBillApr2025.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Finance/US/Accounts/DetailedBillApr2025.pdf",
                                     confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.taxonomy,
                                                           providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Finance/US/Accounts")
        #expect(best.newSegments == ["Finance", "US", "Accounts"])
    }

    /// The narrow half of that rule. `tesla.pdf` → `Vehicles/Tesla` is a perfectly good new folder
    /// named for the vendor; matching the file's STEM rather than its whole name deletes it. This
    /// is the pair that caught the first version of the rule being too broad.
    @Test func aFolderNamedLikeTheFilesStemIsStillAFolder() throws {
        let path = "/root/TODO/tesla.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "tesla.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Vehicles/Tesla", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.taxonomy,
                                                           providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Vehicles/Tesla")
    }

    /// **A backend that has not read the document cannot report high confidence.** It saw a
    /// filename; that is a `.low` claim however sure the model says it is, and the badge is what
    /// the user reads before accepting a home. So a blind verdict no longer displaces a filename
    /// match the deterministic engine made from *the same information* and rated `.medium`.
    @Test func aBlindVerdictIsCappedAndCannotDisplaceAFilenameMatch() {
        let path = "/root/TODO/scan.pdf"
        let dest = FilingDestination(path: "/root/Documents/Visa", confidence: .medium, reasons: ["name"],
                                     newSegments: [], fromContent: false, remembered: false, fromAI: false)
        let base = [FilingSuggestion(filePath: path, fileName: "scan.pdf", size: 10,
                                     modificationDate: nil, candidates: [dest], providerRoot: "/root")]
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high, reason: "r")]
        #expect(FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                           providerRoot: "/root", contentBlind: [path])
                    .first?.best?.path == "/root/Documents/Visa")
    }

    /// The other half: with nothing better to keep, the blind verdict still leads — capped, so the
    /// card says `.low` rather than claiming a certainty nobody has. Without this the test above
    /// would pass for a rule that simply drops every blind verdict.
    @Test func aBlindVerdictStillLeadsWhenThereIsNothingBetter() throws {
        let path = "/root/TODO/scan.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "scan.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                                           providerRoot: "/root", contentBlind: [path])
                                    .first?.best)
        #expect(best.path == "/root/Documents/I-94")
        #expect(best.confidence == .low, "a filename-only verdict was published as \(best.confidence)")
    }

    /// **The model re-ranks the router's shortlist; it does not answer past it.** The same visa
    /// foil returned three different `.high` folders in three scans of one afternoon, so the
    /// arbitration cannot be confidence against confidence. A verdict naming an existing folder the
    /// router never shortlisted leaves the router's home on the card.
    @Test func aVerdictOutsideTheRouterShortlistDoesNotLead() {
        let path = "/root/TODO/H1B Visa - Nov 2026.pdf"
        let base = [routed(path, to: "/root/Documents/Visa")]
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                             providerRoot: "/root",
                                             routerShortlists: [path: ["Documents/Visa", "Documents/Other"]])
        #expect(out.first?.best?.path == "/root/Documents/Visa")
    }

    /// And inside it, the verdict leads exactly as before — otherwise the rule above would be
    /// indistinguishable from ignoring the model altogether.
    @Test func aVerdictInsideTheRouterShortlistStillLeads() {
        let path = "/root/TODO/H1B Visa - Nov 2026.pdf"
        let base = [routed(path, to: "/root/Documents/Visa")]
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                             providerRoot: "/root",
                                             routerShortlists: [path: ["Documents/Visa", "Documents/I-94"]])
        #expect(out.first?.best?.path == "/root/Documents/I-94")
        #expect(out.first?.best?.fromAI == true)
    }

    /// With no artifacts there is no shortlist, the router never ran, and the model is the only
    /// answer there is — the gate must not silently disable the backend on an unsurveyed tree.
    @Test func withNoShortlistTheVerdictIsUnconstrained() {
        let path = "/root/TODO/H1B Visa - Nov 2026.pdf"
        let base = [routed(path, to: "/root/Documents/Visa")]
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                             providerRoot: "/root", routerShortlists: [:])
        #expect(out.first?.best?.path == "/root/Documents/I-94")
    }

    /// **A path segment carrying a file extension is a file, not a folder.** Asked where
    /// `Divit - eOCI.pdf` goes, the model answered `Immigration/OCI/Divit/eOCI.pdf` — the name of
    /// the PEER document already filed there — and the apply path created a folder called
    /// `eOCI.pdf` and moved the file into it. Trimming it lands on the folder the model was
    /// reaching for, which is where the file belongs.
    @Test func aVerdictEndingInAnotherFilesNameKeepsTheFolder() throws {
        let path = "/root/TODO/Divit - eOCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Divit - eOCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Visa/eOCI.pdf", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.taxonomy,
                                                           providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Visa")
        #expect(best.newSegments.isEmpty, "the folder already existed; nothing should be created")
    }

    /// **A folder that already exists is the user's, whatever it is called.** The trim only ever
    /// applies to a segment that would be CREATED — otherwise a real folder named `Backup.old`
    /// would become unreachable.
    @Test func anExistingFolderWithAnExtensionIsLeftAlone() throws {
        let taxonomy = [Self.dir("/root/Documents", [Self.dir("/root/Documents/Backup.old")])]
        let path = "/root/TODO/notes.txt"
        let base = [FilingSuggestion(filePath: path, fileName: "notes.txt", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Backup.old", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: taxonomy,
                                                           providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Backup.old")
    }

    /// A dot is not an extension. `U.S. Passport` and `Dr. Smith` are ordinary folder names, and a
    /// looser test would delete their last word.
    @Test func aFolderNameWithADotIsNotAFileName() {
        #expect(FilingEngine.looksLikeAFileName("eOCI.pdf"))
        #expect(FilingEngine.looksLikeAFileName("415059.jpeg"))
        #expect(!FilingEngine.looksLikeAFileName("U.S. Passport"))
        #expect(!FilingEngine.looksLikeAFileName("Dr. Smith"))
        #expect(!FilingEngine.looksLikeAFileName("2024-2026"))
        #expect(!FilingEngine.looksLikeAFileName("Form 1099-B"))
        #expect(!FilingEngine.looksLikeAFileName(".hidden"))
    }
}
