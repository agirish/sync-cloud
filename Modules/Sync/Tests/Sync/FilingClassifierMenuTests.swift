import Foundation
import Testing
@testable import Sync

/// What the classifier may answer with, and what a verdict may override. A depth-ordered folder
/// list cut at 250 can leave a file's real folder out of the prompt (a deep visa folder ranks
/// 1,344th), and a model with no good option names a wrong folder at High. Withholding page 1
/// because the filename "looks meaningful" hides the very text that would have told it.
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

    /// The half that keeps installs without a reader working. "Read it and got nothing" and "didn't
    /// read" look identical at the call site: with reading off every file is handed over on its
    /// name, and calling them all blind would cap, refuse and demote every verdict unchecked.
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
            // Not a ban on spelling `.subtracting(snippets.keys)`, which pins a spelling, not a
            // behaviour: what matters is that `applyVerdicts` gets the shared rule's value.
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

    /// A blind verdict cannot demote a home read out of the document. The same verdict, from a
    /// backend that DID see the text, still leads — otherwise the blind case passes because
    /// verdicts never apply rather than because blindness is what stopped it.
    @Test(arguments: [true, false])
    func aBlindVerdictCannotDemoteAHomeReadOutOfTheDocument(blind: Bool) throws {
        let path = "/root/TODO/H1B Visa - Nov 2026.pdf"
        let base = [routed(path, to: "/root/Documents/Visa")]
        let reason = blind ? "The file name clearly matches the Form I-94" : "It is an I-94 printout"
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high, reason: reason)]
        let out = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                             providerRoot: "/root", contentBlind: blind ? [path] : [])
        let best = try #require(out.first?.best)
        if blind {
            #expect(best.path == "/root/Documents/Visa", "a name-only High outranked a home read from page 1")
            #expect(best.fromContent)
        } else {
            #expect(best.path == "/root/Documents/I-94")
            #expect(best.fromAI)
        }
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

    /// Where a verdict's path lands, and what it creates.
    ///
    /// - A folder is never the file itself: a model answering with the full path including the file
    ///   would create a folder called `DetailedBillApr2025.pdf` and put the file in it.
    /// - The narrow half: `tesla.pdf` → `Vehicles/Tesla` is a good new folder named for the vendor;
    ///   matching the file's stem rather than its whole name would delete it.
    /// - A segment carrying an extension is a file. Asked where `Son - eOCI.pdf` goes, a model can
    ///   answer with the peer document already filed there; trimming it lands on the folder.
    /// - A folder that already exists is the user's, whatever it is called. The trim applies only
    ///   to a segment that would be CREATED, or a real `Backup.old` would become unreachable.
    /// - A new folder has to be declared; an undeclared one is an invention, not a proposal.
    ///   Declared, the same path creates it, or the rule would be "never propose a new folder".
    @Test(arguments: [
        ("DetailedBillApr2025.pdf", "Finance/US/Accounts/DetailedBillApr2025.pdf", true, false,
         "Finance/US/Accounts", ["Finance", "US", "Accounts"]),
        ("tesla.pdf", "Documents/Vehicles/Tesla", true, false, "Documents/Vehicles/Tesla", nil),
        ("Son - eOCI.pdf", "Documents/Visa/eOCI.pdf", false, false, "Documents/Visa", []),
        ("notes.txt", "Documents/Backup.old", false, true, "Documents/Backup.old", nil),
        ("Son - eOCI.pdf", "Documents/Visa/Something", false, false, "Documents/Visa", []),
        ("a.pdf", "Documents/Visa/Something", true, false, "Documents/Visa/Something", ["Something"]),
    ] as [(String, String, Bool, Bool, String, [String]?)])
    func aVerdictPathLandsOnAFolder(file: String, relativePath: String, proposesNew: Bool,
                                    backupOld: Bool, expected: String, newSegments: [String]?) throws {
        let path = "/root/TODO/\(file)"
        let taxonomy = backupOld ? [Self.dir("/root/Documents", [Self.dir("/root/Documents/Backup.old")])]
                                 : Self.taxonomy
        let v = [path: FilingVerdict(relativePath: relativePath, confidence: .high, reason: "r",
                                     proposesNewFolder: proposesNew)]
        let best = try #require(FilingEngine.applyVerdicts(v, to: [suggestion(path)], taxonomy: taxonomy,
                                                           providerRoot: "/root").first?.best)
        #expect(best.path == "/root/\(expected)")
        if let newSegments {
            #expect(best.newSegments == newSegments, "the segments created for \(relativePath)")
        }
    }

    /// A backend that has not read the document cannot report high confidence: it saw a filename,
    /// a `.low` claim, and the badge is what the user reads before accepting. So a blind verdict
    /// doesn't displace a `.medium` filename match made from the same information. With nothing
    /// better to keep it still leads, capped at `.low`; without that half the first case would pass
    /// for a rule that drops every blind verdict.
    @Test(arguments: [true, false])
    func aBlindVerdictIsCappedAndCannotDisplaceAFilenameMatch(filenameMatch: Bool) throws {
        let path = "/root/TODO/scan.pdf"
        let dest = FilingDestination(path: "/root/Documents/Visa", confidence: .medium, reasons: ["name"],
                                     newSegments: [], fromContent: false, remembered: false, fromAI: false)
        let base = [FilingSuggestion(filePath: path, fileName: "scan.pdf", size: 10, modificationDate: nil,
                                     candidates: filenameMatch ? [dest] : [], providerRoot: "/root")]
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high, reason: "r")]
        let best = try #require(FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                                           providerRoot: "/root", contentBlind: [path])
                                    .first?.best)
        if filenameMatch {
            #expect(best.path == "/root/Documents/Visa")
        } else {
            #expect(best.path == "/root/Documents/I-94")
            #expect(best.confidence == .low, "a filename-only verdict was published as \(best.confidence)")
        }
    }

    /// The model re-ranks the router's shortlist; it does not answer past it. One file can come
    /// back as three different `.high` folders in three scans, so a verdict naming a folder the
    /// router never shortlisted leaves the router's home on the card. Inside the shortlist the
    /// verdict leads, or the rule would be ignoring the model. With no artifacts there is no
    /// shortlist, and the gate must not disable the backend on an unsurveyed tree.
    @Test(arguments: [
        (["Documents/Visa", "Documents/Other"], "/root/Documents/Visa"),
        (["Documents/Visa", "Documents/I-94"], "/root/Documents/I-94"),
        (nil, "/root/Documents/I-94"),
    ] as [([String]?, String)])
    func aVerdictOutsideTheRouterShortlistDoesNotLead(shortlist: [String]?, expected: String) {
        let path = "/root/TODO/H1B Visa - Nov 2026.pdf"
        let base = [routed(path, to: "/root/Documents/Visa")]
        let verdicts = [path: FilingVerdict(relativePath: "Documents/I-94", confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(verdicts, to: base, taxonomy: Self.taxonomy,
                                             providerRoot: "/root",
                                             routerShortlists: shortlist.map { [path: $0] } ?? [:])
        #expect(out.first?.best?.path == expected)
        if shortlist?.contains("Documents/I-94") == true {
            #expect(out.first?.best?.fromAI == true)
        }
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

    /// A colon is not a legal folder name: `validateItemName` rejects `:` because Finder maps it to
    /// `/`, so the folder created isn't the one the name shows. This guard calls the same predicate
    /// rather than a hand-made list that can drift.
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

    enum Roster: Sendable { case people, aliasOnly, aliasAndRegistry }

    /// Filing one family member's document into another's is the error worth a hard rule: least
    /// likely to be noticed, most annoying to undo. `nil` expects the verdict refused.
    @Test(arguments: [
        // Daughter's document, Son's folder: refused.
        ("Daughter OCI.pdf", "Documents/OCI/Son", Roster.people, nil, nil),
        // The right person leads, or the rule above could be refusing every person folder.
        ("Daughter OCI.pdf", "Documents/OCI/Daughter", .people, nil, "Documents/OCI/Daughter"),
        // Asked of the profile's person axis, not the path's words: the trip folder
        // `Elder - 2021` holds the whole family's documents and has no person axis.
        ("Granny Travel Letter.pdf", "Documents/Travel/Elder - 2021", .people, nil,
         "Documents/Travel/Elder - 2021"),
        // A file naming nobody is unconstrained: the rule is about a contradiction.
        ("scan001.pdf", "Documents/OCI/Son", .people, nil, "Documents/OCI/Son"),
        // The registry resolves the alias `Mom` and the axis `Granny` to one person, so her own
        // folder does not refuse her passport.
        ("Mom - passport.pdf", "Documents/Family/Mom/Passport", .aliasAndRegistry, nil,
         "Documents/Family/Mom/Passport"),
        // Without a registry the bare tokens misfire, so the case above measures the registry.
        ("Mom - passport.pdf", "Documents/Family/Mom/Passport", .aliasOnly, nil, nil),
        // A full name is not two people: `Daughter Father` names the daughter only.
        ("Daughter Father - OCI.pdf", "Documents/OCI/Daughter", .aliasAndRegistry, nil,
         "Documents/OCI/Daughter"),
        // And a full name still vetoes the wrong person's folder.
        ("Daughter Father - OCI.pdf", "Documents/OCI/Son", .aliasAndRegistry, nil, nil),
        // A nameless scan is protected by the page it was read from, which names Daughter.
        ("Scan 2026-08-02.pdf", "Documents/OCI/Son", .aliasAndRegistry,
         "OVERSEAS CITIZEN OF INDIA — Daughter Father, date of birth 2016", nil),
    ] as [(String, String, Roster, String?, String?)])
    func aVerdictNamingADifferentPersonDoesNotLead(file: String, verdict: String, roster: Roster,
                                                   page: String?, expected: String?) {
        let path = "/root/TODO/\(file)"
        let v = [path: FilingVerdict(relativePath: verdict, confidence: .high, reason: "r")]
        let out = FilingEngine.applyVerdicts(
            v, to: [suggestion(path)],
            taxonomy: roster == .people ? Self.peopleTaxonomy : Self.aliasTaxonomy,
            providerRoot: "/root",
            profile: roster == .people ? Self.peopleProfile() : Self.aliasProfile(),
            registry: roster == .aliasAndRegistry ? Self.registry() : nil,
            pageSamples: page.map { [path: $0] } ?? [:])
        if let expected {
            #expect(out.first?.best?.path == "/root/\(expected)", "\(file) was refused \(verdict)")
        } else {
            #expect(out.first?.best == nil, "\(file) was filed into \(verdict)")
        }
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
    /// (a sponsor, a sibling, a witness), but a file labelled `Daughter` is Daughter's, so a
    /// verdict sending it to Son's folder is refused though the page names Son. The second half: a
    /// supporting name on the page cannot veto the person the filename declares.
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
