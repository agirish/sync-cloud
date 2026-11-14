import Foundation
import Testing
import Sync
@testable import Settings

/// Ejecting a card forgets the sources on it: the Settings half. Dimmed means *asleep* in this
/// app, which suits an unplugged card but not an ejected one, which the user is done with. An
/// eject is an event the app is told about, not an inference from a source gone quiet, which is
/// what makes acting on it silently safe.
///
/// Whether the volume counted is not decided here: that can't be read once the volume is gone, so
/// it comes from `MountedVolumeMemory` and the caller has already applied it.
@Suite struct VolumeUnmountSourcesTests {

    @MainActor
    private func manager(_ defaults: TestDefaults) -> SettingsManager {
        defaults.manager(validator: { _ in true }, domain: defaults.suiteName)
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

    /// A second card in a second reader. `/Volumes/CARD 2` starts with `/Volumes/CARD`, so a bare
    /// `hasPrefix` would empty a card the user never touched, with no way to connect the loss to
    /// the eject.
    @MainActor
    @Test func unmountingOneCardLeavesASimilarlyNamedOneAlone() {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        settings.addFolderSource(path: "/Volumes/CARD")
        let other = settings.addFolderSource(path: "/Volumes/CARD 2/DCIM")

        settings.removeFolderSources(onVolume: "/Volumes/CARD")

        #expect(settings.folderSources.map(\.id) == [other])
    }

    /// An unmount reported as `/` (or empty) must remove nothing. The fixture needs a source at `/`
    /// itself, which the sidebar's startup-disk row creates when clicked: nested paths survive a
    /// root unmount anyway, because `mount + "/"` is `//` and prefixes nothing, while a source at
    /// `/` matches on equality. Deleting the `/` refusal must make this fail.
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

    /// The name is read before the removal, from the override if there is one, so the message
    /// names the card as the user named it. Read after, it would be the fallback, so the fixture
    /// renames the source to something the path cannot produce.
    @MainActor
    @Test func theRemovedSourceIsNamedAsTheUserNamedIt() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let id = settings.addFolderSource(path: "/Volumes/CARD")
        settings.setCustomName("Wedding shoot", for: id)
        await settings.discoverProviders()

        #expect(settings.removeFolderSources(onVolume: "/Volumes/CARD") == ["Wedding shoot"])
    }

    /// The per-id keys go with the source, as in any other removal: an override left keyed to an
    /// id nothing holds would attach itself to whatever source next got that id.
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

    /// One discovery for the whole card, not one per source. Each pass lists the CloudStorage
    /// mount and `stat`s every provider root, which can block for seconds on network mounts, and
    /// `discoveryGeneration` only picks which pass publishes, so extra passes are pure cost. Fails
    /// if the removal calls `removeFolderSource(id:)` per id.
    ///
    /// Counted through the lister, which each pass calls exactly once, as `SettingsDiscoveryTests`
    /// does. The sources are saved before the manager is built with `autoDiscover: false`, so it
    /// has run no pass and the count starts at zero; adding them through it would start
    /// discoveries of their own to wait out, which times out under load.
    @MainActor
    @Test func unmountingACardRunsOneDiscoveryRatherThanOnePerSource() async throws {
        let defaults = TestDefaults()
        let card = ["/Volumes/CARD", "/Volumes/CARD/DCIM", "/Volumes/CARD/RAW", "/Volumes/CARD/JPG"]
        defaults.defaults.set(try JSONEncoder().encode(card.map(FolderSource.new(path:))),
                              forKey: "folderSources")
        let counter = CallCounter()
        let settings = defaults.manager(
            lister: { counter.increment(); return .read([]) },
            validator: { _ in true },
            domain: defaults.suiteName)
        try #require(settings.folderSources.count == 4, "the saved card did not load, so there is nothing to batch")

        settings.removeFolderSources(onVolume: "/Volumes/CARD")
        let passes = try await Self.countAfter(counter, reaching: 1)

        #expect(settings.folderSources.isEmpty, "the removal did not happen, so the count means nothing")
        #expect(passes == 1,
                "removing four sources on one card ran \(passes) provider discoveries; each one lists the CloudStorage mount and stats every root")
    }

    /// The lister count once at least `reaching` discoveries have run and nothing more has arrived
    /// for a while. It requires the target rather than reporting whatever it saw: on a busy
    /// machine the removal's pass may not have started yet, and a count taken before the work
    /// runs is wrong, not small, so this fails loudly instead.
    ///
    /// Polled on the main actor through `LayoutPumpWait.poll` ("Fixed pumps and fixed sleeps" in
    /// `docs/flaky-tests.md`): each pass starts as a main-actor `Task`, so each poll must spend a
    /// main-actor turn, or the loop could spend the whole deadline while the passes sat queued.
    @MainActor
    private static func countAfter(_ counter: CallCounter, reaching target: Int,
                                   sourceLocation: SourceLocation = #_sourceLocation) async throws -> Int {
        let wait = await LayoutPumpWait.poll(upTo: 20) { counter.count >= target }
        try #require(wait.held,
                     "only \(counter.count) of \(target) provider discoveries had run after \(wait.passes) polls",
                     sourceLocation: sourceLocation)
        // Then quiet: nothing more may arrive, or an extra pass would go uncounted. Counted in
        // polls, not cut short by the deadline above, so a run starved through the first loop
        // still looks; an absence check that never looks passes. The cap only stops a count that
        // never settles from hanging the suite.
        var last = -1, quiet = 0, settling = 0
        while quiet < 40, settling < 1_000 {
            settling += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
            let now = counter.count
            if now == last { quiet += 1 } else { quiet = 0; last = now }
        }
        return counter.count
    }

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
