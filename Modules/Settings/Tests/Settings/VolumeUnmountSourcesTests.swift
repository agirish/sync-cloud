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
        let defaults = TestDefaults(); defer { defaults.wipe() }
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
        let defaults = TestDefaults(); defer { defaults.wipe() }
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
        let defaults = TestDefaults(); defer { defaults.wipe() }
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
        let defaults = TestDefaults(); defer { defaults.wipe() }
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
        let defaults = TestDefaults(); defer { defaults.wipe() }
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
    @MainActor
    @Test func unmountingACardRunsOneDiscoveryRatherThanOnePerSource() async throws {
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let counter = CallCounter()
        let settings = SettingsManager(autoDiscover: false,
                                       userDefaults: defaults.defaults,
                                       overridesDomainName: defaults.suiteName,
                                       cloudStorageLister: { counter.increment(); return .read([]) },
                                       pathValidator: { _ in true })
        for folder in ["/Volumes/CARD", "/Volumes/CARD/DCIM", "/Volumes/CARD/RAW", "/Volumes/CARD/JPG"] {
            settings.addFolderSource(path: folder)
        }
        // The four adds each spawn a discovery of their own; let them all land, then measure only
        // what the removal costs.
        let afterAdds = try await Self.countAfter(counter, reaching: 4)

        settings.removeFolderSources(onVolume: "/Volumes/CARD")
        let afterRemoval = try await Self.countAfter(counter, reaching: afterAdds + 1) - afterAdds

        #expect(settings.folderSources.isEmpty, "the removal did not happen, so the count means nothing")
        #expect(afterRemoval == 1,
                "removing four sources on one card ran \(afterRemoval) provider discoveries; each one lists the CloudStorage mount and stats every root")
    }

    /// The lister count once at least `reaching` discoveries have run AND nothing more has arrived
    /// for a while.
    ///
    /// **It requires the target rather than reporting whatever it saw**, and that is the whole
    /// design. The first version simply quiet-settled inside a 2s budget: on a busy machine — this
    /// suite runs in parallel with three other packages on a self-hosted runner that is also the
    /// development Mac — the four adds had not started when it gave up, so it reported 0, and the
    /// test then read "four discoveries" for a batch that had in fact run one. A measurement taken
    /// before the work runs is not a small measurement, it is a wrong one, so this fails loudly
    /// instead.
    ///
    /// Bounded at 20s so a genuinely wedged pass fails the assertion rather than hanging the suite.
    private static func countAfter(_ counter: CallCounter, reaching target: Int,
                                   sourceLocation: SourceLocation = #_sourceLocation) async throws -> Int {
        let deadline = Date().addingTimeInterval(20)
        while counter.count < target, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(counter.count >= target,
                     "only \(counter.count) of \(target) provider discoveries had run after 20s — the machine is too busy for this measurement to mean anything",
                     sourceLocation: sourceLocation)
        // Then quiet: nothing more may arrive, or a late pass would be credited to the next phase.
        var last = -1, quiet = 0
        while quiet < 40, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            let now = counter.count
            if now == last { quiet += 1 } else { quiet = 0; last = now }
        }
        return counter.count
    }

    @MainActor
    @Test func unmountingAVolumeWithNoSourcesChangesNothing() {
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let settings = manager(defaults)
        settings.addFolderSource(path: "/Users/u/Downloads")
        let before = settings.folderSources

        #expect(settings.removeFolderSources(onVolume: "/Volumes/CARD").isEmpty)
        #expect(settings.folderSources == before)
    }
}
