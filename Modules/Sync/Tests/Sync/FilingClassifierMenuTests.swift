import Foundation
import Testing
@testable import Sync

/// What the classifier is allowed to answer with, and what a verdict is allowed to override.
///
/// A depth-ordered folder list cut at 250 can leave a file's real folder out of the prompt
/// entirely (a visa foil's `Immigration/Visa/US/H-1B Visa/2024-2026` ranks 1,344th), and a model
/// with no good option names a wrong folder at High with an invented reason. Withholding page 1
/// because the filename "looks meaningful" hides the very text (consulate, visa class, expiry) that
/// would have told it.
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

    /// Round-robin, not concatenated. With more files than budget, taking each file's list in
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

    /// The set every rule below is asked about. The four `contentBlind` suites pass it explicitly
    /// and the parameter defaults to `[]` (feature off), so this is what covers the derivation the
    /// two call sites use.
    @Test func aFileHandedOverWithNoTextIsBlindAndOneWithTextIsNot() {
        let blind = FilingEngine.contentBlindFiles(
            handedOver: ["/root/a.pdf", "/root/b.pdf"], read: ["/root/b.pdf"], hadReader: true)
        #expect(blind == ["/root/a.pdf"])
    }

    /// The half that keeps installs without a reader working. "We read it and got nothing" and "we
    /// didn't read" look identical at the call site: with reading off, every file is handed over on
    /// its name, and calling all of them blind would cap every verdict at `.low`, refuse every new
    /// folder and demote every backend answer, on a claim nobody checked.
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

    /// And both call sites reach it, so neither classifier pass can drift from the rule; the refine
    /// pass is the one that reaches the cloud model.
    @Test func bothClassifierPassesDeriveBlindnessFromTheSameRule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync")
        for file in ["FileSyncManager+Filing.swift", "FileSyncManager+FilingRefine.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            try #require(text.count > 5000, "\(file) could not be read — this scan would be vacuous")
            #expect(text.contains("FilingEngine.contentBlindFiles("),
                    "\(file) derives contentBlind itself again — the rule is back to two copies that have to be kept in step by hand")
            // Deliberately NOT a ban on spelling `.subtracting(snippets.keys)`: that expression is
            // general-purpose, a future line could want it for something unrelated, and a scan that
            // forbids it pins a spelling rather than a behaviour. What matters is that the value
            // handed to `applyVerdicts` comes from the shared rule, so that is what is asserted.
            let assigned = text.contains("let contentBlind = FilingEngine.contentBlindFiles(")
            #expect(assigned, "\(file) no longer builds its contentBlind set from the shared rule")
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

    /// A backend that has not read the document may not invent folders for it. Naming an
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

    /// A folder is never the file itself. A model answering with the full path including the file
    /// would have the card create a folder called `DetailedBillApr2025.pdf` and put
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
    /// named for the vendor; matching the file's stem rather than its whole name would delete it.
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

    /// A backend that has not read the document cannot report high confidence. It saw a filename;
    /// that is a `.low` claim however sure the model says it is, and the badge is what the user
    /// reads before accepting a home. So a blind verdict doesn't displace a filename match the
    /// deterministic engine made from the same information and rated `.medium`.
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

    /// The model re-ranks the router's shortlist; it does not answer past it. One file can come
    /// back as three different `.high` folders in three scans, so arbitration can't be confidence
    /// against confidence. A verdict naming an existing folder the router never shortlisted leaves
    /// the router's home on the card.
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

    /// A path segment carrying a file extension is a file, not a folder. Asked where
    /// `Son - eOCI.pdf` goes, a model can answer `Immigration/OCI/Son/eOCI.pdf`, the name of the
    /// peer document already filed there, and the apply path would create a folder `eOCI.pdf`.
    /// Trimming it lands on the folder the model was reaching for.
    @Test func aVerdictEndingInAnotherFilesNameKeepsTheFolder() throws {
        let path = "/root/TODO/Son - eOCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Son - eOCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Visa/eOCI.pdf", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.taxonomy,
                                                           providerRoot: "/root").first?.best)
        #expect(best.path == "/root/Documents/Visa")
        #expect(best.newSegments.isEmpty, "the folder already existed; nothing should be created")
    }

    /// A folder that already exists is the user's, whatever it is called. The trim only ever
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

    /// An undeclared new folder is an invention, not a proposal. Both schemas let a backend answer
    /// with a folder that doesn't exist (that is how a new destination is offered), so it must say
    /// so: otherwise a deliberate proposal and a segment split out of the file's own name
    /// (`Immigration/OCI/Son/eOCI.pdf` for `Son - eOCI.pdf`) are the same signal, and a folder
    /// `eOCI.pdf` is created on disk.
    @Test func anUndeclaredNewSegmentIsDroppedBackToWhatExists() throws {
        let path = "/root/TODO/Son - eOCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Son - eOCI.pdf", size: 10,
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

    /// Renaming an existing folder would not rename anything: it would name a different folder
    /// and quietly propose creating it. So a destination that creates nothing refuses the edit, and
    /// the card cannot turn "file into this" into "create that" by accident.
    @Test func anExistingDestinationRefusesTheRename() {
        let dest = FilingDestination(path: "/root/Documents/Visa", confidence: .high,
                                     reasons: [], newSegments: [])
        #expect(dest.renamingNewFolder(to: "Something Else") == dest)
    }

    /// A colon is not a legal folder name here. Every new-folder path in the app goes through
    /// `validateItemName`, which rejects `:` because Finder maps it to `/` per HFS+ semantics, so
    /// the folder created isn't the one the name shows. This guard calls the same predicate rather
    /// than keeping a hand-made list that can drift.
    @Test func aRenameTheSharedValidatorRefusesIsRefusedHereToo() {
        let dest = FilingDestination(path: "/root/Documents/Visa/Suggested", confidence: .high,
                                     reasons: [], newSegments: ["Suggested"])
        // The premise: the shared predicate really does refuse this, or the test pins nothing.
        #expect(FileSyncManager.validateItemName("2026: Q1") != nil)
        #expect(dest.renamingNewFolder(to: "2026: Q1") == dest,
                "a name the rest of the app refuses was accepted here")
        // And a name it accepts still goes through, so the guard did not become "refuse edits".
        #expect(dest.renamingNewFolder(to: "2026 Q1").newSegments == ["2026 Q1"])
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
        let entries = [entry("Documents/OCI/Daughter", person: "Daughter"),
                       entry("Documents/OCI/Son", person: "Son"),
                       entry("Documents/Travel/Elder - 2021", person: nil)]
        return Sync.FolderProfile(profileId: "t", root: "~",
                                  folders: Dictionary(entries.map { ($0.path, $0) },
                                                      uniquingKeysWith: { a, _ in a }),
                                  personTokens: ["daughter", "son", "elder", "granny"])
    }

    private static let peopleTaxonomy: [FileNode] = [
        dir("/root/Documents", [dir("/root/Documents/OCI", [dir("/root/Documents/OCI/Daughter"),
                                                            dir("/root/Documents/OCI/Son")]),
                                dir("/root/Documents/Travel", [dir("/root/Documents/Travel/Elder - 2021")])]),
    ]

    /// Filing one family member's document into another's is the error worth a hard rule: least
    /// likely to be noticed, most annoying to undo. Asked where `Daughter OCI.pdf` belongs, a model
    /// can answer `Immigration/OCI/Son/Application` while `Immigration/OCI/Daughter` exists, holds
    /// `Daughter - eOCI.pdf`, and is the router's top pick.
    @Test func aVerdictNamingADifferentPersonDoesNotLead() {
        let path = "/root/TODO/Daughter OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Daughter OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Son", confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.peopleTaxonomy,
                                             providerRoot: "/root", profile: Self.peopleProfile())
        #expect(out.first?.best == nil, "Daughter's document was filed into Son's folder")
    }

    /// The same verdict for the RIGHT person leads — without this the rule above is
    /// indistinguishable from refusing every person folder.
    @Test func aVerdictNamingTheSamePersonStillLeads() throws {
        let path = "/root/TODO/Daughter OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Daughter OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Daughter", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.peopleTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.peopleProfile()).first?.best)
        #expect(best.path == "/root/Documents/OCI/Daughter")
    }

    /// Asked of the profile's person axis, not of the words in the path. A trip folder called
    /// `Elder - 2021` holds the whole family's travel documents, and the profile records it with no
    /// person axis. Testing the path text would refuse those: on the corpus it fires on 15 of 756
    /// person-named documents instead of 3.
    @Test func aFolderWithNoPersonAxisIsNotAPersonFolder() throws {
        let path = "/root/TODO/Granny Travel Letter.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Granny Travel Letter.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/Travel/Elder - 2021",
                                     confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.peopleTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.peopleProfile()).first?.best)
        #expect(best.path == "/root/Documents/Travel/Elder - 2021")
    }

    /// A file naming nobody is unconstrained — the rule is about a contradiction, not about
    /// requiring every file to declare a person.
    @Test func aFileNamingNoPersonIsUnconstrained() throws {
        let path = "/root/TODO/scan001.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "scan001.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Son", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.peopleTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.peopleProfile()).first?.best)
        #expect(best.path == "/root/Documents/OCI/Son")
    }

    // MARK: - The veto, resolved through the person registry

    /// The roster, with the aliases and full names a survey cannot know.
    private static func registry() -> PersonRegistry {
        PersonRegistry(people: [
            Person(id: "father", displayName: "Father", fullNames: ["Father Elder"]),
            Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
            Person(id: "son", displayName: "Son", fullNames: ["Son Father"]),
            Person(id: "granny", displayName: "Granny", fullNames: ["Granny Elder"],
                   aliases: ["Mom"]),
        ])
    }

    /// A profile whose person folders include Mom's, recorded under her legal name, which is how
    /// the real tree records it and where an alias can misfire.
    private static func aliasProfile() -> Sync.FolderProfile {
        func entry(_ path: String, person: String) -> FolderProfileEntry {
            FolderProfileEntry(path: path, role: .personBucket, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0,
                               axes: ["person": person])
        }
        let entries = [entry("Documents/Family/Mom/Passport", person: "Granny"),
                       entry("Documents/OCI/Daughter", person: "Daughter"),
                       entry("Documents/OCI/Son", person: "Son")]
        return Sync.FolderProfile(profileId: "t", root: "~",
                                  folders: Dictionary(entries.map { ($0.path, $0) },
                                                      uniquingKeysWith: { a, _ in a }),
                                  personTokens: ["daughter", "son", "granny", "mom", "father"],
                                  personAliases: ["mom": "granny"])
    }

    private static let aliasTaxonomy: [FileNode] = [
        dir("/root/Documents", [
            dir("/root/Documents/Family", [dir("/root/Documents/Family/Mom",
                                               [dir("/root/Documents/Family/Mom/Passport")])]),
            dir("/root/Documents/OCI", [dir("/root/Documents/OCI/Daughter"),
                                        dir("/root/Documents/OCI/Son")]),
        ]),
    ]

    /// The veto must not fire against the correct folder. `Mom - passport.pdf` names Granny and the
    /// folder's axis says `Granny`; compared as bare tokens, `mom` fails to equal `granny` and the
    /// suggestion reads as a cross-person mistake. The registry resolves both to one person.
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
                "Granny's passport was refused by her own folder because Mom read as someone else")
    }

    /// The same fixture without a registry keeps the bare token comparison and its misfire. Pinned
    /// so the test above is known to measure the registry, not an incidental fixture change.
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

    /// A full name is not two people. `Daughter Father - OCI.pdf` names the daughter; a token
    /// comparison reads it as naming her father too, so her own folder (axis `Daughter`) lacks a
    /// person the file "names", and the correct suggestion would be refused.
    @Test func aFullNameDoesNotVetoTheOwnersOwnFolder() throws {
        let path = "/root/TODO/Daughter Father - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Daughter Father - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Daughter", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.aliasProfile(),
                                                           registry: Self.registry()).first?.best)
        #expect(best.path == "/root/Documents/OCI/Daughter")
    }

    /// And the veto still refuses the wrong person when the name is a full one — the protection is
    /// not simply switched off by phrase matching.
    @Test func aFullNameStillVetoesADifferentPersonsFolder() {
        let path = "/root/TODO/Daughter Father - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Daughter Father - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Son", confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                             providerRoot: "/root", profile: Self.aliasProfile(),
                                             registry: Self.registry())
        #expect(out.first?.best == nil)
    }

    /// A scan gets the protection its filename can't earn. `Scan 2026-08-02.pdf` names nobody, so
    /// the filename alone leaves it unguarded; the page the scan already read names Daughter, and
    /// that is enough to refuse Son's folder.
    @Test func aNamelessFileIsProtectedByThePageItWasReadFrom() {
        let path = "/root/TODO/Scan 2026-08-02.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Scan 2026-08-02.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Son", confidence: .high, reason: "r")]
        let samples = [path: "OVERSEAS CITIZEN OF INDIA — Daughter Father, date of birth 2016"]
        let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                             providerRoot: "/root", profile: Self.aliasProfile(),
                                             registry: Self.registry(), pageSamples: samples)
        #expect(out.first?.best == nil, "the page named Daughter and the file went to Son anyway")
    }

    /// A refusal has to be reportable, or the rule working is indistinguishable from it not
    /// existing: nothing appears on screen when the veto acts, so this callback is the only way the
    /// user learns of it.
    @Test func aRefusalIsReported() throws {
        let path = "/root/TODO/Daughter Father - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Daughter Father - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Son", confidence: .high, reason: "r")]
        var refusals: [PersonVetoRefusal] = []
        let out = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                             providerRoot: "/root", profile: Self.aliasProfile(),
                                             registry: Self.registry(),
                                             onVeto: { refusals.append($0) })
        #expect(out.first?.best == nil)
        let refusal = try #require(refusals.first)
        #expect(refusal.namedPerson == "daughter")
        #expect(refusal.proposedPerson == "son")
        #expect(refusal.fileName == "Daughter Father - OCI.pdf")
        #expect(refusal.destination == "Documents/OCI/Son",
                "reported in the RELATIVE domain, like every other path claim in this overlay")
    }

    /// And a suggestion that is allowed through reports nothing — a log that fills up on the happy
    /// path would report the rule doing something on every file it never touched.
    @Test func anAllowedSuggestionReportsNoRefusal() {
        let path = "/root/TODO/Daughter Father - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Daughter Father - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Daughter", confidence: .high, reason: "r")]
        var refusals: [PersonVetoRefusal] = []
        _ = FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                       providerRoot: "/root", profile: Self.aliasProfile(),
                                       registry: Self.registry(),
                                       onVeto: { refusals.append($0) })
        #expect(refusals.isEmpty)
    }

    /// The filename outranks the page; it doesn't merely add to it. A page-1 mention is testimony
    /// (an application prints the sponsor, a sibling, a witness), but a file the user has labelled
    /// `Daughter` is Daughter's, so a verdict sending it to Son's folder is refused even though the
    /// page names Son. Folding the two sets together would let it through.
    ///
    /// The second half is the same rule read the other way: a supporting name on the page cannot
    /// veto the person the filename declares.
    @Test func theFilenameOutranksThePageWhenBothNamePeople() throws {
        let contested = "/root/TODO/Daughter - OCI.pdf"
        let contestedBase = [FilingSuggestion(filePath: contested, fileName: "Daughter - OCI.pdf", size: 10,
                                              modificationDate: nil, candidates: [], providerRoot: "/root")]
        let toSon = [contested: FilingVerdict(relativePath: "Documents/OCI/Son",
                                                confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(toSon, to: contestedBase, taxonomy: Self.aliasTaxonomy,
                                             providerRoot: "/root", profile: Self.aliasProfile(),
                                             registry: Self.registry(),
                                             pageSamples: [contested: "Sibling of Son Father, same application"])
        #expect(out.first?.best == nil,
                "the filename says Daughter; a mention of Son on the page let it into his folder")

        let path = "/root/TODO/Son - OCI.pdf"
        let base = [FilingSuggestion(filePath: path, fileName: "Son - OCI.pdf", size: 10,
                                     modificationDate: nil, candidates: [], providerRoot: "/root")]
        let v = [path: FilingVerdict(relativePath: "Documents/OCI/Son", confidence: .high, reason: "r")]
        let samples = [path: "Sponsored by Father Elder, father, in support of this application"]
        let best = try #require(FilingEngine.applyVerdicts(v, to: base, taxonomy: Self.aliasTaxonomy,
                                                           providerRoot: "/root",
                                                           profile: Self.aliasProfile(),
                                                           registry: Self.registry(),
                                                           pageSamples: samples).first?.best)
        #expect(best.path == "/root/Documents/OCI/Son")
    }
}
