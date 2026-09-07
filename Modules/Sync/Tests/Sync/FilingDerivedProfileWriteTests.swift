import Foundation
import Testing
@testable import Sync

/// §5.5 step 6's store half: the derived-profile write that may re-point `profiles.json` away
/// from a hand-built profile — the one thing `writeProfile` must never do — licensed by the
/// provenance chain in the file, plus the two fields the chain and the carry-over ride on.
@Suite struct FilingDerivedProfileWriteTests {

    private static func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fdpw-\(UUID().uuidString)")
    }

    private static func profile(id: String, derivedFrom: String? = nil,
                                builtBy: String? = nil) -> FolderProfile {
        FolderProfile(
            profileId: id, root: "~/Documents",
            folders: [
                "Finance": FolderProfileEntry(path: "Finance", role: .container, naming: nil,
                                              anchors: [], acceptsNewFiles: nil, fileCount: 0,
                                              subfolderCount: 1, axes: [:]),
                "Finance/Outbound": FolderProfileEntry(
                    path: "Finance/Outbound", role: nil, naming: "ordinal-month", anchors: [],
                    acceptsNewFiles: false, noIntakeReason: "outbound-pack",
                    fileCount: 3, subfolderCount: 0, axes: ["jurisdiction": "Singapore"]),
            ],
            personTokens: [], builtBy: builtBy, derivedFrom: derivedFrom)
    }

    /// Writes a HAND-BUILT profile (no `builtBy`) and makes it active — the state every apply on
    /// this machine starts from.
    private static func handBuiltActive(in dir: URL, id: String = "father") throws {
        try FilingProfileStore.writeProfile(Self.profile(id: id), in: dir,
                                            builtBy: "hand — offline generator")
        // `writeProfile` stamps builtBy from its parameter, so the file reads hand-built; the
        // index now names it.
        #expect(FilingProfileStore.activeProfileId(in: dir) == id)
        #expect(FilingProfileStore.profile(id: id, in: dir)?.provenance == .handBuilt)
    }

    // MARK: - The two fields

    /// `noIntakeReason` and `derivedFrom` round-trip through the real writer and the real decoder
    /// — the hand-built profile carries 45 of the former, and losing the WHY on a carried refusal
    /// is what the field exists to prevent.
    @Test func theRefusalReasonAndTheProvenanceChainRoundTrip() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStore.writeProfile(Self.profile(id: "p1", derivedFrom: "p0"), in: dir)

        let read = try #require(FilingProfileStore.profile(id: "p1", in: dir))
        #expect(read.derivedFrom == "p0")
        let entry = try #require(read.folders["Finance/Outbound"])
        #expect(entry.noIntakeReason == "outbound-pack")
        #expect(entry.acceptsNewFiles == false)
        #expect(entry.naming == "ordinal-month")
    }

    // MARK: - The derived write

    /// The whole point: it re-points away from a HAND-BUILT active profile — with the old file
    /// byte-identical afterwards, because "never lose what exists" is what the create-only guard
    /// was protecting all along.
    @Test func itRePointsAwayFromAHandBuiltProfileAndLeavesTheOldFileAlone() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        let oldBytes = try Data(contentsOf: FilingProfileStore.profileURL(id: "father", in: dir))

        try FilingProfileStore.writeDerivedProfile(
            Self.profile(id: "father-r1", derivedFrom: "father"),
            replacing: "father", in: dir)

        #expect(FilingProfileStore.activeProfileId(in: dir) == "father-r1")
        #expect(try Data(contentsOf: FilingProfileStore.profileURL(id: "father", in: dir))
                == oldBytes, "the old file is what Undo re-points to — it must not move")
        let derived = try #require(FilingProfileStore.profile(id: "father-r1", in: dir))
        #expect(derived.derivedFrom == "father")
        #expect(derived.provenance == .derived, "the derived write stamps its own builtBy")
    }

    /// The licence is the claim being TRUE: a `replacing` id that is not the active one is an
    /// apply that raced a profile switch, and it stops rather than re-pointing away from a
    /// profile it never read. A missing chain is its OWN refusal, naming its own facts — the
    /// first spelling filled the raced-switch case's `active:` with the profile's parent, so
    /// "the active profile is none" was wrong on both counts.
    @Test func aWrongClaimOrAMissingChainRefusesTheWholeWrite() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)

        #expect(throws: FilingProfileStore.WriteRefusal.notReplacingTheActiveProfile(
            claimed: "somebody-else", active: "father")) {
            try FilingProfileStore.writeDerivedProfile(
                Self.profile(id: "r1", derivedFrom: "somebody-else"),
                replacing: "somebody-else", in: dir)
        }
        #expect(throws: FilingProfileStore.WriteRefusal.chainMissing(
            derivedFrom: nil, claimed: "father")) {
            try FilingProfileStore.writeDerivedProfile(
                Self.profile(id: "r1", derivedFrom: nil), replacing: "father", in: dir)
        }
        // Nothing landed and nothing moved.
        #expect(FilingProfileStore.activeProfileId(in: dir) == "father")
        #expect(FilingProfileStore.profile(id: "r1", in: dir) == nil)
    }

    /// The never-overwrite guard did not weaken: a derived id that already exists refuses,
    /// exactly as `writeProfile` does.
    @Test func anExistingDerivedIdStillRefuses() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try FilingProfileStore.writeDerivedProfile(
            Self.profile(id: "r1", derivedFrom: "father"), replacing: "father", in: dir)

        // A second apply must mint a fresh id; re-using one is refused with the file untouched.
        #expect(throws: FilingProfileStore.WriteRefusal.profileExists(id: "r1")) {
            try FilingProfileStore.writeDerivedProfile(
                Self.profile(id: "r1", derivedFrom: "r1"), replacing: "r1", in: dir)
        }
    }

    // MARK: - The re-point back

    /// Undo's half: the inverse ran, and the profile recorded as `derivedFrom` becomes active
    /// again — the old file was kept for exactly this.
    @Test func rePointingBackRestoresTheOldProfileAsActive() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try FilingProfileStore.writeDerivedProfile(
            Self.profile(id: "r1", derivedFrom: "father"), replacing: "father", in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "r1")

        try FilingProfileStore.repointActiveProfile(to: "father", in: dir)

        #expect(FilingProfileStore.activeProfileId(in: dir) == "father")
        // Both files still on disk — the chain is history, not a swap.
        #expect(FilingProfileStore.profile(id: "r1", in: dir) != nil)

        // And a target with no file refuses rather than writing a dangling pointer.
        #expect(throws: FilingProfileStore.WriteRefusal.self) {
            try FilingProfileStore.repointActiveProfile(to: "ghost", in: dir)
        }
    }

    // MARK: - What the index row says about a derived profile

    /// **A re-derivation inherits the identity of the profile it replaces.**
    ///
    /// `amendedIndex` wrote five fields and no more, on the stated ground that "a folder walk does
    /// not know the person's name, and an absent field reads as unknown while a guessed one reads
    /// as a fact". That is right about a FIRST profile and wrong about a re-derivation: the tree
    /// has already been identified, and the answer is sitting in the row being superseded. Written
    /// as it was, one press of "Update the survey" turned `Father / iCloud Drive (Desktop &
    /// Documents sync) / 12280 files` into a nameless row — and every later press inherited the
    /// nothing, so his live index ended up with four anonymous profiles.
    @Test func aDerivedProfileInheritsTheNameAndProviderItWasDerivedFrom() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)

        // Give the active row the two fields the offline generator writes.
        let indexURL = dir.appendingPathComponent("profiles.json")
        var object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: indexURL)) as? [String: Any])
        var rows = try #require(object["profiles"] as? [[String: Any]])
        rows[0]["displayName"] = "Father"
        rows[0]["provider"] = "iCloud Drive (Desktop & Documents sync)"
        object["profiles"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: indexURL)

        _ = try FilingProfileStore.writeDerivedProfile(
            Self.profile(id: "reorg-1", derivedFrom: "father"), replacing: "father", in: dir)

        let after = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: indexURL)) as? [String: Any])
        let listed = try #require(after["profiles"] as? [[String: Any]])
        let derived = try #require(listed.first { $0["profileId"] as? String == "reorg-1" })
        #expect(derived["displayName"] as? String == "Father",
                "the re-derived profile lost the name of the tree it describes")
        #expect(derived["provider"] as? String == "iCloud Drive (Desktop & Documents sync)",
                "the re-derived profile lost its provider")
        // The counts are the NEW survey's own, never inherited — they are what changed.
        #expect(derived["surveyedFolders"] as? Int == 2)
        #expect(derived["surveyedFiles"] as? Int == 3, "the file total is summed from the walk")
        // And the parent row is untouched, so the chain Undo reads still reads.
        let parent = try #require(listed.first { $0["profileId"] as? String == "father" })
        #expect(parent["displayName"] as? String == "Father")
    }

    /// A first profile still gets no invented name. The rule above inherits from a row that
    /// exists; with nothing to inherit from, absent stays absent rather than becoming a guess.
    @Test func aFirstProfileStillCarriesNoInventedName() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingProfileStore.writeProfile(Self.profile(id: "p1"), in: dir)

        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("profiles.json"))) as? [String: Any])
        let rows = try #require(object["profiles"] as? [[String: Any]])
        let row = try #require(rows.first { $0["profileId"] as? String == "p1" })
        #expect(row["displayName"] == nil, "a walk that knows no name must not write one")
    }

    // MARK: - Retiring what a re-derivation superseded

    /// Writes a derived profile over the active one, the way a re-derivation does.
    @discardableResult
    private static func derive(_ id: String, from parent: String, in dir: URL) throws -> URL {
        try FilingProfileStore.writeDerivedProfile(
            Self.profile(id: id, derivedFrom: parent,
                         builtBy: FolderProfile.derivedBuiltByPrefix + " test"),
            replacing: parent, in: dir)
    }

    private static func ids(in dir: URL) throws -> [String] {
        let o = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("profiles.json"))) as? [String: Any])
        let rows = try #require(o["profiles"] as? [[String: Any]])
        return rows.compactMap { $0["profileId"] as? String }.sorted()
    }

    /// **The whole point: a chain of re-derivations collapses to the active one.** Eight profiles
    /// and 90 MB accumulated in one evening because `writeDerivedProfile(replacing:)`'s
    /// "replacing" only ever asserted which id was active — it retired nothing.
    @Test func retiringLeavesOnlyTheActiveProfileAndTheHandBuiltRoot() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try Self.derive("d1", from: "father", in: dir)
        try Self.derive("d2", from: "d1", in: dir)
        try Self.derive("d3", from: "d2", in: dir)
        #expect(try Self.ids(in: dir) == ["d1", "d2", "d3", "father"])

        let retired = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: dir)
        #expect(retired == ["d1", "d2"])
        #expect(try Self.ids(in: dir) == ["d3", "father"])
        // The directories are gone, not merely unlisted.
        for gone in ["d1", "d2"] {
            #expect(!FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(gone).path), "\(gone) survived on disk")
        }
        #expect(FilingProfileStore.activeProfileId(in: dir) == "d3")
        #expect(FilingProfileStore.profile(id: "d3", in: dir) != nil)
    }

    /// **A hand-built profile is never retired**, even unprotected and inactive. It is the one
    /// artifact the app cannot rebuild, and `provenance` answers `handBuilt` for an absent or
    /// unrecognised `builtBy` — the safe default by construction.
    @Test func aHandBuiltProfileIsNeverRetired() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try Self.derive("d1", from: "father", in: dir)

        let retired = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: dir)
        #expect(retired.isEmpty, "nothing was superseded but the hand-built root")
        #expect(try Self.ids(in: dir) == ["d1", "father"])
        #expect(FilingProfileStore.profile(id: "father", in: dir)?.provenance == .handBuilt)
    }

    /// **What the caller protects survives** — the ledger pins the profile a landing was applied
    /// under, because Undo re-points at it and `repointActiveProfile` needs it on disk.
    @Test func aProtectedProfileSurvivesEvenThoughItIsSuperseded() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try Self.derive("d1", from: "father", in: dir)
        try Self.derive("d2", from: "d1", in: dir)
        try Self.derive("d3", from: "d2", in: dir)

        let retired = try FilingProfileStore.retireSupersededProfiles(protecting: ["d1"], in: dir)
        #expect(retired == ["d2"])
        #expect(try Self.ids(in: dir) == ["d1", "d3", "father"])
        // And the protected one is still re-pointable, which is the whole reason it was pinned.
        try FilingProfileStore.repointActiveProfile(to: "d1", in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "d1")
    }

    /// The active profile is read from the INDEX, not taken from the caller — so a caller that
    /// has drifted cannot talk this into deleting the tree the app is currently reading.
    @Test func theActiveProfileIsNeverRetiredEvenIfTheCallerForgetsIt() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try Self.derive("d1", from: "father", in: dir)

        // `protecting: []` names nothing at all, d1 is derived, and it still survives.
        _ = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "d1")
        #expect(FilingProfileStore.profile(id: "d1", in: dir) != nil)
    }

    /// A row whose directory has already gone is pruned rather than skipped. Without this an
    /// interrupted sweep would strand that row for good: `profile(id:)` returns nil for it, so
    /// the "is it derived?" test could never pass again.
    @Test func aRowWhoseDirectoryIsAlreadyGoneIsPruned() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try Self.derive("d1", from: "father", in: dir)
        try Self.derive("d2", from: "d1", in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("d1"))

        let retired = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: dir)
        #expect(retired == ["d1"])
        #expect(try Self.ids(in: dir) == ["d2", "father"])
    }

    /// Retiring is idempotent — a second sweep with nothing left to do reports nothing and
    /// rewrites nothing it should not.
    @Test func asecondSweepIsANoOp() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try Self.derive("d1", from: "father", in: dir)
        try Self.derive("d2", from: "d1", in: dir)

        #expect(try FilingProfileStore.retireSupersededProfiles(protecting: [], in: dir) == ["d1"])
        #expect(try FilingProfileStore.retireSupersededProfiles(protecting: [], in: dir).isEmpty)
        #expect(try Self.ids(in: dir) == ["d2", "father"])
    }

    // MARK: - The provenance probe

    /// **The sweep now reads the header, not the whole profile — and the two must AGREE.**
    ///
    /// `retireSupersededProfiles` used to fully decode every candidate (3,013 folder entries,
    /// each with its axes and its lenient retry) to read one string, on the main actor, in the
    /// middle of a landing. `provenance(id:in:)` reads only `builtBy`. This is the equivalence
    /// that makes the swap safe: the two must answer the same for every shape a profile file can
    /// take, because a disagreement in the *derived* direction is a directory deleted on a
    /// weaker reading than the old code required.
    @Test func theProvenanceProbeAgreesWithTheFullDecode() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.handBuiltActive(in: dir)
        try Self.derive("d1", from: "father", in: dir)

        for id in ["father", "d1"] {
            #expect(FilingProfileStore.provenance(id: id, in: dir)
                        == FilingProfileStore.profile(id: id, in: dir)?.provenance,
                    "\(id): the probe and the full decode disagree")
        }

        // Hand-written shapes the sweep can actually meet, each checked against the full decode.
        func write(_ id: String, _ json: String) throws {
            let folder = dir.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: folder.appendingPathComponent("folder-profile.json"))
        }
        // No header at all — the pre-`builtBy` profiles, which are exactly the hand-built ones.
        try write("no-header", #"{"profileId":"no-header","root":"~"}"#)
        // A header of the wrong TYPE: costs the file its provenance, never its readability.
        try write("bad-header", #"{"profileId":"x","builtBy":42,"root":"~"}"#)
        // Someone else's marker.
        try write("foreign", #"{"profileId":"x","builtBy":"a hand edit","root":"~"}"#)
        // The app's own, with the version suffix the prefix match exists to tolerate.
        try write("ours", #"{"profileId":"x","builtBy":"SyncCloud — folder survey 5.2"}"#)
        // Not an object at all: unreadable to both, and unreadable is never disposable.
        try write("array", "[1,2,3]")
        try write("junk", "not json")

        for id in ["no-header", "bad-header", "foreign", "ours", "array", "junk"] {
            #expect(FilingProfileStore.provenance(id: id, in: dir)
                        == FilingProfileStore.profile(id: id, in: dir)?.provenance,
                    "\(id): the probe and the full decode disagree")
        }
        // And the answers themselves, spelled out — an equivalence between two functions that
        // are both wrong is still an equivalence.
        #expect(FilingProfileStore.provenance(id: "ours", in: dir) == .derived)
        #expect(FilingProfileStore.provenance(id: "no-header", in: dir) == .handBuilt)
        #expect(FilingProfileStore.provenance(id: "bad-header", in: dir) == .handBuilt)
        #expect(FilingProfileStore.provenance(id: "foreign", in: dir) == .handBuilt)
        #expect(FilingProfileStore.provenance(id: "array", in: dir) == nil)
        #expect(FilingProfileStore.provenance(id: "junk", in: dir) == nil)
        #expect(FilingProfileStore.provenance(id: "absent", in: dir) == nil)
    }

    /// A profile file that is a JSON object but whose folder list is rubbish stays retirable
    /// exactly as before — the full decoder salvages it, so the probe must not be stricter.
    @Test func theProbeIsNoStricterThanTheLenientDecoder() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try Self.derive("d1", from: "father", in: dir)
        try Self.derive("d2", from: "d1", in: dir)
        // d1's folder list carries an entry with a role no build knows and one that is not an
        // object at all — both salvaged by `FolderProfile`'s decoder, neither seen by the probe.
        let url = FilingProfileStore.profileURL(id: "d1", in: dir)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                                    as? [String: Any])
        object["folders"] = [["path": "Odd", "role": "a-role-from-the-future"], "nonsense"]
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        #expect(FilingProfileStore.provenance(id: "d1", in: dir)
                    == FilingProfileStore.profile(id: "d1", in: dir)?.provenance)
        #expect(try FilingProfileStore.retireSupersededProfiles(protecting: [], in: dir) == ["d1"])
    }
}
