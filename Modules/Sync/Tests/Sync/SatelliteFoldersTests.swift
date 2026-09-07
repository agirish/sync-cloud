import Foundation
import Testing
@testable import Sync

/// Folders that hold copies of another folder's documents, and the demotion that follows.
///
/// The fixtures are the real relation measured on the surveyed tree: 14 satellite folders out of
/// 3,013, found by pairing the persisted byte-hash and PDF-fingerprint indexes.
@Suite struct SatelliteFoldersTests {

    private let root = "/P"

    private func record(_ path: String, _ hex: String) -> ContentHashRecord {
        ContentHashRecord(path: "/P/" + path, mtime: 0, size: 1, hex: hex, storedAt: Date(timeIntervalSince1970: 0))
    }

    /// The reported case, at its real shape: four payslips copied into an H-1B petition packet whose
    /// originals are ten files in the salary-statement folder for the same year.
    private func payslipTree() -> DocumentIdentityIndex {
        let home = "Work/EMP/Compensation/Salary Statements/2026/"
        let stash = "Immigration/Authorization/H-1B/2026-2029/Petition/Supporting Documents/pay_statements/"
        var fps = (1...10).map { record(home + "\($0). doc.pdf", "pay\($0)") }
        fps += (1...4).map { record(stash + "Payslip_\($0).pdf", "pay\($0)") }
        return DocumentIdentityIndex.build(hashes: [], fingerprints: fps,
                                           providerRoot: root, existsOnDisk: { _ in true })
    }

    private func homes(_ index: DocumentIdentityIndex,
                       accepts: @escaping (String) -> Bool = { _ in true }) -> [String: Set<String>] {
        SatelliteFolders.homesBySatellite(in: index, accepts: accepts)
    }

    // MARK: Identity

    @Test("A PDF's text digest wins over its byte hash")
    func fingerprintWinsForPDFs() {
        // The whole reason the relation can see anything: a provider re-stamps a fresh `/ID` into
        // every download, so the copy and the original share no bytes at all. Here they disagree —
        // different byte hashes, one fingerprint — and only the fingerprint reading pairs them.
        let index = DocumentIdentityIndex.build(
            hashes: [record("A/x.pdf", "bytes1"), record("B/y.pdf", "bytes2")],
            fingerprints: [record("A/x.pdf", "same"), record("B/y.pdf", "same")],
            providerRoot: root, existsOnDisk: { _ in true })
        #expect(index.foldersByIdentity["f:same"] == ["A", "B"])
        #expect(index.foldersByIdentity["b:bytes1"] == nil)
        // Non-vacuity: a file with no fingerprint keeps its byte identity.
        let bytesOnly = DocumentIdentityIndex.build(
            hashes: [record("A/x.pdf", "bytes1")], fingerprints: [],
            providerRoot: root, existsOnDisk: { _ in true })
        #expect(bytesOnly.foldersByIdentity["b:bytes1"] == ["A"])
    }

    @Test("A path with two records is read at its newest, whatever order they arrive in")
    func supersededRecordsLoseToTheNewest() {
        // An index is an append-only log keyed by (path, mtime, size): editing a file adds a second
        // record and the old one survives for 30 days. They reach `build` in the order
        // `ContentHashCache.save` happened to enumerate its dictionary — arbitrary, and reseeded
        // every launch — so reading them straight into a map made the file's identity depend on the
        // hash seed. Measured on the real index: 13 paths under the provider root carry two records
        // with different digests.
        //
        // Both orderings are run because ONE ordering is what a fixture would accidentally pin: the
        // buggy "last wins" agrees with the fix on whichever order puts the newest last.
        func index(_ recs: [ContentHashRecord]) -> DocumentIdentityIndex {
            DocumentIdentityIndex.build(hashes: recs, fingerprints: [],
                                        providerRoot: root, existsOnDisk: { _ in true })
        }
        let stale = ContentHashRecord(path: "/P/A/x.pdf", mtime: 100, size: 1, hex: "old",
                                      storedAt: Date(timeIntervalSince1970: 1_000))
        let fresh = ContentHashRecord(path: "/P/A/x.pdf", mtime: 200, size: 2, hex: "new",
                                      storedAt: Date(timeIntervalSince1970: 2_000))
        for (label, recs) in [("newest last", [stale, fresh]), ("newest first", [fresh, stale])] {
            let built = index(recs)
            #expect(built.foldersByIdentity["b:new"] == ["A"], "\(label): the newest digest is the file's identity")
            #expect(built.foldersByIdentity["b:old"] == nil, "\(label): the superseded digest identifies nothing")
            // Counted once, not once per record. This half always held — the map is keyed by path
            // — and is pinned here so the de-duplication cannot be lost while fixing the ordering.
            #expect(built.documentCounts["A"] == 1, "\(label)")
        }
    }

