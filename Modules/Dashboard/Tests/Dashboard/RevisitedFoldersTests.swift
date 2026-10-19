import Testing
import Foundation
@testable import Dashboard

/// The rules behind the sidebar's **Revisited** and **Frequent** lists (decided 2026-10-19).
///
/// A stay is a visit the pane stayed in for a few seconds (SQ4); a return inside five minutes
/// continues the stay before it (SQ8). Revisited is stays on 2+ different calendar days (SQ1),
/// Frequent is 2+ stays (SQ8), and both need a faded weight of 1 (SQ7) inside 90 days (SQ2).
/// Revisited is newest first; Frequent is by weight (SQ6). Favorites and landing folders are
/// subtracted as Recents subtracts them, at most eight rows.
@MainActor
@Suite struct RevisitedFoldersTests {

    /// Every date in this suite is UTC on a UTC calendar, so "a different day" is the same answer
    /// on every machine.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-10-19 12:00 UTC, plus an offset.
    private func t(days: Double = 0, hours: Double = 0, minutes: Double = 0, seconds: Double = 0) -> Date {
        Date(timeIntervalSince1970: 1_792_411_200 + days * 86_400 + hours * 3_600 + minutes * 60 + seconds)
    }

    private let root = "/Volumes/Data"
    private let stay = FolderJumpStore.stayThreshold

    private func stays(_ dates: Date..., name: String = "x") -> FolderStays {
        FolderStays(name: name, stays: dates)
    }

    private func listed(_ mode: RecentsMode, _ map: [String: [String: FolderStays]],
                        favorites: [String: [JumpLocation]] = [:],
                        landings: [String: String] = [:],
                        now: Date, limit: Int = FolderJumpStore.maxRecents) -> [String] {
        FolderJumpStore.stayedAcrossRoots(mode, stays: map, favorites: favorites, landings: landings,
                                          now: now, calendar: Self.utc, limit: limit)
            .map(\.relativePath)
    }

    /// Arrives, stays `seconds`, and leaves for the root — the shape one visit has in the app.
    private func visit(_ store: FolderJumpStore, _ path: String, at start: Date, for seconds: Double) {
        store.noteArrival(pane: "left", root: root, relativePath: path, name: path, at: start)
        store.noteArrival(pane: "left", root: root, relativePath: "", name: "",
                          at: start.addingTimeInterval(seconds))
    }

    // MARK: SQ1 — Revisited needs two calendar days

    @Test func twoStaysOnOneDayAreNotRevisited() {
        let map = [root: ["Backup": stays(t(hours: -3), t())]]
        #expect(listed(.revisited, map, now: t()) == [])
    }

    @Test func twoStaysOnTwoDaysAreRevisited() {
        let map = [root: ["Taxes": stays(t(days: -1), t())]]
        #expect(listed(.revisited, map, now: t()) == ["Taxes"])
    }

    /// Calendar days, not 24 hours apart: 23:55 and 00:05 are two days (the mockup's own example).
    @Test func midnightSplitsTwoDays() {
        let lateNight = t(hours: 11, minutes: 55)     // 23:55
        let justAfter = t(hours: 12, minutes: 5)      // 00:05 the next day
        let map = [root: ["Late": stays(lateNight, justAfter)]]
        #expect(listed(.revisited, map, now: justAfter) == ["Late"])
    }

    // MARK: SQ8 — Frequent counts every stay, same day included

    /// Three stays this morning: Frequent, not Revisited — so the two lists can differ.
    @Test func threeStaysInOneDayAreFrequentButNotRevisited() {
        let map = [root: ["Inbox": stays(t(hours: -3), t(hours: -2), t(hours: -1))]]
        #expect(listed(.frequent, map, now: t()) == ["Inbox"])
        #expect(listed(.revisited, map, now: t()) == [])
    }

    @Test func oneStayIsNeverFrequent() {
        let map = [root: ["Once": stays(t())]]
        #expect(listed(.frequent, map, now: t()) == [])
    }

    /// Frequent ranks by faded weight of stays, not by recency: four stays last week outrank two
    /// today, and the newest-first order Revisited uses would put them the other way round.
    @Test func frequentRanksByWeightedStays() {
        let map = [root: ["Today": stays(t(hours: -2), t(hours: -1)),
                          "Weekly": stays(t(days: -7), t(days: -7, hours: 1),
                                          t(days: -6), t(days: -6, hours: 1))]]
        #expect(listed(.frequent, map, now: t()) == ["Weekly", "Today"])
        #expect(listed(.revisited, map, now: t()) == ["Weekly"], "Today has one day only")
    }

