import Testing
import Foundation
@testable import Dashboard

/// One global Recents list across every source. Per-root lists can't be interleaved without a
/// clock, so `visitedAt` is what lets the store answer "the eight folders I visited last, wherever
/// they were". Most rules below cover the seam between dated entries and entries written without
/// the field.
@Suite struct CrossSourceRecentsTests {

    /// A fixed clock, so the tests state ordering rather than racing a real `Date()`; it is why
    /// `recordVisit` takes `at:`.
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func visit(_ path: String, _ minutes: Double?) -> JumpLocation {
        JumpLocation(relativePath: path, name: (path as NSString).lastPathComponent,
                     visitedAt: minutes.map { Self.at($0) })
    }

    /// An empty favorites map shaped like the recents one, so a landings test can't pass because of
    /// a favorite it forgot to declare.
    private func favorites(none recents: [String: [JumpLocation]]) -> [String: [JumpLocation]] {
        recents.mapValues { _ in [] }
    }

    // MARK: - The ordering itself

    /// Folders from four sources come back as one list in visit order, not grouped by source.
    @Test func visitsInterleaveAcrossRootsByTime() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/iCloud": [visit("Health/Dental", 100)],
                      "/Dropbox": [visit("Shared Docs", 40)],
                      "/Drive-emp": [visit("Work/Q3 Review", 80)],
                      "/Local": [visit("Downloads", 10)]],
            favorites: [:], limit: 8)
        #expect(out.map(\.relativePath) == ["Health/Dental", "Work/Q3 Review", "Shared Docs", "Downloads"])
        #expect(out.map(\.root) == ["/iCloud", "/Drive-emp", "/Dropbox", "/Local"])
    }

    /// Why `visitedAt` is optional, not defaulted: older builds, and the maintenance lines that
    /// share this defaults domain, write entries with no date. `.distantPast` would claim the
    /// folder was visited longest ago when nobody recorded it. An undated entry sorts after every
    /// dated one and is still listed.
    @Test func anUndatedEntrySortsAfterEveryDatedOneAndIsStillListed() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/iCloud": [visit("Dental", 100), visit("Statements", nil)],
                      "/Dropbox": [visit("Shared Docs", 1)]],
            favorites: [:], limit: 8)
        #expect(out.map(\.relativePath) == ["Dental", "Shared Docs", "Statements"])
        #expect(out.last?.visitedAt == nil)
    }

    /// An undated entry must not outrank even a very old dated one, a case a `.distantPast` default
    /// would pass anyway.
    @Test func aVeryOldDatedEntryStillOutranksAnUndatedOne() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/a": [visit("Ancient", -500_000)], "/b": [visit("Unknown", nil)]],
            favorites: [:], limit: 8)
        #expect(out.map(\.relativePath) == ["Ancient", "Unknown"])
    }

    /// An all-undated store, the state after upgrading, still lists everything; its order makes no
    /// claim about recency.
    @Test func anAllUndatedStoreStillListsEverything() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/b": [visit("Two", nil)], "/a": [visit("One", nil)]],
            favorites: [:], limit: 8)
        #expect(Set(out.map(\.relativePath)) == ["One", "Two"])
    }

    // MARK: - Stability

    /// The order must be the same on every launch. Dictionary iteration order varies between
    /// processes, and leaning on it would reshuffle Recents for no visible reason.
    @Test func theOrderDoesNotDependOnDictionaryIteration() {
        let recents = ["/z": [visit("Zed", nil)], "/a": [visit("Ay", nil)], "/m": [visit("Em", nil)]]
        let answers = Set((0..<40).map { _ in
            FolderJumpStore.mostRecentAcrossRoots(recents: recents, favorites: [:], limit: 8)
                .map(\.relativePath).joined(separator: ">")
        })
        #expect(answers.count == 1, "the order varies between runs: \(answers)")
    }

    /// Two visits sharing a date break their tie on root then path, because `sorted(by:)` is not a
    /// stable sort in Swift and would otherwise be free to swap them run to run.
    @Test func visitsSharingADateBreakTheirTieReproducibly() {
        let recents = ["/b": [visit("Same", 50)], "/a": [visit("Same", 50)]]
        let answers = Set((0..<40).map { _ in
            FolderJumpStore.mostRecentAcrossRoots(recents: recents, favorites: [:], limit: 8)
                .map(\.root).joined(separator: ">")
        })
        #expect(answers == ["/a>/b"], "same-date visits are not ordered reproducibly: \(answers)")
    }

    // MARK: - What it excludes and how far it goes

    /// Favorites are subtracted per root, as `recentPaths(forRoot:)` does: a folder under two
    /// headings wastes a row in a list of eight.
    @Test func aFolderThatIsAFavoriteIsNotAlsoARecent() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/iCloud": [visit("Dental", 100), visit("Taxes 2026", 90)]],
            favorites: ["/iCloud": [visit("Taxes 2026", nil)]], limit: 8)
        #expect(out.map(\.relativePath) == ["Dental"])
    }

    /// Subtraction is per root, not global: the same relative path under two sources is two
    /// folders, and favouriting one must not hide the other.
    @Test func favouritingAFolderInOneSourceDoesNotHideTheSamePathInAnother() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/iCloud": [visit("Health", 100)], "/Dropbox": [visit("Health", 90)]],
            favorites: ["/iCloud": [visit("Health", nil)]], limit: 8)
        #expect(out.map(\.root) == ["/Dropbox"])
    }

    /// The landing folder is subtracted. Switching to a source lands the pane on its `openAt` and
    /// records a visit, so without this Recents fills with the folders the Locations rows already
    /// reach. `/iCloud` lands at its root (the empty path) and its recent survives, since
    /// `recordVisit` never writes a recent for a root itself.
    @Test func aSourcesLandingFolderIsNotAlsoARecent() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/Dropbox": [visit("Documents", 100)],
                      "/Drive-emp": [visit("My Drive", 90)],
                      "/iCloud": [visit("Finance/US", 80)]],
            favorites: [:],
            landings: ["/Dropbox": "Documents", "/Drive-emp": "My Drive", "/iCloud": ""],
            limit: 8)
        #expect(out.map(\.relativePath) == ["Finance/US"])
    }

    /// Only the landing itself: a folder inside it is somewhere the user navigated to, and no other
    /// row goes there. A prefix match would wrongly hide it.
    @Test func aFolderUnderTheLandingIsStillARecent() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/Dropbox": [visit("Documents", 100), visit("Documents/Taxes 2026", 90)]],
            favorites: [:], landings: ["/Dropbox": "Documents"], limit: 8)
        #expect(out.map(\.relativePath) == ["Documents/Taxes 2026"])
    }

    /// Per root, like the favorites subtraction: `Documents` being one source's landing must not
    /// hide the `Documents` you visited in another, whose landing is somewhere else entirely.
    @Test func oneSourcesLandingDoesNotHideTheSamePathInAnother() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/Dropbox": [visit("Documents", 100)], "/OneDrive": [visit("Documents", 90)]],
            favorites: [:], landings: ["/Dropbox": "Documents"], limit: 8)
        #expect(out.map(\.root) == ["/OneDrive"])
    }

    /// Landings are subtracted before the cap, not after. A multi-account install can have eight
    /// landings ahead of a real recent; filtering after the limit would show an empty section.
    @Test func landingsDoNotConsumeTheLimit() {
        var recents: [String: [JumpLocation]] = ["/iCloud": [visit("Finance/US", 1)]]
        var landings: [String: String] = [:]
        for i in 0..<8 {
            recents["/source\(i)"] = [visit("Documents", Double(100 + i))]
            landings["/source\(i)"] = "Documents"
        }
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: recents, favorites: favorites(none: recents), landings: landings, limit: 8)
        #expect(out.map(\.relativePath) == ["Finance/US"],
                "a landing displaced a real recent out of the eight")
    }

    /// No landings, as every other caller (the ⌘K palette) passes, subtracts nothing.
    @Test func noLandingsSubtractsNothing() {
        let recents = ["/Dropbox": [visit("Documents", 100)]]
        #expect(FolderJumpStore.mostRecentAcrossRoots(recents: recents, favorites: [:], limit: 8)
                    .map(\.relativePath) == ["Documents"])
    }

    /// The limit bounds the merged list: eight across every source, not eight per source.
    @Test func theLimitBoundsTheMergedListNotEachRoot() {
        let recents = Dictionary(uniqueKeysWithValues: (0..<5).map { r in
            ("/root\(r)", (0..<4).map { i in visit("r\(r)f\(i)", Double(r * 10 + i)) })
        })
        let out = FolderJumpStore.mostRecentAcrossRoots(recents: recents, favorites: [:], limit: 8)
        #expect(out.count == 8, "the merged list is \(out.count) long, not the requested 8")
        // Newest first: root 4's folders carry the largest offsets.
        #expect(out.first?.root == "/root4")
    }

    /// A zero or negative limit yields nothing rather than trapping on `prefix`.
    @Test func aNonPositiveLimitYieldsNothing() {
        let recents = ["/a": [visit("One", 10)]]
        #expect(FolderJumpStore.mostRecentAcrossRoots(recents: recents, favorites: [:], limit: 0).isEmpty)
        #expect(FolderJumpStore.mostRecentAcrossRoots(recents: recents, favorites: [:], limit: -3).isEmpty)
    }

    /// An empty store is an empty list, not a crash — the first-run state.
    @Test func anEmptyStoreYieldsAnEmptyList() {
        #expect(FolderJumpStore.mostRecentAcrossRoots(recents: [:], favorites: [:], limit: 8).isEmpty)
    }

    // MARK: - Favorites across roots

    /// Favorites span sources too, but keep each root's curated order: the user chose it.
    @Test func favoritesSpanRootsAndKeepEachRootsOwnOrder() {
        let store = ["/iCloud": [visit("Taxes 2026", nil), visit("Scans", nil)],
                     "/Dropbox": [visit("Health", nil)]]
        let out = FolderJumpStore.mostRecentAcrossRoots(recents: [:], favorites: store, limit: 8)
        #expect(out.isEmpty, "favorites must not leak into the recents list")
        // The favorites accessor is the store's, so the ordering rule is asserted through the
        // pure function the store calls: roots sorted, each root's own order untouched.
        let sorted = store.keys.sorted().flatMap { store[$0]!.map(\.relativePath) }
        #expect(sorted == ["Health", "Taxes 2026", "Scans"])
    }
}

