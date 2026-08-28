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
    private static func handBuiltActive(in dir: URL, id: String = "abhishek") throws {
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
        let oldBytes = try Data(contentsOf: FilingProfileStore.profileURL(id: "abhishek", in: dir))

        try FilingProfileStore.writeDerivedProfile(
            Self.profile(id: "abhishek-r1", derivedFrom: "abhishek"),
            replacing: "abhishek", in: dir)

        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek-r1")
        #expect(try Data(contentsOf: FilingProfileStore.profileURL(id: "abhishek", in: dir))
                == oldBytes, "the old file is what Undo re-points to — it must not move")
        let derived = try #require(FilingProfileStore.profile(id: "abhishek-r1", in: dir))
        #expect(derived.derivedFrom == "abhishek")
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
            claimed: "somebody-else", active: "abhishek")) {
            try FilingProfileStore.writeDerivedProfile(
                Self.profile(id: "r1", derivedFrom: "somebody-else"),
                replacing: "somebody-else", in: dir)
        }
        #expect(throws: FilingProfileStore.WriteRefusal.chainMissing(
            derivedFrom: nil, claimed: "abhishek")) {
            try FilingProfileStore.writeDerivedProfile(
                Self.profile(id: "r1", derivedFrom: nil), replacing: "abhishek", in: dir)
        }
        // Nothing landed and nothing moved.
        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek")
        #expect(FilingProfileStore.profile(id: "r1", in: dir) == nil)
    }

    /// The never-overwrite guard did not weaken: a derived id that already exists refuses,
    /// exactly as `writeProfile` does.
    @Test func anExistingDerivedIdStillRefuses() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.handBuiltActive(in: dir)
        try FilingProfileStore.writeDerivedProfile(
            Self.profile(id: "r1", derivedFrom: "abhishek"), replacing: "abhishek", in: dir)

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
            Self.profile(id: "r1", derivedFrom: "abhishek"), replacing: "abhishek", in: dir)
        #expect(FilingProfileStore.activeProfileId(in: dir) == "r1")

        try FilingProfileStore.repointActiveProfile(to: "abhishek", in: dir)

        #expect(FilingProfileStore.activeProfileId(in: dir) == "abhishek")
        // Both files still on disk — the chain is history, not a swap.
        #expect(FilingProfileStore.profile(id: "r1", in: dir) != nil)

        // And a target with no file refuses rather than writing a dangling pointer.
        #expect(throws: FilingProfileStore.WriteRefusal.self) {
            try FilingProfileStore.repointActiveProfile(to: "ghost", in: dir)
        }
    }
}