    /// Revisited stays newest first by last stay, whatever the weights say.
    @Test func revisitedIsNewestFirstNotHeaviestFirst() {
        let map = [root: ["Heavy": stays(t(days: -6), t(days: -5), t(days: -4), t(days: -3)),
                          "Light": stays(t(days: -1), t())]]
        #expect(listed(.revisited, map, now: t()) == ["Light", "Heavy"])
        #expect(listed(.frequent, map, now: t()) == ["Heavy", "Light"])
    }

    /// With the fade, two folders weigh the same only when their stays are the same, so a tie is
    /// broken by root and path — the order is the same on every run, never dictionary order.
    @Test func equalWeightsKeepAStableOrder() {
        let same = stays(t(days: -2), t(days: -2, hours: 1))
        let map = [root: ["Older": same, "Newer": same, "Middle": same]]
        for _ in 0..<5 { #expect(listed(.frequent, map, now: t()) == ["Middle", "Newer", "Older"]) }
    }

    // MARK: SQ7 — the fade

    /// Two days a month ago just make it; two days two months ago do not — in both modes.
    @Test func twoDaysAMonthAgoQualifyTwoMonthsAgoDoNot() {
        let monthAgo = [root: ["Q": stays(t(days: -30), t(days: -29))]]   // 0.5 + 0.51 ≥ 1
        #expect(listed(.revisited, monthAgo, now: t()) == ["Q"])
        #expect(listed(.frequent, monthAgo, now: t()) == ["Q"])
        let twoMonthsAgo = [root: ["Q": stays(t(days: -60), t(days: -59))]] // 0.25 + 0.26 < 1
        #expect(listed(.revisited, twoMonthsAgo, now: t()) == [])
        #expect(listed(.frequent, twoMonthsAgo, now: t()) == [])
    }

    @Test func theFadeHalvesOverTheHalfLife() {
        #expect(FolderJumpStore.fadedWeight(of: t(), now: t()) == 1)
        let halfLife = t(days: -FolderJumpStore.fadeHalfLifeDays)
        #expect(abs(FolderJumpStore.fadedWeight(of: halfLife, now: t()) - 0.5) < 1e-12)
    }

    /// Revisited weighs DAYS, not stays: many stays on two old days must not buy their way in.
    @Test func revisitedWeighsDaysNotStays() {
        var old: [Date] = []
        for hour in 0..<6 { old.append(t(days: -60, hours: Double(hour))); old.append(t(days: -59, hours: Double(hour))) }
        let map = [root: ["Busy": FolderStays(name: "Busy", stays: old)]]
        #expect(listed(.revisited, map, now: t()) == [], "two days two months ago weigh about 0.5")
        #expect(listed(.frequent, map, now: t()) == ["Busy"], "twelve stays at ~0.25 each weigh about 3")
    }

    // MARK: SQ2 — 90 days

    @Test func aStayOlderThanNinetyDaysNoLongerCounts() {
        let threeRecent = [root: ["Q": stays(t(days: -91), t(days: -1), t())]]
        let twoRecent = [root: ["Q": stays(t(days: -1), t())]]
        // The 91-day stay would add weight; inside the window it must add none.
        #expect(listed(.frequent, threeRecent, now: t()) == listed(.frequent, twoRecent, now: t()))
        let onlyOld = [root: ["Q": stays(t(days: -91), t())]]
        #expect(listed(.revisited, onlyOld, now: t()) == [])
        #expect(listed(.frequent, onlyOld, now: t()) == [])
    }

    @Test func pruningDropsExpiredStaysAndEmptiedFolders() {
        let map = [root: ["Old": stays(t(days: -100)), "Mixed": stays(t(days: -100), t(days: -1))]]
        let pruned = FolderJumpStore.pruned(map, now: t(), cap: 500)
        #expect(pruned[root]?["Old"] == nil)
        #expect(pruned[root]?["Mixed"]?.stays == [t(days: -1)])
    }

    /// The record is not capped at eight — that is the point of it — but it is bounded, and the
    /// least recently stayed go first.
    @Test func pruningPastTheCapDropsTheLeastRecentlyStayed() {
        let map = [root: ["a": stays(t(days: -3)), "b": stays(t(days: -1)), "c": stays(t(days: -2))]]
        let pruned = FolderJumpStore.pruned(map, now: t(), cap: 2)
        #expect(pruned[root]?.keys.sorted() == ["b", "c"])
    }

    // MARK: SQ4 + SQ8 — what counts as a stay

    @Test func aFolderLeftBeforeTheThresholdDoesNotCount() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-dwell-skim"))
        store.noteArrival(pane: "left", root: root, relativePath: "Taxes", name: "Taxes", at: t())
        store.noteArrival(pane: "left", root: root, relativePath: "Taxes/2025", name: "2025",
                          at: t(seconds: stay - 1))
        #expect(store.staysByRoot[root]?["Taxes"] == nil, "a drill-through parent counted as a stay")
    }

