import Foundation
import Testing
@testable import Sync

/// Surveys by source (GK–GN): which survey places a tree's files, the store that records a source's
/// own survey and choice, and learning one without ever re-aiming the primary.
@Suite @MainActor struct SourceSurveyTests {

    static func profile(_ id: String, root: String, _ folders: [String]) -> FolderProfile {
        let entries = folders.map {
            FolderProfileEntry(path: $0, role: .destination, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0, axes: [:])
        }
        return FolderProfile(profileId: id, root: root,
                             folders: Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }),
                             personTokens: [])
    }

    static func mkdirs(_ root: URL, _ paths: [String]) throws {
        for p in paths {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(p),
                                                    withIntermediateDirectories: true)
        }
    }

    // MARK: The rule

    @Test func aTreeInsideThePrimarySurveyIsPrimaryWhateverItsFolders() {
        let r = FilingSurveyInUse.resolve(providerRoot: "/u/Documents/Finance", primaryRoot: "/u/Documents",
                                          entry: SourceSurveyEntry(root: "/u/Documents/Finance", choice: .own),
                                          hasOwn: true, matched: 0, total: 40)
        #expect(r.kind == .primary)
        #expect(!r.chosen)
    }

    /// GN: at least half borrows, under half is placed by name. 50% exactly borrows; 49% does not.
    @Test func halfOrMoreBorrowsThePrimarySurvey() {
        func kind(_ matched: Int, _ total: Int) -> FilingSurveyInUse.Kind {
            FilingSurveyInUse.resolve(providerRoot: "/d", primaryRoot: "/u/Documents", entry: nil,
                                      hasOwn: false, matched: matched, total: total).kind
        }
        #expect(kind(2_499, 2_745) == .borrowed)   // Dropbox on his Mac
        #expect(kind(2_529, 3_574) == .borrowed)   // OneDrive
        #expect(kind(28, 4_045) == .byName)        // Google Drive
        #expect(kind(50, 100) == .borrowed)
        #expect(kind(49, 100) == .byName)
        #expect(kind(0, 0) == .borrowed, "an empty source uses the primary survey until it holds folders")
    }

    @Test func aChoiceOverridesTheMeasurement() {
        let own = FilingSurveyInUse.resolve(providerRoot: "/d", primaryRoot: "/u/Documents",
                                            entry: SourceSurveyEntry(root: "/d", choice: .own),
                                            hasOwn: true, matched: 90, total: 100)
        #expect(own.kind == .own && own.chosen)
        let borrowed = FilingSurveyInUse.resolve(providerRoot: "/g", primaryRoot: "/u/Documents",
                                                 entry: SourceSurveyEntry(root: "/g", profileId: "x", choice: .primary),
                                                 hasOwn: true, matched: 1, total: 100)
        #expect(borrowed.kind == .borrowed && borrowed.chosen)
    }

    /// An own survey wins by default; a choice of "own" whose survey has gone falls back to the
    /// measurement rather than to nothing.
    @Test func anOwnSurveyIsUsedUnlessItIsGone() {
        let has = FilingSurveyInUse.resolve(providerRoot: "/g", primaryRoot: "/u/Documents", entry: nil,
                                            hasOwn: true, matched: 90, total: 100)
        #expect(has.kind == .own && !has.chosen)
        let gone = FilingSurveyInUse.resolve(providerRoot: "/g", primaryRoot: "/u/Documents",
                                             entry: SourceSurveyEntry(root: "/g", choice: .own),
                                             hasOwn: false, matched: 1, total: 100)
        #expect(gone.kind == .byName)
    }

    @Test func withNoPrimarySurveyOnlyAnOwnOneApplies() {
        #expect(FilingSurveyInUse.resolve(providerRoot: "/g", primaryRoot: nil, entry: nil, hasOwn: false,
                                          matched: 0, total: 0).kind == .byName)
        #expect(FilingSurveyInUse.resolve(providerRoot: "/g", primaryRoot: nil,
                                          entry: SourceSurveyEntry(root: "/g", choice: .primary),
                                          hasOwn: false, matched: 0, total: 0).kind == .byName)
    }

    @Test func overlapIgnoresCaseAndTheRootEntry() {
        let o = FilingSurveyInUse.overlap(folders: [".", "Finance", "finance/us", "Work Authorization", ""],
                                          primaryFolders: [".", "Finance", "Finance/US", "Home"])
        #expect(o.matched == 2)
        #expect(o.total == 3)
    }

    /// Rounded down, so a source just short of borrowing never reads "50%".
    @Test func thePercentRoundsDown() {
        let use = FilingSurveyInUse(kind: .byName, root: "/g", matched: 4_996, total: 10_000, chosen: false)
        #expect(use.matchPercent == "49%")
    }

    @Test func iCloudsDocumentsLinkIsInsideThePrimarySurvey() throws {
        let root = try makeCanonicalTempRoot(prefix: "SurveyLink")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let container = root.appendingPathComponent("CloudDocs")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: container.appendingPathComponent("Documents"),
                                                   withDestinationURL: real)
        #expect(FilingSurveyInUse.isAtOrInside(container.appendingPathComponent("Documents").path, real.path))
        #expect(!FilingSurveyInUse.isAtOrInside(container.path, real.path))
        #expect(!FilingSurveyInUse.isAtOrInside(root.appendingPathComponent("Documents2").path, real.path),
                "a sibling sharing a prefix is not inside")
    }

    /// The closest source names a tree, so iCloud's Documents is not named after a Home folder
    /// source that also holds it.
    @Test func theClosestSourceNamesATree() {
        let sources = [(name: "Home", root: "/u"), (name: "iCloud Drive", root: "/u/iCloud"),
                       (name: "Google Drive", root: "/u/Library/CloudStorage/GoogleDrive-a")]
        #expect(FilingSurveyInUse.sourceName(for: "/u/iCloud/Documents", sources: sources) == "iCloud Drive")
        #expect(FilingSurveyInUse.sourceName(for: "/u/Library/CloudStorage/GoogleDrive-a/My Drive/Documents",
                                             sources: sources) == "Google Drive")
        #expect(FilingSurveyInUse.sourceName(for: "/elsewhere", sources: sources) == nil)
        #expect(FilingSurveyInUse.possessive("Dropbox") == "Dropbox’s")
        #expect(FilingSurveyInUse.possessive("Documents") == "Documents’")
    }

    // MARK: The store

    @Test func theStoreRecordsAndDropsEntries() throws {
        let dir = try makeCanonicalTempRoot(prefix: "SourceSurveyStore")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SourceSurveyStore.entries(in: dir).isEmpty)
        try SourceSurveyStore.update(root: "/g/Documents", in: dir) { $0.choice = .primary }
        try SourceSurveyStore.update(root: "/g/Documents/", in: dir) { $0.profileId = "source-1"; $0.folderCount = 7 }
        let entries = SourceSurveyStore.entries(in: dir)
        #expect(entries.count == 1, "a trailing slash names the same folder")
        #expect(entries.first?.choice == .primary)
        #expect(entries.first?.profileId == "source-1")
        // Emptied: dropped rather than kept as a row that records nothing.
        try SourceSurveyStore.update(root: "/g/Documents", in: dir) { $0.choice = nil; $0.profileId = nil }
        #expect(SourceSurveyStore.entries(in: dir).isEmpty)
    }

    @Test func anUnreadableStoreIsEverySourceOnItsDefault() throws {
        let dir = try makeCanonicalTempRoot(prefix: "SourceSurveyStoreBad")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ not json".utf8).write(to: SourceSurveyStore.url(in: dir))
        #expect(SourceSurveyStore.entries(in: dir).isEmpty)
    }

    /// The whole reason the store exists: a source's survey never becomes the active profile, even
    /// when the active one is the app's own derivation, which `writeProfile` would re-point away from.
    @Test func aSourceProfileNeverTouchesProfilesJson() throws {
        let dir = try makeCanonicalTempRoot(prefix: "SourceProfileWrite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = Data(#"{"activeProfileId":"walk-1","schemaVersion":1}"#.utf8)
        try index.write(to: FilingProfileStore.indexURL(in: dir))
        let p = Self.profile("source-1", root: "/g", [".", "School"])
        try FilingProfileStore.writeSourceProfile(p, in: dir)
        #expect(try Data(contentsOf: FilingProfileStore.indexURL(in: dir)) == index)
        #expect(FilingProfileStore.profile(id: "source-1", in: dir)?.folders.keys.contains("School") == true)
        #expect(throws: FilingProfileStore.WriteRefusal.profileExists(id: "source-1")) {
            try FilingProfileStore.writeSourceProfile(p, in: dir)
        }
    }

    // MARK: On the manager

    struct Fixture {
        let base: URL
        let profiles: URL
        let primary: URL
        let google: URL
        let manager: FileSyncManager
    }

    /// A primary survey of `Documents` (Finance, Home…) and a "Google Drive" laid out differently.
    static func fixture() throws -> Fixture {
        let base = try makeCanonicalTempRoot(prefix: "SourceSurveys")
        let profiles = base.appendingPathComponent("profiles")
        let primary = base.appendingPathComponent("Documents")
        let google = base.appendingPathComponent("Google/Documents")
        try mkdirs(primary, ["Finance/US", "Finance/IN", "Home/Utilities", "School"])
        try mkdirs(google, ["Work Authorization/H-1B", "Personal/Letters", "School/Divit", "Feb 2026"])
        let m = FileSyncManager()
        m.filingProfilesDirectory = profiles
        m.filingFolderProfile = profile("primary", root: primary.path,
                                        [".", "Finance", "Finance/US", "Finance/IN", "Home", "Home/Utilities", "School"])
        m.sourceSurveyRetire = { try FileManager.default.removeItem(at: $0) }
        return Fixture(base: base, profiles: profiles, primary: primary, google: google, manager: m)
    }

    @Test func aDifferentLayoutIsPlacedByNameAndACopyBorrows() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let g = f.manager.resolveFilingSurvey(providerRoot: f.google.path,
                                              folders: ["Work Authorization", "Work Authorization/H-1B",
                                                        "Personal", "Personal/Letters", "School", "School/Divit"])
        #expect(g.kind == .byName)
        #expect(g.matched == 1 && g.total == 6)
        #expect(f.manager.filingRoutingProfile == nil, "a tree under half like iCloud's gets no profile")

        let d = f.manager.resolveFilingSurvey(providerRoot: f.base.appendingPathComponent("Dropbox").path,
                                              folders: ["Finance", "Finance/US", "Home", "Extra"])
        #expect(d.kind == .borrowed)
        #expect(f.manager.filingRoutingProfile?.profileId == "primary")

        let p = f.manager.resolveFilingSurvey(providerRoot: f.primary.path, folders: ["Finance"])
        #expect(p.kind == .primary)
    }

    /// Learn Its Folders: the own survey lands beside the primary, is listed in the store, is what
    /// the tree now uses — and `profiles.json` still names the primary.
    @Test func learningASourceWritesItsOwnSurveyAndLeavesThePrimaryActive() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try FileManager.default.createDirectory(at: f.profiles, withIntermediateDirectories: true)
        let index = Data(#"{"activeProfileId":"primary","schemaVersion":1}"#.utf8)
        try index.write(to: FilingProfileStore.indexURL(in: f.profiles))
        f.manager.resolveFilingSurvey(providerRoot: f.google.path, folders: ["Personal", "School"])

        let result = await f.manager.learnSourceSurvey(root: f.google.path)
        guard case .success(let use?) = result else {
            Issue.record("learning failed: \(result)")
            return
        }
        #expect(use.kind == .own)
        #expect(use.ownFolderCount == 7)
        let entry = try #require(SourceSurveyStore.entry(forRoot: f.google.path, in: f.profiles))
        let id = try #require(entry.profileId)
        #expect(id.hasPrefix("source-"))
        #expect(entry.choice == .own)
        #expect(FilingProfileStore.profile(id: id, in: f.profiles)?.folders.keys.contains("Work Authorization/H-1B") == true)
        #expect(try Data(contentsOf: FilingProfileStore.indexURL(in: f.profiles)) == index)
        #expect(f.manager.filingRoutingProfile?.profileId == id)
        #expect(f.manager.filingRoutingMemory == nil, "a folders-only survey carries no memory")
        #expect(f.manager.learningSourceSurveyRoot == nil)

        // Learned again: a new survey, and the old one's folder is retired.
        let again = await f.manager.learnSourceSurvey(root: f.google.path, now: Date().addingTimeInterval(5))
        guard case .success(let second?) = again else {
            Issue.record("learning again failed: \(again)")
            return
        }
        #expect(second.ownProfileId != id)
        #expect(!FileManager.default.fileExists(atPath: f.profiles.appendingPathComponent(id).path))
    }

    @Test func choosingTheBorrowedSurveyAndForgettingTheOwn() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        // One of three folders like the primary's: by name until it has its own.
        f.manager.resolveFilingSurvey(providerRoot: f.google.path, folders: ["Personal", "Personal/Letters", "School"])
        _ = await f.manager.learnSourceSurvey(root: f.google.path)
        let id = try #require(f.manager.filingSurveyInUse?.ownProfileId)

        f.manager.setSourceSurveyChoice(root: f.google.path, .primary)
        #expect(f.manager.filingSurveyInUse?.kind == .borrowed)
        #expect(f.manager.filingSurveyInUse?.chosen == true)
        #expect(f.manager.filingRoutingProfile?.profileId == "primary")
        #expect(f.manager.filingSurveyInUse?.ownProfileId == id, "the own survey is still there to switch back to")

        f.manager.forgetSourceSurvey(root: f.google.path)
        #expect(SourceSurveyStore.entry(forRoot: f.google.path, in: f.profiles) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.profiles.appendingPathComponent(id).path))
        #expect(f.manager.filingSurveyInUse?.kind == .byName, "back to the measured default")
    }

    /// The router index is keyed on the tree's folders, which do not move when only the survey
    /// does — so switching the survey must drop it, or the rescan reuses the index of the old one.
    @Test func switchingTheSurveyRebuildsTheRouterIndex() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let folders: Set<String> = ["Finance", "Finance/US", "School", "Other"]
        f.manager.prepareFilingRouter(destinations: folders, providerRoot: f.google.path)
        #expect(f.manager.filingSurveyInUse?.kind == .borrowed)
        let builds = f.manager.filingRouterIndexBuilds
        f.manager.prepareFilingRouter(destinations: folders, providerRoot: f.google.path)
        #expect(f.manager.filingRouterIndexBuilds == builds, "unchanged survey and tree reuse the index")

        _ = await f.manager.learnSourceSurvey(root: f.google.path)
        f.manager.prepareFilingRouter(destinations: folders, providerRoot: f.google.path)
        #expect(f.manager.filingSurveyInUse?.kind == .own)
        #expect(f.manager.filingRouterIndexBuilds == builds + 1)
    }

    @Test func learningRefusesAnEmptyOrMissingFolder() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let empty = f.base.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(await f.manager.learnSourceSurvey(root: empty.path) == .failure(.nothingToLearn(empty.path)))
        let missing = f.base.appendingPathComponent("Missing").path
        #expect(await f.manager.learnSourceSurvey(root: missing) == .failure(.unreadable(missing)))
        #expect(SourceSurveyStore.entries(in: f.profiles).isEmpty)
    }

    /// GM: Ask Claude answers a Google Drive file from Google Drive's survey and places it there;
    /// a file anywhere else from the primary.
    @Test func askClaudeFollowsTheSource() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        _ = await f.manager.learnSourceSurvey(root: f.google.path)
        let inGoogle = f.google.appendingPathComponent("Divit report card.pdf").path
        let survey = try #require(f.manager.filingHelpSurvey(for: inGoogle))
        // The survey records the folder standardised (`/var/…` for the temporary `/private/var/…`).
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let google = real(f.google.path)
        #expect(real(survey.root) == google)
        #expect(survey.memory == nil)
        let elsewhere = f.base.appendingPathComponent("Downloads/W-2.pdf").path
        #expect(f.manager.filingHelpSurvey(for: elsewhere)?.profile.profileId == "primary")

        let answer = await f.manager.whereToFile(inGoogle, snippet: nil, isHidden: { _ in false })
        if case .suggested(let s) = answer.outcome {
            #expect(!s.isEmpty && s.allSatisfy { real($0.folder).hasPrefix(google + "/") }, "placed in Google Drive")
        } else {
            Issue.record("expected a suggestion, got \(answer.outcome)")
        }

        // Chosen iCloud's for Google Drive: Ask Claude follows that too.
        f.manager.setSourceSurveyChoice(root: f.google.path, .primary)
        #expect(f.manager.filingHelpSurvey(for: inGoogle)?.profile.profileId == "primary")
    }

    /// Read Documents changes Google Drive's survey and not the primary's, so Ask Claude must rank
    /// with what the reading learned rather than the index it built from folder names alone.
    @Test func askClaudeRanksWithWhatReadingASourceLearned() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        _ = await f.manager.learnSourceSurvey(root: f.google.path)
        let id = try #require(SourceSurveyStore.entry(forRoot: f.google.path, in: f.profiles)?.profileId)
        let file = f.google.appendingPathComponent("scan.pdf").path
        let page = "fragomen petition receipt notice uscis"
        let before = await f.manager.whereToFile(file, snippet: page, isHidden: { _ in false })
        if case .suggested(let s) = before.outcome {
            #expect(s.first?.relativePath != "Work Authorization/H-1B", "premise: the folder names alone don't place it")
        }

        let memory = FilingMemory(profileId: id, salt: "s", folders: [
            "Work Authorization/H-1B": FilingMemoryEntry(docs: 4, anchors: ["fragomen", "petition", "uscis"].map {
                FilingMemoryToken(token: $0, weight: 4.0)
            }, idHashes: []),
        ])
        f.manager.recordSourceDocumentsRead(sourceRoot: f.google.path, profileId: id, memory: memory,
                                            documentsRead: 4, in: f.profiles, now: Date())
        let after = await f.manager.whereToFile(file, snippet: page, isHidden: { _ in false })
        guard case .suggested(let s) = after.outcome else { Issue.record("no suggestion after the reading: \(after)"); return }
        #expect(s.first?.relativePath == "Work Authorization/H-1B", "ranked with the index from before the reading")
    }
}
