import Foundation
import Testing
@testable import Sync

/// Each folder Setup walks keeps its own Restructure history (FR4, follow-up).
///
/// A walk of another folder used to carry the old folder's `restructure.json` across, so its
/// path-keyed suppressions, answers and drafts applied to a different tree. Now the folder left is
/// recorded in `restructure-roots.json`, the new folder starts its own ledger (or takes up the one
/// it had), and the retire sweep keeps what a walk back needs. Real temp folders throughout: the
/// rules compare folders through links and by containment, which only a real disk answers.
@MainActor
@Suite struct RestructureRootHistoryTests {

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func tree(in root: URL) throws {
        for path in ["Tax", "Tax/Forms", "Finance", "Finance/Receipts", "Family/Mother"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("Finance/Receipts/2024 receipt.pdf"),
                      atomically: true, encoding: .utf8)
    }

    private static func time(_ step: Int) -> Date { Date(timeIntervalSince1970: 1_754_000_000 + Double(step) * 600) }

    private static let forms = RestructureKey(kind: .shape, path: "Tax/Forms")
    private static let receipts = RestructureKey(kind: .echoName, path: "Finance/Receipts")

    private func walk(_ manager: FileSyncManager, _ root: URL, at step: Int) async throws -> String {
        let report = try #require(try? (await manager.deriveFolderProfile(
            root: root, now: Self.time(step))).get())
        try #require(report.becameActive)
        return report.profileId
    }

    /// A finished landing in `id`'s ledger, applied under `under`, at `step` (plus a minute).
    private static func land(_ id: String, under: String, at step: Int, in profiles: URL,
                             manifestId: String = "landing-1") throws {
        let at = FilingProfileStore.stamp(time(step).addingTimeInterval(60))
        let manifest = RestructureManifest(profileId: under, manifestId: manifestId,
                                           createdAt: at, family: "Tax", kind: .shape, actions: [])
        try #require(RestructureStore(directory: profiles, profileId: id).recordApplied(
            .init(manifest: manifest, inverse: manifest, at: at, created: 0, skipped: 0,
                  appliedUnderProfileId: under, producedProfileId: id, summary: "1 moved")))
    }

    private static func ledger(_ id: String, _ profiles: URL) -> RestructureStore {
        RestructureStore(directory: profiles, profileId: id)
    }

    private func manager(_ profiles: URL) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingProfilesDirectory = profiles
        return m
    }

    // MARK: - A → B

    /// Walking another folder starts that folder's own ledger: the first folder's suppression does
    /// not reach it. The first folder's history survives a sweep while the second is active, and
    /// so does the profile its landing was applied under — a walk back re-points Undo at it.
    @Test func anotherFolderStartsItsOwnHistoryAndTheFirstOneIsKept() async throws {
        let a = try Self.scratch(), b = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [a, b, profiles] { try? FileManager.default.removeItem(at: url) } }
        try Self.tree(in: a)
        try Self.tree(in: b)
        let m = manager(profiles)
        let stale = try await walk(m, a, at: 0)
        let a0 = try await walk(m, a, at: 1)
        let a1 = try await walk(m, a, at: 2)
        Self.ledger(a1, profiles).suppress(Self.forms)
        try Self.land(a1, under: a0, at: 2, in: profiles)

        let b0 = try await walk(m, b, at: 3)

        let bLedger = profiles.appendingPathComponent("\(b0)/restructure.json")
        #expect(FileManager.default.fileExists(atPath: bLedger.path),
                "the new folder has no ledger of its own, so the sweep keeps every old folder")
        let fresh = Self.ledger(b0, profiles)
        #expect(!fresh.isSuppressed(Self.forms), "the first folder's suppression reached the second")
        #expect(fresh.applied.isEmpty)

        let retired = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: profiles)
        #expect(retired == [stale], "the sweep should take only the folder nothing needs")
        #expect(FilingProfileStore.profile(id: a1, in: profiles) != nil,
                "the first folder's history was retired while the second was active")
        #expect(FilingProfileStore.profile(id: a0, in: profiles) != nil,
                "the profile the first folder's landing was applied under was retired")
    }

    // MARK: - The person verdicts

    /// The verdicts are keyed by paths in the folder walked (review R2), so they follow the
    /// folder as the ledger does: another folder starts with none — and with a file of its own,
    /// so the old folder is not stranded — and walking back takes them up again. A folder whose
    /// only history is a verdict is still kept for the walk back.
    @Test func theVerdictsFollowTheFolderTheyWereMadeIn() async throws {
        let a = try Self.scratch(), b = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [a, b, profiles] { try? FileManager.default.removeItem(at: url) } }
        try Self.tree(in: a)
        try Self.tree(in: b)
        let m = manager(profiles)
        let receipt = "Finance/Receipts/2024 receipt.pdf"
        let a0 = try await walk(m, a, at: 0)
        PersonTagStore(directory: profiles, profileId: a0)
            .record(personId: "mum", key: .path(receipt), verdict: .confirmed, path: receipt)

        let b0 = try await walk(m, b, at: 1)

        let tagsFile = profiles.appendingPathComponent("\(b0)/person-tags.json")
        #expect(FileManager.default.fileExists(atPath: tagsFile.path),
                "the new folder has no verdict file, so the old folder is kept as the only copy")
        #expect(PersonTagStore(directory: profiles, profileId: b0).tags.isEmpty,
                "a verdict on a file in the first folder reached the file of that name in the second")
        _ = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: profiles)
        #expect(FilingProfileStore.profile(id: a0, in: profiles) != nil,
                "the folder holding the first folder's verdicts was retired")

        let a1 = try await walk(m, a, at: 2)
        #expect(PersonTagStore(directory: profiles, profileId: a1).index
                    .verdict(personId: "mum", path: receipt) == .confirmed,
                "the folder's verdict did not come back")
    }

    // MARK: - A → B → A

    /// Walking back takes the first folder's history up again — suppression, draft and landing —
    /// and its Undo is offered from the new profile.
    @Test func walkingBackTakesTheFolderHistoryUpAgain() async throws {
        let a = try Self.scratch(), b = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [a, b, profiles] { try? FileManager.default.removeItem(at: url) } }
        try Self.tree(in: a)
        try Self.tree(in: b)
        let m = manager(profiles)
        let a0 = try await walk(m, a, at: 0)
        let a1 = try await walk(m, a, at: 1)
        let store = Self.ledger(a1, profiles)
        store.suppress(Self.forms)
        let draft = RestructureManifest(profileId: a1, manifestId: "draft-1", createdAt: "x",
                                        family: "Finance", kind: .echoName, actions: [])
        store.saveDraft(.init(manifest: draft, savedAt: "2026-10-24T09:00:00"), for: Self.receipts)
        try Self.land(a1, under: a0, at: 1, in: profiles)

        let b0 = try await walk(m, b, at: 2)
        Self.ledger(b0, profiles).suppress(Self.receipts)
        let a2 = try await walk(m, a, at: 3)

        let back = Self.ledger(a2, profiles)
        #expect(back.isSuppressed(Self.forms), "the folder's suppression did not come back")
        #expect(!back.isSuppressed(Self.receipts), "the other folder's suppression came along")
        #expect(back.draft(for: Self.receipts)?.manifest.manifestId == "draft-1")
        let undo = try #require(back.undoableReorganisation(currentProfileId: a2),
                                "the folder's last landing is no longer offered for Undo")
        #expect(undo.manifest.manifestId == "landing-1")
        #expect(undo.appliedUnderProfileId == a0)
        #expect(RestructureRootMap.read(in: profiles)
                == .loaded([.init(root: FileSyncManager.recordedRoot(for: b), profileId: b0,
                                  leftAt: FilingProfileStore.stamp(Self.time(3)),
                                  landingsSeen: ["landing-1"])]),
                "the map should name only the folder now left")
    }

    // MARK: - Overlapping folders

    /// A folder inside the first one, walked and reshaped by a landing, then the first folder
    /// walked again: its history comes back, but its Undo is not offered — its inverse describes
    /// folders the nested landing moved. The controls: the same landing in a SIBLING folder, and
    /// a nested landing from BEFORE the user left the folder, both leave the Undo offered.
    @Test func aLandingInsideTheFolderSinceItWasLeftWithdrawsItsUndo() async throws {
        let base = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [base, profiles] { try? FileManager.default.removeItem(at: url) } }
        let a = base.appendingPathComponent("A"), sibling = base.appendingPathComponent("S")
        try Self.tree(in: a)
        try Self.tree(in: sibling)
        let nested = a.appendingPathComponent("Tax")
        let m = manager(profiles)
        let a0 = try await walk(m, a, at: 0)
        let a1 = try await walk(m, a, at: 1)
        Self.ledger(a1, profiles).suppress(Self.forms)
        try Self.land(a1, under: a0, at: 1, in: profiles)

        let n0 = try await walk(m, nested, at: 2)
        try Self.land(n0, under: n0, at: 2, in: profiles, manifestId: "nested")
        let a2 = try await walk(m, a, at: 3)
        let back = Self.ledger(a2, profiles)
        #expect(back.isSuppressed(Self.forms), "the folder's history did not come back")
        #expect(back.applied.contains { $0.manifest.manifestId == "landing-1" })
        #expect(back.undoableReorganisation(currentProfileId: a2) == nil,
                "an Undo was offered over a tree a landing inside it has reshaped since")
        // The card says why (review R7): the record names the folder whose landing did it.
        #expect(back.applied.first { $0.manifest.manifestId == "landing-1" }?.undoWithheldBy
                == FileSyncManager.recordedRoot(for: nested), "the withheld Undo gives no reason")

        // Control: a landing in a sibling folder touches nothing here.
        try Self.land(a2, under: a2, at: 3, in: profiles, manifestId: "landing-2")
        let s0 = try await walk(m, sibling, at: 4)
        try Self.land(s0, under: s0, at: 4, in: profiles, manifestId: "sibling")
        let a3 = try await walk(m, a, at: 5)
        #expect(Self.ledger(a3, profiles).undoableReorganisation(currentProfileId: a3)?
                    .manifest.manifestId == "landing-2",
                "a landing in a folder beside this one withdrew its Undo")
    }

    /// "Since" is not read off the clock (review R6). The stamps are local time with no zone, so
    /// after a zone change or the autumn hour a landing made after the user left reads as earlier
    /// than leaving — and the Undo was re-pointed over a tree that landing had reshaped.
    @Test func aLandingStampedBeforeTheFolderWasLeftButMadeAfterStillWithdrawsItsUndo() async throws {
        let base = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [base, profiles] { try? FileManager.default.removeItem(at: url) } }
        let a = base.appendingPathComponent("A")
        try Self.tree(in: a)
        let m = manager(profiles)
        let a0 = try await walk(m, a, at: 0)
        let a1 = try await walk(m, a, at: 1)
        try Self.land(a1, under: a0, at: 1, in: profiles)
        let n0 = try await walk(m, a.appendingPathComponent("Tax"), at: 3)
        // Stamped an hour and more before the walk away — the clock fell back in between.
        try Self.land(n0, under: n0, at: -3, in: profiles, manifestId: "nested")
        let a2 = try await walk(m, a, at: 4)
        #expect(Self.ledger(a2, profiles).undoableReorganisation(currentProfileId: a2) == nil,
                "an Undo was offered over a tree a later landing reshaped, because its stamp read earlier")
    }

    /// The other half of "since": a landing in a nested folder from BEFORE the user walked away
    /// from the outer one is already part of the tree the outer folder's Undo describes.
    @Test func aNestedLandingFromBeforeTheFolderWasLeftKeepsItsUndo() async throws {
        let base = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [base, profiles] { try? FileManager.default.removeItem(at: url) } }
        let a = base.appendingPathComponent("A"), other = base.appendingPathComponent("C")
        try Self.tree(in: a)
        try Self.tree(in: other)
        let m = manager(profiles)
        let n0 = try await walk(m, a.appendingPathComponent("Tax"), at: 0)
        try Self.land(n0, under: n0, at: 0, in: profiles, manifestId: "nested")
        let a0 = try await walk(m, a, at: 1)
        try Self.land(a0, under: a0, at: 1, in: profiles)
        _ = try await walk(m, other, at: 2)
        let a1 = try await walk(m, a, at: 3)
        #expect(Self.ledger(a1, profiles).undoableReorganisation(currentProfileId: a1)?
                    .manifest.manifestId == "landing-1",
                "a nested landing from before the folder was left withdrew its Undo")
    }

    // MARK: - After an Undo

    /// An Undo re-points the survey back to the pre-landing folder without reordering
    /// `profiles.json`. Leaving and coming back must take the history the user was looking at —
    /// the pre-landing folder's — not the undone landing's newer folder.
    @Test func walkingBackAfterAnUndoTakesThePostUndoHistory() async throws {
        let a = try Self.scratch(), b = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [a, b, profiles] { try? FileManager.default.removeItem(at: url) } }
        try Self.tree(in: a)
        try Self.tree(in: b)
        let m = manager(profiles)
        let a0 = try await walk(m, a, at: 0)
        Self.ledger(a0, profiles).suppress(Self.forms)
        let a1 = try await walk(m, a, at: 1)
        Self.ledger(a1, profiles).suppress(Self.receipts)
        try Self.land(a1, under: a0, at: 1, in: profiles)
        // What Undo's re-point does to the index.
        try FilingProfileStore.repointActiveProfile(to: a0, in: profiles, now: Self.time(2))
        try #require(FilingProfileStore.activeProfileId(in: profiles) == a0)

        _ = try await walk(m, b, at: 3)
        let a2 = try await walk(m, a, at: 4)

        let back = Self.ledger(a2, profiles)
        #expect(back.isSuppressed(Self.forms))
        #expect(!back.isSuppressed(Self.receipts),
                "the undone landing's folder was taken up instead of the one the user was in")
        #expect(back.applied.isEmpty)
    }

    // MARK: - One folder, two spellings

    /// A folder reached through a link is the same folder: its history and Undo carry as for any
    /// walk of the same folder, and the map gains no entry.
    @Test func theSameFolderThroughALinkKeepsItsHistory() async throws {
        let base = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [base, profiles] { try? FileManager.default.removeItem(at: url) } }
        let real = base.appendingPathComponent("real"), link = base.appendingPathComponent("link")
        try Self.tree(in: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let m = manager(profiles)
        let a0 = try await walk(m, real, at: 0)
        Self.ledger(a0, profiles).suppress(Self.forms)
        try Self.land(a0, under: a0, at: 0, in: profiles)

        let a1 = try await walk(m, link, at: 1)
        try #require(FilingProfileStore.recordedRoot(id: a1, in: profiles)
                     != FilingProfileStore.recordedRoot(id: a0, in: profiles),
                     "the fixture must record two spellings")
        let carried = Self.ledger(a1, profiles)
        #expect(carried.isSuppressed(Self.forms))
        #expect(carried.undoableReorganisation(currentProfileId: a1)?.manifest.manifestId
                == "landing-1")
        #expect(RestructureRootMap.read(in: profiles) == .loaded([]))
    }

    // MARK: - A history that cannot be taken up

    /// When the folder's history cannot be copied back, the walk starts an empty ledger and the
    /// map keeps naming where the history is — and keeps naming it through what follows: a walk of
    /// the same folder and a walk away both meet an empty ledger, and neither may displace the
    /// entry, or the next sweep takes the history. Once the copy can be made, it comes back.
    @Test func aFailedCopyKeepsTheEntryUntilTheHistoryComesBack() async throws {
        let a = try Self.scratch(), b = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [a, b, profiles] { try? FileManager.default.removeItem(at: url) } }
        try Self.tree(in: a)
        try Self.tree(in: b)
        let m = manager(profiles)
        let a0 = try await walk(m, a, at: 0)
        Self.ledger(a0, profiles).suppress(Self.forms)
        _ = try await walk(m, b, at: 1)
        let held = profiles.appendingPathComponent("\(a0)/restructure.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: held.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: held.path) }

        let a1 = try await walk(m, a, at: 2)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: held.path)
        #expect(FileManager.default.fileExists(
            atPath: profiles.appendingPathComponent("\(a1)/restructure.json").path),
                "a failed copy left the folder with no ledger of its own")
        #expect(!Self.ledger(a1, profiles).isSuppressed(Self.forms))
        func namesA0() -> Bool {
            guard case .loaded(let entries) = RestructureRootMap.read(in: profiles) else { return false }
            return entries.contains { $0.profileId == a0 }
        }
        #expect(namesA0(), "the entry naming the folder's history was dropped though nothing was taken up")

        _ = try await walk(m, a, at: 3)
        #expect(namesA0(), "a walk of the same folder onto an empty ledger dropped the only way back")
        _ = try await walk(m, b, at: 4)
        #expect(namesA0(), "walking away from an empty ledger displaced the entry naming the history")

        let a4 = try await walk(m, a, at: 5)
        #expect(Self.ledger(a4, profiles).isSuppressed(Self.forms),
                "the history never came back once it could be copied")
        #expect(!namesA0())
    }

    /// The point the app stamps into the active ledger after every Setup walk
    /// (`FilingArtifacts.attach(recordingTrend:)` → `stampStructureTrend`).
    private static func stampTrend(_ id: String, _ profiles: URL, at step: Int) {
        ledger(id, profiles).recordTrend(.init(at: FilingProfileStore.stamp(time(step)), profileId: id,
                                               countsByKind: ["shape": 1], landing: false))
    }

    /// A trend point is not history (review R1). After a failed copy the app stamps one into the
    /// empty ledger the walk started; counted as history, the next walk of the same folder, or
    /// a walk away, dropped or displaced the entry naming the real history, and the sweep then
    /// retired it.
    @Test func aTrendPointInTheEmptyLedgerIsNotHistory() async throws {
        let a = try Self.scratch(), b = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [a, b, profiles] { try? FileManager.default.removeItem(at: url) } }
        try Self.tree(in: a)
        try Self.tree(in: b)
        let m = manager(profiles)
        let a0 = try await walk(m, a, at: 0)
        Self.ledger(a0, profiles).suppress(Self.forms)
        _ = try await walk(m, b, at: 1)
        let held = profiles.appendingPathComponent("\(a0)/restructure.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: held.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: held.path) }
        let a1 = try await walk(m, a, at: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: held.path)
        Self.stampTrend(a1, profiles, at: 2)
        try #require(!Self.ledger(a1, profiles).trend.isEmpty, "the fixture must stamp a trend point")
        func namesA0() -> Bool {
            guard case .loaded(let entries) = RestructureRootMap.read(in: profiles) else { return false }
            return entries.contains { $0.profileId == a0 }
        }
        try #require(namesA0())

        let a2 = try await walk(m, a, at: 3)
        Self.stampTrend(a2, profiles, at: 3)
        #expect(namesA0(), "a walk of the same folder onto a trend-only ledger dropped the entry")
        let b1 = try await walk(m, b, at: 4)
        Self.stampTrend(b1, profiles, at: 4)
        #expect(namesA0(), "walking away from a trend-only ledger displaced the entry")
        _ = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: profiles)
        #expect(FileManager.default.fileExists(atPath: held.path),
                "the sweep retired the folder holding the history")

        let a3 = try await walk(m, a, at: 5)
        #expect(Self.ledger(a3, profiles).isSuppressed(Self.forms), "the history never came back")
    }

    // MARK: - Entries that hold nothing

    /// A folder left with no history — only the trend point every walk stamps — gets no entry
    /// (review R4): one would pin its profile folder, corpus and memory, for good.
    @Test func aFolderWithNoHistoryIsNotRecorded() async throws {
        let a = try Self.scratch(), b = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [a, b, profiles] { try? FileManager.default.removeItem(at: url) } }
        try Self.tree(in: a)
        try Self.tree(in: b)
        let m = manager(profiles)
        let a0 = try await walk(m, a, at: 0)
        Self.stampTrend(a0, profiles, at: 0)

        _ = try await walk(m, b, at: 1)

        #expect(RestructureRootMap.read(in: profiles) == .loaded([]),
                "a folder with nothing to return to was recorded")
        let retired = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: profiles)
        #expect(retired == [a0], "the folder left with no history was kept")
    }

    /// An entry whose Setup folder has been deleted goes at the next walk to another folder, and
    /// its profile folder with it at the next sweep (review R4). A folder whose PARENT is missing —
    /// how an unmounted volume looks — is not gone, and keeps its entry.
    @Test func anEntryWhoseFolderIsGoneIsDropped() async throws {
        let base = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [base, profiles] { try? FileManager.default.removeItem(at: url) } }
        let a = base.appendingPathComponent("A"), b = base.appendingPathComponent("B")
        let volume = base.appendingPathComponent("Volume"), c = volume.appendingPathComponent("C")
        let d = base.appendingPathComponent("D")
        for root in [a, b, c, d] { try Self.tree(in: root) }
        let m = manager(profiles)
        let a0 = try await walk(m, a, at: 0)
        Self.ledger(a0, profiles).suppress(Self.forms)
        let c0 = try await walk(m, c, at: 1)
        Self.ledger(c0, profiles).suppress(Self.forms)
        _ = try await walk(m, b, at: 2)
        func roots() -> [String] {
            guard case .loaded(let entries) = RestructureRootMap.read(in: profiles) else { return ["?"] }
            return entries.map(\.profileId).sorted()
        }
        try #require(roots() == [a0, c0].sorted())

        try FileManager.default.removeItem(at: a)
        try FileManager.default.removeItem(at: volume)
        _ = try await walk(m, d, at: 3)

        #expect(roots() == [c0], "the deleted folder's entry should go, the unmounted one's stay")
        _ = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: profiles)
        #expect(FilingProfileStore.profile(id: a0, in: profiles) == nil,
                "the deleted folder's history was kept")
        #expect(FilingProfileStore.profile(id: c0, in: profiles) != nil)
    }

    // MARK: - An unreadable map

    /// A map this build cannot read is never written over: the walk carries the ledger as it did
    /// before the map existed, and the sweep retires nothing — not even a folder it otherwise
    /// would.
    @Test func anUnreadableMapCarriesTheLedgerAndRetiresNothing() async throws {
        let a = try Self.scratch(), b = try Self.scratch(), profiles = try Self.scratch()
        defer { for url in [a, b, profiles] { try? FileManager.default.removeItem(at: url) } }
        try Self.tree(in: a)
        try Self.tree(in: b)
        let m = manager(profiles)
        let stale = try await walk(m, a, at: 0)
        let a0 = try await walk(m, a, at: 1)
        Self.ledger(a0, profiles).suppress(Self.forms)
        let garbage = Data("{ not a map".utf8)
        try garbage.write(to: RestructureRootMap.url(in: profiles))

        let b0 = try await walk(m, b, at: 2)

        #expect(Self.ledger(b0, profiles).isSuppressed(Self.forms),
                "with the map unreadable the ledger should carry as before")
        #expect(try Data(contentsOf: RestructureRootMap.url(in: profiles)) == garbage,
                "an unreadable map was written over")
        let retired = try FilingProfileStore.retireSupersededProfiles(protecting: [], in: profiles)
        #expect(retired.isEmpty)
        #expect(FilingProfileStore.profile(id: stale, in: profiles) != nil)

        // Control: the same sweep with the map gone takes the stale folder.
        try FileManager.default.removeItem(at: RestructureRootMap.url(in: profiles))
        #expect(try FilingProfileStore.retireSupersededProfiles(protecting: [], in: profiles)
                .contains(stale))
    }
}