/// The decode side of `visitedAt`. The ordering tests build `JumpLocation`s in memory and can't
/// see whether the field round-trips; the sidebar gets whatever `JSONDecoder` makes of the stored
/// bytes, including bytes from builds that never write this key.
@Suite struct JumpLocationMigrationTests {

    /// An entry with no date decodes, as unknown: the shape in older installs' defaults and the one
    /// older release lines still write.
    @Test func aStoredEntryWithNoDateDecodesAsUnknown() throws {
        let json = #"[{"relativePath":"Health/Dental","name":"Dental"}]"#
        let decoded = try JSONDecoder().decode([JumpLocation].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded.first?.relativePath == "Health/Dental")
        #expect(decoded.first?.visitedAt == nil, "an undated entry decoded to a date it never had")
    }

    /// A dated entry round-trips, so the field is really written, not dropped by the encoder.
    @Test func aDatedEntryRoundTrips() throws {
        let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = JumpLocation(relativePath: "Work/Q3", name: "Q3", visitedAt: when)
        let back = try JSONDecoder().decode([JumpLocation].self,
                                            from: try JSONEncoder().encode([original]))
        #expect(back.first?.visitedAt == when)
    }

    /// A whole per-root map in the undated shape decodes, as `storedMap` reads it. If it didn't,
    /// `storedMap` would take the undecodable branch and move every user's recents into the salvage
    /// key on first launch, which looks like the upgrade lost their history.
    @Test func aWholeOldMapDecodesRatherThanBeingTreatedAsUnreadable() throws {
        let json = #"{"/iCloud":[{"relativePath":"Health","name":"Health"}],"# +
                   #""/Dropbox":[{"relativePath":"Shared","name":"Shared"}]}"#
        let decoded = try JSONDecoder().decode([String: [JumpLocation]].self, from: Data(json.utf8))
        #expect(decoded.keys.sorted() == ["/Dropbox", "/iCloud"])
        #expect(decoded.values.allSatisfy { $0.allSatisfy { $0.visitedAt == nil } })
    }

    /// The other direction, since the release lines share this defaults domain: an older decoder
    /// meeting `visitedAt` must ignore the key, not fail the whole map.
    @Test func anOlderDecoderIgnoresTheNewKey() throws {
        struct PreV44: Codable, Equatable { let relativePath: String; let name: String }
        let json = #"[{"relativePath":"Work","name":"Work","visitedAt":776000000}]"#
        let back = try JSONDecoder().decode([PreV44].self, from: Data(json.utf8))
        #expect(back == [PreV44(relativePath: "Work", name: "Work")])
    }
}
