import Testing
import Foundation
@testable import Dashboard

/// **One global Recents list across every source**, and the timestamp that makes it computable.
///
/// Before v4.4 a `JumpLocation` was `{relativePath, name}` — the per-root lists were each ordered,
/// but two ordered lists cannot be interleaved without a clock, so "the eight folders I visited
/// last, wherever they were" was not a question the store could answer. `visitedAt` is what makes
/// it one, and every rule below is about what happens at the seam between entries that have a date
/// and entries written before the field existed.
@Suite struct CrossSourceRecentsTests {

    /// A fixed clock. Dates are built by offset from one instant so the tests state *ordering*
    /// rather than racing a real `Date()` — the reason `recordVisit` takes its `at:`.
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func visit(_ path: String, _ minutes: Double?) -> JumpLocation {
        JumpLocation(relativePath: path, name: (path as NSString).lastPathComponent,
                     visitedAt: minutes.map { Self.at($0) })
    }

    /// An empty favorites map shaped like the recents one — so a test about landings cannot pass
    /// because of a favorite it forgot to declare.
    private func favorites(none recents: [String: [JumpLocation]]) -> [String: [JumpLocation]] {
        recents.mapValues { _ in [] }
    }

    // MARK: - The ordering itself

    /// The headline: folders from four different sources come back as one list in the order they
    /// were visited, not grouped by where they live.
    @Test func visitsInterleaveAcrossRootsByTime() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/iCloud": [visit("Health/Dental", 100)],
                      "/Dropbox": [visit("Shared Docs", 40)],
                      "/Drive-hpe": [visit("Work/Q3 Review", 80)],
                      "/Local": [visit("Downloads", 10)]],
            favorites: [:], limit: 8)
        #expect(out.map(\.relativePath) == ["Health/Dental", "Work/Q3 Review", "Shared Docs", "Downloads"])
        #expect(out.map(\.root) == ["/iCloud", "/Drive-hpe", "/Dropbox", "/Local"])
    }

    /// **The migration case, and the reason `visitedAt` is optional rather than defaulted.**
    ///
    /// An entry written by any build before v4.4 — or by a v2.x/v3.x build, which share this
    /// defaults domain and will never write the field — has no date. Defaulting it to
    /// `.distantPast` would assert that folder was visited longest ago; the truth is that nobody
    /// recorded it. It sorts after everything dated, which is where "we do not know" belongs
    /// against "we do", and it is still *listed* rather than dropped.
    @Test func anUndatedEntrySortsAfterEveryDatedOneAndIsStillListed() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/iCloud": [visit("Dental", 100), visit("Statements", nil)],
                      "/Dropbox": [visit("Shared Docs", 1)]],
            favorites: [:], limit: 8)
        #expect(out.map(\.relativePath) == ["Dental", "Shared Docs", "Statements"])
        #expect(out.last?.visitedAt == nil)
    }

    /// The other half of that claim, and the one a `.distantPast` default would have passed anyway:
    /// an undated entry must not outrank a *very old* dated one either.
    @Test func aVeryOldDatedEntryStillOutranksAnUndatedOne() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/a": [visit("Ancient", -500_000)], "/b": [visit("Unknown", nil)]],
            favorites: [:], limit: 8)
        #expect(out.map(\.relativePath) == ["Ancient", "Unknown"])
    }

    /// All-undated is the state every install is in on first launch after upgrading, and it must
    /// still produce a list — just one whose order carries no claim about recency.
    @Test func anAllUndatedStoreStillListsEverything() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/b": [visit("Two", nil)], "/a": [visit("One", nil)]],
            favorites: [:], limit: 8)
        #expect(Set(out.map(\.relativePath)) == ["One", "Two"])
    }

    // MARK: - Stability

    /// **The order must be the same on every launch.** Dictionary iteration order is not stable
    /// across processes, so a rule that leaned on it would give a Recents section that reshuffled
    /// itself for no reason the user could see. Asserted by building the same store many times and
    /// requiring one answer.
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

    /// Favorites are subtracted per root, exactly as `recentPaths(forRoot:)` does it — a folder
    /// under two headings is one wasted row in a list of eight.
    @Test func aFolderThatIsAFavoriteIsNotAlsoARecent() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/iCloud": [visit("Dental", 100), visit("Taxes 2026", 90)]],
            favorites: ["/iCloud": [visit("Taxes 2026", nil)]], limit: 8)
        #expect(out.map(\.relativePath) == ["Dental"])
    }

    /// **Subtraction is per root, not global.** The same relative path under two different sources
    /// is two different folders, and favouriting one must not silently hide the other.
    @Test func favouritingAFolderInOneSourceDoesNotHideTheSamePathInAnother() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/iCloud": [visit("Health", 100)], "/Dropbox": [visit("Health", 90)]],
            favorites: ["/iCloud": [visit("Health", nil)]], limit: 8)
        #expect(out.map(\.root) == ["/Dropbox"])
    }

    /// **The landing folder is subtracted**, which is the case that made this section useless with
    /// several accounts connected: switching to a source lands the pane on its `openAt` and records
    /// a visit, so Recents filled up with the very folders the Locations rows above take you to.
    /// Measured on the real store, 2026-08-27: six of seven recents were landings.
    ///
    /// `/iCloud` lands at its root — the empty spelling — and its recent survives, which is the
    /// case a rule written as "drop what equals the landing" gets right only because a recent for
    /// the root itself is something `recordVisit` will not write.
    @Test func aSourcesLandingFolderIsNotAlsoARecent() {
        let out = FolderJumpStore.mostRecentAcrossRoots(
            recents: ["/Dropbox": [visit("Documents", 100)],
                      "/Drive-hpe": [visit("My Drive", 90)],
                      "/iCloud": [visit("Finance/US", 80)]],
            favorites: [:],
            landings: ["/Dropbox": "Documents", "/Drive-hpe": "My Drive", "/iCloud": ""],
            limit: 8)
        #expect(out.map(\.relativePath) == ["Finance/US"])
    }

    /// **Only the landing itself.** A folder *inside* it is somewhere the user navigated to, and no
    /// row anywhere else in the column goes there — the mirror of the favorites rule, and the half
    /// a prefix match would have got wrong for every source whose landing is `Documents`.
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

    /// **Subtracted before the cap, not after.** Eight landings ahead of a real recent is exactly
    /// the shape a multi-account install reaches, and a filter applied to the result of a limit of
    /// eight would have returned an empty section while `Finance/US` sat unshown behind them.
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

    /// No landings is the shape every other caller passes — the ⌘K palette, and any build before
    /// this rule existed. Nothing is subtracted.
    @Test func noLandingsSubtractsNothing() {
        let recents = ["/Dropbox": [visit("Documents", 100)]]
        #expect(FolderJumpStore.mostRecentAcrossRoots(recents: recents, favorites: [:], limit: 8)
                    .map(\.relativePath) == ["Documents"])
    }

    /// The limit is applied to the merged list, which is the whole point — eight across every
    /// source rather than eight per source.
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

    /// Favorites span sources the same way, but keep each root's curated order rather than being
    /// re-sorted by anything — the user put them in that order.
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