    @Test func aFolderLeftAfterTheThresholdCounts() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-dwell-stay"))
        store.noteArrival(pane: "left", root: root, relativePath: "Taxes", name: "Taxes", at: t())
        store.noteArrival(pane: "left", root: root, relativePath: "Medical", name: "Medical",
                          at: t(seconds: stay))
        #expect(store.staysByRoot[root]?["Taxes"]?.stays == [t()])
        #expect(store.staysByRoot[root]?["Medical"] == nil, "the folder just arrived at is not stayed in yet")
    }

    /// The timer the app sets: an early settle leaves the arrival alone, an on-time one counts it,
    /// and a later one does not count it twice.
    @Test func settlingCountsEachStayOnce() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-dwell-settle"))
        store.noteArrival(pane: "left", root: root, relativePath: "Taxes", name: "Taxes", at: t())
        store.settleStays(at: t(seconds: stay - 0.5))
        #expect(store.staysByRoot.isEmpty)
        store.settleStays(at: t(seconds: stay))
        store.settleStays(at: t(minutes: 30))
        #expect(store.staysByRoot[root]?["Taxes"]?.stays == [t()])
    }

    /// Two opens three minutes apart are one stay, so the folder is not Frequent.
    @Test func aReturnWithinFiveMinutesIsTheSameStay() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-return-soon"))
        visit(store, "Taxes", at: t(), for: 60)
        visit(store, "Taxes", at: t(minutes: 3), for: 60)
        #expect(store.staysByRoot[root]?["Taxes"]?.stays == [t()])
        #expect(store.visitsAcrossRoots(.frequent, now: t(minutes: 10)).isEmpty)
    }

    /// Measured from LEAVING, not from arriving: a long stay, a minute away, then back, is one stay.
    @Test func theGapIsTimeAwayNotTimeSinceArriving() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-return-long"))
        visit(store, "Taxes", at: t(), for: 20 * 60)
        visit(store, "Taxes", at: t(minutes: 21), for: 60)
        #expect(store.staysByRoot[root]?["Taxes"]?.stays.count == 1)
    }

    @Test func aReturnAfterFiveMinutesIsANewStay() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-return-later"))
        visit(store, "Taxes", at: t(), for: 60)
        visit(store, "Taxes", at: t(minutes: 1 + FolderJumpStore.returnGap / 60), for: 60)
        #expect(store.staysByRoot[root]?["Taxes"]?.stays.count == 2)
        #expect(store.visitsAcrossRoots(.frequent, now: t(minutes: 10)).map(\.relativePath) == ["Taxes"])
    }

    /// A skim never left a stay to continue, so a return after one is judged on its own dwell.
    @Test func aSkimThenAReturnCountsTheReturn() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-skim-return"))
        visit(store, "Taxes", at: t(), for: 1)
        visit(store, "Taxes", at: t(minutes: 1), for: 60)
        #expect(store.staysByRoot[root]?["Taxes"]?.stays == [t(minutes: 1)])
    }

    /// Each pane has its own folder: the right pane moving must not settle — or drop — the left's.
    @Test func panesAreSettledIndependently() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-dwell-panes"))
        store.noteArrival(pane: "left", root: root, relativePath: "Taxes", name: "Taxes", at: t())
        store.noteArrival(pane: "right", root: root, relativePath: "A", name: "A", at: t(seconds: 1))
        store.noteArrival(pane: "right", root: root, relativePath: "B", name: "B", at: t(seconds: 2))
        store.settleStays(at: t(seconds: 10))
        #expect(store.staysByRoot[root]?.keys.sorted() == ["B", "Taxes"],
                "A was skimmed; Taxes and B were stayed in")
    }

    /// Stays never touch Recents, and visits never make stays: Recents is unchanged (SQ4).
    @Test func visitsAndStaysAreSeparateRecords() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-separate"))
        store.recordVisit(root: root, relativePath: "Skim", name: "Skim", at: t())
        #expect(store.staysByRoot.isEmpty)
        store.noteArrival(pane: "left", root: root, relativePath: "Stay", name: "Stay", at: t())
        store.settleStays(at: t(seconds: 60))
        #expect(store.recents(forRoot: root).map(\.relativePath) == ["Skim"])
        #expect(store.visitsAcrossRoots(.recents).map(\.relativePath) == ["Skim"])
    }

    /// End to end through the store: two stays on two days, then each mode.
    @Test func twoStayedDaysThroughTheStore() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-e2e"))
        visit(store, "Taxes", at: t(days: -1), for: 30)
        visit(store, "Taxes", at: t(), for: 30)
        #expect(store.visitsAcrossRoots(.revisited, now: t(minutes: 1)).map(\.relativePath) == ["Taxes"])
        #expect(store.visitsAcrossRoots(.frequent, now: t(minutes: 1)).map(\.relativePath) == ["Taxes"])
    }

    // MARK: Cap, subtraction, roots

    @Test func atMostEight() {
        var folders: [String: FolderStays] = [:]
        for i in 0..<10 { folders["f\(i)"] = stays(t(days: -20), t(days: -10, hours: Double(i))) }
        #expect(listed(.revisited, [root: folders], now: t()) == ["f9", "f8", "f7", "f6", "f5", "f4", "f3", "f2"])
        #expect(listed(.frequent, [root: folders], now: t()).count == 8)
    }

    @Test(arguments: [RecentsMode.revisited, .frequent])
    func favoritesAndLandingsAreSubtracted(mode: RecentsMode) {
        let map = [root: ["Fav": stays(t(days: -1), t()),
                          "Documents": stays(t(days: -1), t()),
                          "Documents/Taxes": stays(t(days: -1), t())]]
        let rows = listed(mode, map, favorites: [root: [JumpLocation(relativePath: "Fav", name: "Fav")]],
                          landings: [root: "Documents"], now: t())
        #expect(rows == ["Documents/Taxes"], "only the landing itself is subtracted, never what is under it")
    }

    /// Spans roots, like Recents: one list across every source.
    @Test func spansRoots() {
        let map = ["/a": ["One": stays(t(days: -2), t(hours: -1))],
                   "/b": ["Two": stays(t(days: -2), t())]]
        #expect(FolderJumpStore.stayedAcrossRoots(.revisited, stays: map, favorites: [:], now: t(),
                                                  calendar: Self.utc, limit: 8).map(\.root)
                == ["/b", "/a"])
    }

    // MARK: The mode

    @Test func theIconCyclesThroughTheThreeModes() {
        #expect(RecentsMode.recents.next == .revisited)
        #expect(RecentsMode.revisited.next == .frequent)
        #expect(RecentsMode.frequent.next == .recents)
        #expect(FolderSidebarView.modeAccessibilityLabel(.revisited) == "Showing Revisited. Switch to Frequent")
        #expect(FolderSidebarView.modeSymbol(.frequent) != FolderSidebarView.modeSymbol(.revisited))
        #expect(FolderSidebarView.emptyLine(.recents) == nil)
        #expect(FolderSidebarView.emptyLine(.revisited) != FolderSidebarView.emptyLine(.frequent))
    }

    // MARK: Persistence and removal

    @Test func staysSurviveARelaunch() {
        let defaults = ScratchDefaults("revisited-persist")
        let store = FolderJumpStore(defaults: defaults)
        store.recordStay(root: root, relativePath: "Taxes", name: "Taxes", at: t(days: -1))
        store.recordStay(root: root, relativePath: "Taxes", name: "Taxes", at: t())
        let relaunched = FolderJumpStore(defaults: defaults)
        #expect(relaunched.staysByRoot[root]?["Taxes"]?.stays == [t(days: -1), t()])
    }

    /// "Remove from Recents" on a Revisited or Frequent row has to remove it from that list.
    @Test func forgettingARecentForgetsItsStays() {
        let store = FolderJumpStore(defaults: ScratchDefaults("revisited-forget"))
        store.recordStay(root: root, relativePath: "Taxes", name: "Taxes", at: t(days: -1))
        store.recordStay(root: root, relativePath: "Taxes", name: "Taxes", at: t())
        #expect(store.visitsAcrossRoots(.revisited, now: t()).map(\.relativePath) == ["Taxes"])
        store.forgetRecent(root: root, relativePath: "Taxes")
        #expect(store.visitsAcrossRoots(.revisited, now: t()).isEmpty)
        #expect(store.visitsAcrossRoots(.frequent, now: t()).isEmpty)
    }

    /// Unreadable bytes are kept aside, not written over by the next stay — the store's rule for
    /// every list it holds.
    @Test func unreadableStaysAreKeptAside() {
        let defaults = ScratchDefaults("revisited-salvage")
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: FolderJumpStore.staysKey)
        let store = FolderJumpStore(defaults: defaults)
        store.recordStay(root: root, relativePath: "Taxes", name: "Taxes", at: t())
        #expect(defaults.data(forKey: FolderJumpStore.salvageKey(for: FolderJumpStore.staysKey)) == garbage)
    }
}