    @Test("A record whose file is gone does not vouch for anything")
    func staleRecordsAreDropped() {
        // The indexes are a cache and outlive what they describe. A stale record would both invent
        // a holder for a document and inflate the count that decides which folder is established.
        let index = DocumentIdentityIndex.build(
            hashes: [record("A/x.pdf", "h"), record("B/gone.pdf", "h")], fingerprints: [],
            providerRoot: root, existsOnDisk: { !$0.hasSuffix("gone.pdf") })
        #expect(index.foldersByIdentity["b:h"] == ["A"])
        #expect(index.documentCounts["B"] == nil)
    }

    @Test("Only files under the provider root are read")
    func foreignPathsIgnored() {
        let index = DocumentIdentityIndex.build(
            hashes: [record("A/x.pdf", "h"),
                     ContentHashRecord(path: "/Elsewhere/A/x.pdf", mtime: 0, size: 1, hex: "h",
                                       storedAt: Date(timeIntervalSince1970: 0))],
            fingerprints: [], providerRoot: root, existsOnDisk: { _ in true })
        #expect(index.foldersByIdentity["b:h"] == ["A"])
    }

    // MARK: The relation

    @Test("The petition's copy stash is a satellite of the salary folder")
    func findsTheReportedCase() {
        let stash = "Immigration/Authorization/H-1B/2026-2029/Petition/Supporting Documents/pay_statements"
        let home = "Work/EMP/Compensation/Salary Statements/2026"
        let found = homes(payslipTree())
        #expect(found[stash] == [home])
        // **Directional.** The home is not also a satellite of the stash, which is the entire point
        // — a relation that fired both ways would be a statement that they are duplicates of each
        // other and would give the ranking no reason to prefer either.
        #expect(found[home] == nil)
    }

    @Test("An inbox is never a home")
    func inboxesAreNotHomes() {
        // Without this the relation reads backwards on the real tree: the biggest folder in a family
        // is routinely the pile everything was filed OUT of. `Credit 2809/2024` came out a satellite
        // of `Chase/TODO` (47 documents) — a real home demoted in favour of its own inbox.
        var fps = (1...12).map { record("Finance/Chase/TODO/s\($0).pdf", "st\($0)") }
        fps += (1...4).map { record("Finance/Chase/Credit 2809/2024/s\($0).pdf", "st\($0)") }
        let index = DocumentIdentityIndex.build(hashes: [], fingerprints: fps,
                                                providerRoot: root, existsOnDisk: { _ in true })
        // The relation is there on the numbers alone …
        let unguarded: Set<String>? = homes(index)["Finance/Chase/Credit 2809/2024"]
        #expect(unguarded == ["Finance/Chase/TODO"])
        // … and the profile's own rule is what refuses it.
        #expect(homes(index, accepts: { !FolderProfile.isInboxPath($0) }).isEmpty)
    }

    @Test("Two folders that merely overlap are not a satellite pair")
    func nearTiesAreRefused() {
        // At a 1.01x size rule the tree produced `Papers/SQL` (3 docs) inside `Papers/Data
        // Analytics` (4) and `Checking 5670/2016` (6) inside `Savings 3931/2016` (7) — pairs where
        // "bigger" carries no information and the direction is arbitrary.
        var fps = (1...4).map { record("Papers/Data Analytics/p\($0).pdf", "p\($0)") }
        fps += (1...3).map { record("Papers/SQL/p\($0).pdf", "p\($0)") }
        let index = DocumentIdentityIndex.build(hashes: [], fingerprints: fps,
                                                providerRoot: root, existsOnDisk: { _ in true })
        #expect(homes(index).isEmpty)
        // Non-vacuity: the same shape with the home twice the size IS a satellite pair, so the
        // emptiness above is the ratio rule and not the fixture failing to overlap at all.
        var bigger = (1...6).map { record("Papers/Data Analytics/p\($0).pdf", "p\($0)") }
        bigger += (1...3).map { record("Papers/SQL/p\($0).pdf", "p\($0)") }
        let withRoom = homes(DocumentIdentityIndex.build(hashes: [], fingerprints: bigger,
                                                         providerRoot: root, existsOnDisk: { _ in true }))
        #expect(withRoom["Papers/SQL"] == ["Papers/Data Analytics"])
    }

    @Test("Two shared documents are not evidence, however small the folder")
    func needsThreeSharedDocuments() {
        var fps = (1...10).map { record("Home/Big/d\($0).pdf", "d\($0)") }
        fps += (1...2).map { record("Home/Small/d\($0).pdf", "d\($0)") }
        let index = DocumentIdentityIndex.build(hashes: [], fingerprints: fps,
                                                providerRoot: root, existsOnDisk: { _ in true })
        #expect(homes(index).isEmpty)
    }

