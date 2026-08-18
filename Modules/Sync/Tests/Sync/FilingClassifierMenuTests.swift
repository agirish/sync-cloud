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

    // MARK: - Which files are blind in the first place

    /// **Every rule below is asked about a set no test used to compute.** All four `contentBlind`
    /// suites pass the set explicitly, and the parameter defaults to `[]` — the feature-off value —
    /// so the derivation at the two call sites had no coverage of any kind while the rules it feeds
    /// had plenty.
    @Test func aFileHandedOverWithNoTextIsBlindAndOneWithTextIsNot() {
        let blind = FilingEngine.contentBlindFiles(
            handedOver: ["/root/a.pdf", "/root/b.pdf"], read: ["/root/b.pdf"], hadReader: true)
        #expect(blind == ["/root/a.pdf"])
    }

    /// **The half that keeps installs without a reader working.** "We read it and got nothing" and
    /// "we did not read" look identical at the call site: a scan with reading switched off hands
    /// EVERY file over on its name, and calling all of them blind would cap every verdict at `.low`,
    /// refuse every new folder and demote every backend answer — leaving those machines with no
    /// intelligent suggestions at all, while telling the user nothing true, since nobody looked.
    @Test func noReaderMeansNoFileIsCalledBlind() {
        #expect(FilingEngine.contentBlindFiles(
            handedOver: ["/root/a.pdf", "/root/b.pdf"], read: [], hadReader: false).isEmpty)
        // …and the same inputs WITH a reader do call them blind, so the expectation above is about
        // the reader rather than about the function answering empty for everything.
        #expect(FilingEngine.contentBlindFiles(
            handedOver: ["/root/a.pdf", "/root/b.pdf"], read: [], hadReader: true).count == 2)
    }

    /// A file that was never handed to the classifier is not blind — it has no verdict to govern.
    /// `read` naming files outside the batch (a cache carrying earlier scans) must not add to it.
    @Test func blindnessCoversOnlyTheFilesActuallyHandedOver() {
        #expect(FilingEngine.contentBlindFiles(
            handedOver: ["/root/a.pdf"], read: ["/root/z.pdf"], hadReader: true) == ["/root/a.pdf"])
        #expect(FilingEngine.contentBlindFiles(
            handedOver: [], read: ["/root/z.pdf"], hadReader: true).isEmpty)
    }

    /// And both call sites reach it. The rule used to be written out twice, once per pass, with the
    /// same comment above each — and the pass that was missed on the last two filing fixes was the
    /// refine one, which is the pass that actually reaches the cloud model.
    @Test func bothClassifierPassesDeriveBlindnessFromTheSameRule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync")
        for file in ["FileSyncManager+Filing.swift", "FileSyncManager+FilingRefine.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            try #require(text.count > 5000, "\(file) could not be read — this scan would be vacuous")
            #expect(text.contains("FilingEngine.contentBlindFiles("),
                    "\(file) derives contentBlind itself again — the rule is back to two copies that have to be kept in step by hand")
            #expect(!text.contains(".subtracting(snippets.keys)"),
                    "\(file) still spells the subtraction out inline")
        }
    }

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
                                          reason: "common for financial statements",
                                          proposesNewFolder: true)]
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
                                     confidence: .high, reason: "r", proposesNewFolder: true)]
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
        let v = [path: FilingVerdict(relativePath: "Documents/Vehicles/Tesla", confidence: .high, reason: "r",
                                     proposesNewFolder: true)]
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

    // MARK: - A new folder has to be declared

    /// **An undeclared new folder is an invention, not a proposal.** Both schemas let a backend
    /// answer with a folder that does not exist — that is how a genuinely new destination gets
    /// offered — so until it had to SAY so, a deliberate proposal and a composed path segment were
    /// the same signal. Asked where `Divit - eOCI.pdf` belonged, the model answered
    /// `Immigration/OCI/Divit/eOCI.pdf`, split out of the file's OWN NAME, and a folder called
    /// `eOCI.pdf` was created on disk.
    @Test func anUndeclaredNewSegmentIsDroppedBackToWhatExists() throws {
        let path = "/root/TODO/Divit - eOCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Divit - eOCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Visa/Something", confidence: .high,
                                     reason: "r", proposesNewFolder: false)]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.taxonomy,
                                                           providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Visa")
        #expect(best.newSegments.isEmpty)
    }

    /// Declared, the same path creates the folder — without this half the rule above would be
    /// indistinguishable from never proposing a new folder at all.
    @Test func aDeclaredNewFolderIsStillProposed() throws {
        let path = "/root/TODO/a.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "a.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Visa/Something", confidence: .high,
                                     reason: "r", proposesNewFolder: true)]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.taxonomy,
                                                           providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Visa/Something")
        #expect(best.newSegments == ["Something"])
    }

    // MARK: - Renaming a proposed folder

    /// The name of a folder that does not exist yet is the model's suggestion, not the user's
    /// vocabulary. Editing it before accepting is a text field; not being able to means filing into
    /// a name you did not choose and renaming it in Finder afterwards.
    @Test func aProposedNewFolderCanBeRenamed() {
        let dest = FilingDestination(path: "/root/Documents/Visa/Suggested", confidence: .high,
                                     reasons: [], newSegments: ["Suggested"], fromAI: true)
        let renamed = dest.renamingNewFolder(to: "  H-1B Visa  ")
        #expect(renamed.path == "/root/Documents/Visa/H-1B Visa")
        #expect(renamed.newSegments == ["H-1B Visa"])
        #expect(renamed.confidence == dest.confidence)
        #expect(renamed.fromAI)
    }

    /// **Renaming an EXISTING folder would not rename anything** — it would name a different folder
    /// and quietly propose creating it. So a destination that creates nothing refuses the edit, and
    /// the card cannot turn "file into this" into "create that" by accident.
    @Test func anExistingDestinationRefusesTheRename() {
        let dest = FilingDestination(path: "/root/Documents/Visa", confidence: .high,
                                     reasons: [], newSegments: [])
        #expect(dest.renamingNewFolder(to: "Something Else") == dest)
    }

    /// A blank edit means "keep the suggestion", and a name that is not a single folder is refused
    /// rather than silently reinterpreted as a path.
    @Test func aBlankOrPathLikeRenameKeepsTheSuggestion() {
        let dest = FilingDestination(path: "/root/Documents/Visa/Suggested", confidence: .high,
                                     reasons: [], newSegments: ["Suggested"])
        #expect(dest.renamingNewFolder(to: "") == dest)
        #expect(dest.renamingNewFolder(to: "   ") == dest)
        #expect(dest.renamingNewFolder(to: "a/b") == dest)
        #expect(dest.renamingNewFolder(to: "..") == dest)
    }

    // MARK: - One person's documents do not go in another's folder

    private static func peopleProfile() -> Sync.FolderProfile {
        func entry(_ path: String, person: String?) -> FolderProfileEntry {
            FolderProfileEntry(path: path, role: .personBucket, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0,
                               axes: person.map { ["person": $0] } ?? [:])
        }
        let entries = [entry("Documents/OCI/Aditi", person: "Aditi"),
                       entry("Documents/OCI/Divit", person: "Divit"),
                       entry("Documents/Travel/Girish - 2021", person: nil)]
        return Sync.FolderProfile(profileId: "t", root: "~",
                                  folders: Dictionary(entries.map { ($0.path, $0) },
                                                      uniquingKeysWith: { a, _ in a }),
                                  personTokens: ["aditi", "divit", "girish", "muktha"])
    }

    private static let peopleTaxonomy: [FileNode] = [
        dir("/root/Documents", [dir("/root/Documents/OCI", [dir("/root/Documents/OCI/Aditi"),
                                                            dir("/root/Documents/OCI/Divit")]),
                                dir("/root/Documents/Travel", [dir("/root/Documents/Travel/Girish - 2021")])]),
    ]

    /// **Of every error this arc produced, filing one family member's document into another's is
    /// the one worth a hard rule** — least likely to be noticed, most annoying to undo. Asked where
    /// `Aditi OCI.pdf` belonged, the on-device model answered `Immigration/OCI/Divit/Application`
    /// while `Immigration/OCI/Aditi` exists, holds `Aditi - eOCI.pdf`, and was the router's top pick.
    @Test func aVerdictNamingADifferentPersonDoesNotLead() {
        let path = "/root/TODO/Aditi OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Aditi OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Divit", confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.peopleTaxonomy,
                                             providerRoot: "/root", profile: Self.peopleProfile())
        #expect(out.first?.best == nil, "Aditi's document was filed into Divit's folder")
    }

    /// The same verdict for the RIGHT person leads — without this the rule above is
    /// indistinguishable from refusing every person folder.
    @Test func aVerdictNamingTheSamePersonStillLeads() throws {
        let path = "/root/TODO/Aditi OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Aditi OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Aditi", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.peopleTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.peopleProfile()).first?.best)
        #expect(best.path == "/root/Documents/OCI/Aditi")
    }

    /// **Asked of the profile's person AXIS, not of the words in the path.** A trip folder called
    /// `Girish - 2021` holds the whole family's travel documents, and the profile records it with no
    /// person axis at all. Testing the path text would refuse those — measured, it would fire on 15
    /// of the corpus's 756 person-named documents instead of 3.
    @Test func aFolderWithNoPersonAxisIsNotAPersonFolder() throws {
        let path = "/root/TODO/Muktha Travel Letter.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Muktha Travel Letter.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Travel/Girish - 2021",
                                     confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.peopleTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.peopleProfile()).first?.best)
        #expect(best.path == "/root/Documents/Travel/Girish - 2021")
    }

    /// A file naming nobody is unconstrained — the rule is about a contradiction, not about
    /// requiring every file to declare a person.
    @Test func aFileNamingNoPersonIsUnconstrained() throws {
        let path = "/root/TODO/scan001.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "scan001.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Divit", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.peopleTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.peopleProfile()).first?.best)
        #expect(best.path == "/root/Documents/OCI/Divit")
    }

    // MARK: - The veto, resolved through the person registry

    /// The roster, with the aliases and full names a survey cannot know.
    private static func registry() -> PersonRegistry {
        PersonRegistry(people: [
            Person(id: "abhishek", displayName: "Abhishek", fullNames: ["Abhishek Girish"]),
            Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
            Person(id: "divit", displayName: "Divit", fullNames: ["Divit Abhishek"]),
            Person(id: "muktha", displayName: "Muktha", fullNames: ["Muktha Girish"],
                   aliases: ["Mom"]),
        ])
    }

    /// A profile whose person folders include Mom's, recorded under her legal name — which is how
    /// the real tree records it, and where the misfire lived.
    private static func aliasProfile() -> Sync.FolderProfile {
        func entry(_ path: String, person: String) -> FolderProfileEntry {
            FolderProfileEntry(path: path, role: .personBucket, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0,
                               axes: ["person": person])
        }
        let entries = [entry("Documents/Family/Mom/Passport", person: "Muktha"),
                       entry("Documents/OCI/Aditi", person: "Aditi"),
                       entry("Documents/OCI/Divit", person: "Divit")]
        return Sync.FolderProfile(profileId: "t", root: "~",
                                  folders: Dictionary(entries.map { ($0.path, $0) },
                                                      uniquingKeysWith: { a, _ in a }),
                                  personTokens: ["aditi", "divit", "muktha", "mom", "abhishek"],
                                  personAliases: ["mom": "muktha"])
    }

    private static let aliasTaxonomy: [FileNode] = [
        dir("/root/Documents", [
            dir("/root/Documents/Family", [dir("/root/Documents/Family/Mom",
                                               [dir("/root/Documents/Family/Mom/Passport")])]),
            dir("/root/Documents/OCI", [dir("/root/Documents/OCI/Aditi"),
                                        dir("/root/Documents/OCI/Divit")]),
        ]),
    ]

    /// **The veto used to fire against the CORRECT folder.** `Mom - passport.pdf` names Muktha,
    /// and the folder's axis says `Muktha` — but with the alias map flattened away, `mom` was just
    /// a token that failed to equal `muktha`, so the suggestion read as a cross-person mistake and
    /// was refused. The registry resolves both to one person.
    @Test func anAliasResolvesToThePersonItNames() throws {
        let path = "/root/TODO/Mom - passport.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Mom - passport.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Family/Mom/Passport",
                                     confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.aliasProfile(),
                                                           registry: Self.registry()).first?.best)
        #expect(best.path == "/root/Documents/Family/Mom/Passport",
                "Muktha's passport was refused by her own folder because Mom read as someone else")
    }

    /// The same fixture without a registry keeps the old token comparison — and the old bug. Pinned
    /// deliberately: it is what proves the test above is measuring the registry rather than some
    /// incidental change to the fixture.
    @Test func withoutARegistryTheAliasStillReadsAsAContradiction() {
        let path = "/root/TODO/Mom - passport.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Mom - passport.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Family/Mom/Passport",
                                     confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                             providerRoot: "/root", profile: Self.aliasProfile())
        #expect(out.first?.best == nil)
    }

    /// **A full name is not two people.** `Aditi Abhishek - OCI.pdf` names the daughter; the token
    /// comparison reads it as naming her father as well, so her own folder — whose axis is `Aditi`
    /// — contains a person the file "names" that is not the destination's, and the correct
    /// suggestion is refused.
    @Test func aFullNameDoesNotVetoTheOwnersOwnFolder() throws {
        let path = "/root/TODO/Aditi Abhishek - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Aditi Abhishek - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Aditi", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.aliasProfile(),
                                                           registry: Self.registry()).first?.best)
        #expect(best.path == "/root/Documents/OCI/Aditi")
    }

    /// And the veto still refuses the wrong person when the name is a full one — the protection is
    /// not simply switched off by phrase matching.
    @Test func aFullNameStillVetoesADifferentPersonsFolder() {
        let path = "/root/TODO/Aditi Abhishek - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Aditi Abhishek - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Divit", confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                             providerRoot: "/root", profile: Self.aliasProfile(),
                                             registry: Self.registry())
        #expect(out.first?.best == nil)
    }

    /// **A scan gets the protection its filename could never earn.** `Scan 2026-08-02.pdf` names
    /// nobody, so the filename-only rule left it unguarded; the page the scan already read names
    /// Aditi, and that is enough to refuse Divit's folder.
    @Test func aNamelessFileIsProtectedByThePageItWasReadFrom() {
        let path = "/root/TODO/Scan 2026-08-02.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Scan 2026-08-02.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Divit", confidence: .high, reason: "r")]
        let samples = [path: "OVERSEAS CITIZEN OF INDIA — Aditi Abhishek, date of birth 2016"]
        let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                             providerRoot: "/root", profile: Self.aliasProfile(),
                                             registry: Self.registry(), pageSamples: samples)
        #expect(out.first?.best == nil, "the page named Aditi and the file went to Divit anyway")
    }

    /// **A refusal has to be reportable, or the rule working perfectly is indistinguishable from
    /// it not existing.** The veto's entire job is to make a wrong suggestion not happen; nothing
    /// appears on screen when it does, so the only way the user learns it acted is this callback.
    @Test func aRefusalIsReported() throws {
        let path = "/root/TODO/Aditi Abhishek - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Aditi Abhishek - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Divit", confidence: .high, reason: "r")]
        var refusals: [PersonVetoRefusal] = []
        let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                             providerRoot: "/root", profile: Self.aliasProfile(),
                                             registry: Self.registry(),
                                             onVeto: { refusals.append($0) })
        #expect(out.first?.best == nil)
        let refusal = try #require(refusals.first)
        #expect(refusal.namedPerson == "aditi")
        #expect(refusal.proposedPerson == "divit")
        #expect(refusal.fileName == "Aditi Abhishek - OCI.pdf")
        #expect(refusal.destination == "Documents/OCI/Divit",
                "reported in the RELATIVE domain, like every other path claim in this overlay")
    }

    /// And a suggestion that is allowed through reports nothing — a log that fills up on the happy
    /// path would report the rule doing something on every file it never touched.
    @Test func anAllowedSuggestionReportsNoRefusal() {
        let path = "/root/TODO/Aditi Abhishek - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Aditi Abhishek - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Aditi", confidence: .high, reason: "r")]
        var refusals: [PersonVetoRefusal] = []
        _ = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                       providerRoot: "/root", profile: Self.aliasProfile(),
                                       registry: Self.registry(),
                                       onVeto: { refusals.append($0) })
        #expect(refusals.isEmpty)
    }

    /// **The filename outranks the page — it does not merely add to it.** A page-1 mention is
    /// testimony: an application prints the sponsor, a sibling, a witness. A file the user has
    /// *labelled* `Aditi` is Aditi's, so a verdict sending it to Divit's folder must be refused
    /// even though the page names Divit — which is exactly what folding the two sets together
    /// would permit, since Divit would then be "named".
    ///
    /// The second half is the same rule read the other way: a supporting name on the page cannot
    /// veto the person the filename declares.
    @Test func theFilenameOutranksThePageWhenBothNamePeople() throws {
        let contested = "/root/TODO/Aditi - OCI.pdf"
        let contestedBase = [FilingSuggestion(filePath: contested, fileName: "Aditi - OCI.pdf", size: 10,
                                              modificationDate: nil, candidates: [], providerRoot: "/root")]
        let toDivit = [contested: FilingVerdict(relativePath: "Documents/OCI/Divit",
                                                confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(toDivit, to: contestedBase, taxonomy: Self.aliasTaxonomy,
                                             providerRoot: "/root", profile: Self.aliasProfile(),
                                             registry: Self.registry(),
                                             pageSamples: [contested: "Sibling of Divit Abhishek, same application"])
        #expect(out.first?.best == nil,
                "the filename says Aditi; a mention of Divit on the page let it into his folder")

        let path = "/root/TODO/Divit - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Divit - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Divit", confidence: .high, reason: "r")]
        let samples = [path: "Sponsored by Abhishek Girish, father, in support of this application"]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.aliasProfile(),
                                                           registry: Self.registry(),
                                                           pageSamples: samples).first?.best)
        #expect(best.path == "/root/Documents/OCI/Divit")
    }
}
