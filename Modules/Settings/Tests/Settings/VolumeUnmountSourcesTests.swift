import Foundation
import Testing
import Sync
@testable import Settings

/// **Ejecting a card forgets the sources on it** — the Settings half of it.
///
/// Reported 2026-08-29: a card that is renamed or ejected leaves a row that draws dimmed forever,
/// and dimmed is this app's word for *asleep*, which is what an unplugged card is. An eject is a
/// different thing — the user saying they are done with it — and it is an **event** the app is told
/// about rather than an inference from a source having gone quiet, which is what makes acting on it
/// safe to do silently.
///
/// **Whether the volume counted is not decided here.** That fact cannot be read once the volume has
/// gone, so it comes from `MountedVolumeMemory` and the caller has already applied it; these tests
/// are about what happens once it has.
@Suite struct VolumeUnmountSourcesTests {

    @MainActor
    private func manager(_ defaults: TestDefaults) -> SettingsManager {
        SettingsManager(autoDiscover: false,
                        userDefaults: defaults.defaults,
                        overridesDomainName: defaults.suiteName,
                        cloudStorageLister: { .read([]) },
                        pathValidator: { _ in true })
    }

    @MainActor
    @Test func unmountingRemovesEveryFolderSourceOnThatVolume() {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let root = settings.addFolderSource(path: "/Volumes/CARD")
        let nested = settings.addFolderSource(path: "/Volumes/CARD/DCIM")
        let elsewhere = settings.addFolderSource(path: "/Users/u/Downloads")

        let removed = settings.removeFolderSources(onVolume: "/Volumes/CARD")

        #expect(removed.count == 2, "both sources on the card should have been named")
        #expect(settings.folderSources.map(\.id) == [elsewhere],
                "the source off the card was taken too, or one on it survived")
        #expect(!settings.folderSources.contains { $0.id == root || $0.id == nested })
    }

    /// **A second card in a second reader.** `/Volumes/CARD 2` starts with `/Volumes/CARD`, so a
    /// `hasPrefix` here would empty a card the user never touched — and they would have no way to
    /// connect the loss to the eject.
    @MainActor
    @Test func unmountingOneCardLeavesASimilarlyNamedOneAlone() {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        settings.addFolderSource(path: "/Volumes/CARD")
        let other = settings.addFolderSource(path: "/Volumes/CARD 2/DCIM")

        settings.removeFolderSources(onVolume: "/Volumes/CARD")

        #expect(settings.folderSources.map(\.id) == [other])
    }

    /// **The catastrophic case, asserted where it would happen** — and the fixture has to include a
    /// source rooted at `/` itself, which is not a contrivance: the sidebar's own startup-disk row
    /// mints exactly that when it is clicked, and the reporting user's defaults carry one.
    ///
    /// It is the case the boundary form does not cover by luck. A source at `/Users/u/Downloads`
    /// survives a root unmount either way, because `mount + "/"` is `//` and prefixes nothing — so
    /// a fixture holding only nested paths stays green with the `/` refusal deleted, which is what
    /// this suite did until a mutation showed it. A source AT `/` matches on equality and is taken.
    @MainActor
    @Test func anUnmountReportedAsTheRootRemovesNothing() {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        settings.addFolderSource(path: "/")
        settings.addFolderSource(path: "/Users/u/Downloads")
        settings.addFolderSource(path: "/Volumes/CARD")
        let before = settings.folderSources

        #expect(settings.removeFolderSources(onVolume: "/").isEmpty)
        #expect(settings.removeFolderSources(onVolume: "").isEmpty)
        #expect(settings.folderSources == before)
    }

    /// **The name is read before the removal**, from the override if there is one — the message the
    /// user sees names the card they just ejected, not a raw id or a folder name they renamed away
    /// from. Reading it after would give the fallback for both, so the fixture renames the source
    /// to something the path cannot produce.
    @MainActor
    @Test func theRemovedSourceIsNamedAsTheUserNamedIt() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let id = settings.addFolderSource(path: "/Volumes/CARD")
        settings.setCustomName("Wedding shoot", for: id)
        await settings.discoverProviders()

        #expect(settings.removeFolderSources(onVolume: "/Volumes/CARD") == ["Wedding shoot"])
    }

    /// The per-id keys go with the source, the same as any other removal — an override left keyed
    /// to an id nothing holds would attach itself to whatever id came next.
    @MainActor
    @Test func unmountingClearsTheNameOverrideAndTheEnabledFlag() {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let id = settings.addFolderSource(path: "/Volumes/CARD")
        settings.setCustomName("Wedding shoot", for: id)
        settings.setEnabled(false, for: id)
        #expect(defaults.defaults.string(forKey: "name_override_\(id)") == "Wedding shoot")

        settings.removeFolderSources(onVolume: "/Volumes/CARD")

        #expect(defaults.defaults.string(forKey: "name_override_\(id)") == nil)
        #expect(settings.isEnabled(id), "the disabled flag outlived the source it belonged to")
    }

    /// **One discovery for the whole card, not one per source.**
    ///
    /// The removal ran `removeFolderSource(id:)` per id, and each of those spawns
    /// `Task { await discoverProviders() }` — a pass that lists the CloudStorage mounting point and
    /// then `stat`s every provider root to recompute `pathValidity`, on network-backed mounts that
    /// can block for seconds. `discoveryGeneration` only decides which pass gets to *publish*, so
    /// the extra ones did the whole cost and were discarded. Four sources on one card meant four
    /// full discoveries at the moment a volume disappeared.
    ///
    /// Counted through the lister, which each pass calls exactly once — the same instrument
    /// `SettingsDiscoveryTests` uses to count passes.
    ///
    /// **The card's sources are already on disk when the manager under count is built.** Adding
    /// them through it spawned four discoveries of its own, and the test had to wait those out
    /// before it could measure anything — work it is not about, behind its run's first wait. In
    /// full-package runs at load 44–99 that wait ran out in 4 of 10. Built over saved sources with
    /// `autoDiscover: false`, the manager has run no pass, so the count starts at a true zero.
    @MainActor
    @Test func unmountingACardRunsOneDiscoveryRatherThanOnePerSource() async throws {
        let defaults = TestDefaults()
        let card = ["/Volumes/CARD", "/Volumes/CARD/DCIM", "/Volumes/CARD/RAW", "/Volumes/CARD/JPG"]
        defaults.defaults.set(try JSONEncoder().encode(card.map(FolderSource.new(path:))),
                              forKey: "folderSources")
        let counter = CallCounter()
        let settings = SettingsManager(autoDiscover: false,
                                       userDefaults: defaults.defaults,
                                       overridesDomainName: defaults.suiteName,
                                       cloudStorageLister: { counter.increment(); return .read([]) },
                                       pathValidator: { _ in true })
        try #require(settings.folderSources.count == 4, "the saved card did not load, so there is nothing to batch")

        settings.removeFolderSources(onVolume: "/Volumes/CARD")
        let passes = try await Self.countAfter(counter, reaching: 1)

        #expect(settings.folderSources.isEmpty, "the removal did not happen, so the count means nothing")
        #expect(passes == 1,
                "removing four sources on one card ran \(passes) provider discoveries; each one lists the CloudStorage mount and stats every root")
    }

    /// The lister count once at least `reaching` discoveries have run AND nothing more has arrived
    /// for a while.
    ///
    /// **It requires the target rather than reporting whatever it saw**, and that is the whole
    /// design. The first version simply quiet-settled inside a 2s budget: on a busy machine — this
    /// suite runs in parallel with three other packages on a self-hosted runner that is also the
    /// development Mac — the removal's pass had not started when it gave up, so it reported 0. A
    /// measurement taken before the work runs is not a small measurement, it is a wrong one, so
    /// this fails loudly instead.
    ///
    /// **Polled on the main actor, and floored in polls** — see "Fixed pumps and fixed sleeps" in
    /// `docs/flaky-tests.md`. Each pass starts as a main-actor `Task`, so what it waits for is
    /// main-actor turns, and a poll that hops through the main actor spends one: the floor
    /// guarantees `pollFloor` of them however few the clock allows. Polled off it, as this
    /// was, the loop could spend all 20s while the main thread ran other suites' test bodies and
    /// the passes sat queued. The poll count goes in the failure, because it is the diagnosis.
    @MainActor
    private static func countAfter(_ counter: CallCounter, reaching target: Int,
                                   sourceLocation: SourceLocation = #_sourceLocation) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var polls = 0
        while counter.count < target, polls < Self.pollFloor || ContinuousClock.now < deadline {
            polls += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(counter.count >= target,
                     "only \(counter.count) of \(target) provider discoveries had run after \(polls) polls",
                     sourceLocation: sourceLocation)
        // Then quiet: nothing more may arrive, or an extra pass would go uncounted. Counted in
        // polls, not cut short by the deadline above — a run starved through the first loop used
        // to reach this one with no time left, and an absence check that never looked passes. The
        // cap only stops a count that never settles from hanging the suite.
        var last = -1, quiet = 0, settling = 0
        while quiet < 40, settling < 1_000 {
            settling += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
            let now = counter.count
            if now == last { quiet += 1 } else { quiet = 0; last = now }
        }
        return counter.count
    }

    /// The fewest polls `countAfter` makes before it may give up — the number, and the reason, of
    /// `waitPollFloor` in `Modules/Sync/Tests/Sync/TestSupport.swift`, which this target cannot
    /// import.
    private static let pollFloor = 50

    @MainActor
    @Test func unmountingAVolumeWithNoSourcesChangesNothing() {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        settings.addFolderSource(path: "/Users/u/Downloads")
        let before = settings.folderSources

        #expect(settings.removeFolderSources(onVolume: "/Volumes/CARD").isEmpty)
        #expect(settings.folderSources == before)
    }
}