    // MARK: The demotion

    @Test("The home outranks its copy stash, and the stash stays on the card")
    func demotesTheSatellite() {
        let stash = "Immigration/Authorization/H-1B/2026-2029/Petition/Supporting Documents/pay_statements"
        let home = "Work/EMP/Compensation/Salary Statements/2026"
        // A memory in which the stash genuinely scores higher — which is what the real one does,
        // because it learned the anchor `payslip` from the filenames the copies were saved under.
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            stash: FilingMemoryEntry(docs: 4, anchors: [FilingMemoryToken(token: "payslip", weight: 6),
                                                         FilingMemoryToken(token: "salary", weight: 4)],
                                      idHashes: []),
            home: FilingMemoryEntry(docs: 4, anchors: [FilingMemoryToken(token: "salary", weight: 4)],
                                     idHashes: []),
        ])
        func rank(satellites: [String: Set<String>]) -> FilingRouter.Ranking {
            let index = FilingRouter.makeIndex(destinations: [stash, home], profile: nil,
                                               memory: memory, satelliteHomes: satellites)
            return FilingRouter.rank(fileName: "Payslip_2026-06-15.pdf",
                                     contentSnippet: "payslip salary", index: index)
        }
        // Without the relation the stash leads — the defect, reproduced.
        #expect(rank(satellites: [:]).best?.relativePath == stash)
        // With it the home leads …
        let demoted = rank(satellites: [stash: [home]])
        #expect(demoted.best?.relativePath == home)
        // … and the stash is still offered, one click away. A removal would make the relation a
        // veto on ever filing a document into a petition packet again, which it is not.
        #expect(demoted.candidates.contains { $0.relativePath == stash })
    }

    @Test("A satellite whose home is not in play keeps its place")
    func onlyFiresWhenBothAreCandidates() {
        let stash = "Immigration/Petition/pay_statements"
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            stash: FilingMemoryEntry(docs: 4, anchors: [FilingMemoryToken(token: "payslip", weight: 6)],
                                      idHashes: []),
        ])
        // The home is named by the relation but is not a destination here, so nothing displaces the
        // satellite and it remains the answer — a document really can belong in a petition packet.
        let index = FilingRouter.makeIndex(destinations: [stash], profile: nil, memory: memory,
                                           satelliteHomes: [stash: ["Work/EMP/Salary"]])
        let r = FilingRouter.rank(fileName: "Payslip.pdf", contentSnippet: "payslip", index: index)
        #expect(r.best?.relativePath == stash)
    }

    @Test("A verdict naming a satellite is refused when the home is on the card")
    func verdictCannotUndoTheDemotion() {
        // The router demotes, but the model re-ranks the shortlist afterwards and the satellite is
        // *in* that shortlist — so without this the refine pass hands the wrong answer straight
        // back. Measured: asked where `Payslip_2026-06-15.pdf` belonged, the backend answered the
        // petition stash at High confidence.
        let stash = "Immigration/Petition/pay_statements"
        let home = "Work/EMP/Salary Statements/2026"
        let suggestion = FilingSuggestion(
            filePath: "/P/TODO/Payslip.pdf", fileName: "Payslip.pdf", size: 1,
            modificationDate: nil,
            candidates: [FilingDestination(path: "/P/" + home, confidence: .low,
                                           reasons: [], newSegments: [])],
            providerRoot: "/P")
        let verdict = FilingVerdict(relativePath: stash, confidence: .high, reason: "looks like a payslip")
        // Every ancestor, not just the two leaves: `destination(from:)` walks the path and calls
        // any segment missing from this set a folder to CREATE — which, for a verdict that does not
        // declare a new folder, trims the answer back to its existing prefix. A set of two leaves
        // makes the control leg pass for the wrong reason.
        let existing: Set<String> = [
            "Immigration", "Immigration/Petition", stash,
            "Work", "Work/EMP", "Work/EMP/Salary Statements", home,
        ]
        func applied(satellites: [String: Set<String>]) -> String? {
            FilingEngine.applyVerdicts(["/P/TODO/Payslip.pdf": verdict], to: [suggestion],
                                       existingRelative: existing, providerRoot: "/P",
                                       satelliteHomes: satellites).first?.best?.path
        }
        // Without the rule the verdict wins — the defect, reproduced through the real entry point.
        #expect(applied(satellites: [:]) == "/P/" + stash)
        // With it the card keeps the home it already had.
        #expect(applied(satellites: [stash: [home]]) == "/P/" + home)
    }
}