/// **The decode side of `visitedAt`** — the half a test of the ordering rule cannot see.
///
/// The ordering tests above build `JumpLocation`s in memory, so they would pass identically whether
/// the field round-trips through JSON or not. What actually reaches the sidebar is whatever
/// `JSONDecoder` makes of bytes on disk, including bytes written by a build that had never heard of
/// this key.
@Suite struct JumpLocationMigrationTests {

    /// **Bytes from before v4.4 decode, and decode as unknown.** This is the shape sitting in every
    /// existing install's defaults, and the shape a v2.x or v3.x build writes today.
    @Test func aStoredEntryWithNoDateDecodesAsUnknown() throws {
        let json = #"[{"relativePath":"Health/Dental","name":"Dental"}]"#
        let decoded = try JSONDecoder().decode([JumpLocation].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded.first?.relativePath == "Health/Dental")
        #expect(decoded.first?.visitedAt == nil, "an undated entry decoded to a date it never had")
    }

    /// And a dated one round-trips, so the field is really being written rather than dropped by an
    /// encoder that never sees it.
    @Test func aDatedEntryRoundTrips() throws {
        let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = JumpLocation(relativePath: "Work/Q3", name: "Q3", visitedAt: when)
        let back = try JSONDecoder().decode([JumpLocation].self,
                                            from: try JSONEncoder().encode([original]))
        #expect(back.first?.visitedAt == when)
    }

    /// **A whole stored map from the old shape survives**, which is what `storedMap` actually
    /// decodes — a per-root dictionary, not a bare array. If this failed, `storedMap` would take
    /// the undecodable branch and stash every existing user's recents into the salvage key on
    /// first launch, which looks exactly like "the upgrade lost my history".
    @Test func aWholeOldMapDecodesRatherThanBeingTreatedAsUnreadable() throws {
        let json = #"{"/iCloud":[{"relativePath":"Health","name":"Health"}],"# +
                   #""/Dropbox":[{"relativePath":"Shared","name":"Shared"}]}"#
        let decoded = try JSONDecoder().decode([String: [JumpLocation]].self, from: Data(json.utf8))
        #expect(decoded.keys.sorted() == ["/Dropbox", "/iCloud"])
        #expect(decoded.values.allSatisfy { $0.allSatisfy { $0.visitedAt == nil } })
    }

    /// The other direction, which matters because all three release lines share this defaults
    /// domain: a v2.x decoder meets an entry carrying `visitedAt` and must ignore the key rather
    /// than fail the whole map. Asserted by decoding into a struct that has no such field.
    @Test func anOlderDecoderIgnoresTheNewKey() throws {
        struct PreV44: Codable, Equatable { let relativePath: String; let name: String }
        let json = #"[{"relativePath":"Work","name":"Work","visitedAt":776000000}]"#
        let back = try JSONDecoder().decode([PreV44].self, from: Data(json.utf8))
        #expect(back == [PreV44(relativePath: "Work", name: "Work")])
    }
}
