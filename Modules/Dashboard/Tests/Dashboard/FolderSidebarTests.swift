import Testing
import SwiftUI
import AppKit
import Design
@testable import Dashboard

/// Browse's remembered-folders sidebar: the rows the model builds.
@Suite struct FolderSidebarModelTests {

    /// The provider's display name: what a top-level folder is "in", and what the badge reads.
    static let rootName = "iCloud"
    static let root = "/iCloud"

    /// One source, the shape most of these assertions need: qualification and ordering can go
    /// wrong without two accounts.
    private func one(recents: [String] = [], favorites: [String] = [],
                     isAvailable: Bool = true) -> [FolderSidebarRow] {
        FolderSidebarModel.rows(
            sources: [.init(root: Self.root, name: Self.rootName,
                            favorites: favorites, isAvailable: isAvailable)],
            recents: recents.map { RememberedVisit(root: Self.root, relativePath: $0,
                                                   name: ($0 as NSString).lastPathComponent,
                                                   visitedAt: nil) })
    }

    /// Favorites are curated and recents a rolling eight, so favorites go first; the order within
    /// each is the store's.
    @Test func favoritesComeFirstAndEachListKeepsTheStoresOrder() {
        let rows = one(recents: ["Downloads", "Notes"], favorites: ["Work", "Archive"])
        #expect(rows.map(\.name) == ["Work", "Archive", "Downloads", "Notes"])
        #expect(rows.map(\.group) == [.pinned, .pinned, .recents, .recents])
    }

    /// The row reads the folder's own name, not the path that reaches it.
    @Test func aRowIsNamedForItsFolder() {
        let rows = one(favorites: ["Clients/Acme/Legal"])
        #expect(rows.first?.name == "Legal")
        #expect(rows.first?.relativePath == "Clients/Acme/Legal")
    }

    /// Two folders with the same leaf would read identically, and one goes somewhere the user
    /// didn't mean, so each shows its parent.
    @Test func twoFoldersSharingALeafNameEachShowTheirParent() {
        #expect(one(favorites: ["Clients/Legal", "Archive/Legal"]).map(\.detail) == ["Clients", "Archive"])
    }

    /// A top-level folder has no parent path, so in a collision between `Clients/Legal` and a
    /// root-level `Legal` it is qualified by the provider's name, or only one row would say which.
    @Test func aTopLevelFolderInACollisionIsQualifiedByTheProvider() {
        #expect(one(favorites: ["Clients/Legal", "Legal"]).map(\.detail) == ["Clients", "iCloud"])
    }

    /// Collisions are counted across both groups, since the reader sees one column. The recent gets
    /// no second line of its own, but it still makes the colliding favorite grow one.
    @Test func theCollisionIsCountedAcrossFavoritesAndRecentsTogether() {
        #expect(one(recents: ["Archive/Legal"], favorites: ["Clients/Legal"]).map(\.detail) == ["Clients", nil])
    }

    /// A recent never carries a second line, whatever would qualify it. Asserted over every shape
    /// that could qualify one: a collision with a parent, a top-level collision that would borrow
    /// the source's name, and two colliding recents. Its whole path is in the tooltip.
    @Test func aRecentNeverShowsASecondLine() {
        let cases: [[FolderSidebarRow]] = [
            one(recents: ["Archive/Legal"], favorites: ["Clients/Legal"]),
            one(recents: ["Legal"], favorites: ["Clients/Legal"]),
            one(recents: ["Clients/Legal", "Archive/Legal"]),
            one(recents: ["Legal", "Archive/Legal"]),
        ]
        for rows in cases {
            let recents = FolderSidebarModel.rows(rows, in: .recents)
            #expect(!recents.isEmpty, "the fixture produced no recents to check")
            #expect(recents.allSatisfy { $0.detail == nil },
                    "a recent grew a second line: \(recents.compactMap(\.detail))")
        }
    }

    /// The other direction, which keeps every row from growing a second line: a name nothing else
    /// shares needs no disambiguation.
    @Test func aNameNothingSharesShowsNoParent() {
        #expect(one(favorites: ["Clients/Legal", "Archive/Invoices"]).allSatisfy { $0.detail == nil })
        #expect(one(favorites: ["Work", "Work extra"]).allSatisfy { $0.detail == nil })
    }

    /// A root that didn't answer means "everything remembered, unchecked": the rows stay, marked,
    /// because dropping them over a sleeping drive would cost the user their favorites.
    @Test func aSleepingRootLeavesEveryRowListedAndUnavailable() {
        let rows = one(recents: ["Notes"], favorites: ["Work"], isAvailable: false)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.isAvailable })
        #expect(rows.allSatisfy { !FolderSidebarModel.canOpen($0) })
    }

    @Test func aLiveRootLeavesEveryRowOpenable() {
        #expect(one(favorites: ["Work"]).allSatisfy { FolderSidebarModel.canOpen($0) })
    }

    /// ⌘ opens a new tab; nothing else does. ⌥ must not: it mirrors panes everywhere else in the
    /// app, and is kept out of chords for the shortcut reveal.
    @Test func onlyCommandOpensANewTab() {
        #expect(FolderSidebarModel.opensInNewTab(.command))
        #expect(FolderSidebarModel.opensInNewTab([.command, .shift]))
        #expect(!FolderSidebarModel.opensInNewTab([]))
        #expect(!FolderSidebarModel.opensInNewTab(.option))
        #expect(!FolderSidebarModel.opensInNewTab(.shift))
    }

    /// The ids a `ForEach` runs on can't collide across the groups, so a store bug that made a
    /// folder both favorite and recent would draw it twice rather than crash the list.
    @Test func rowIdsAreUniqueEvenIfAFolderAppearsInBothLists() {
        let rows = one(recents: ["Work"], favorites: ["Work"])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    // MARK: - Across sources

    private static func source(_ root: String, _ name: String, _ favorites: [String],
                               available: Bool = true) -> FolderSidebarModel.Source {
        .init(root: root, name: name, favorites: favorites, isAvailable: available)
    }

    private static func visit(_ root: String, _ path: String) -> RememberedVisit {
        RememberedVisit(root: root, relativePath: path,
                        name: (path as NSString).lastPathComponent, visitedAt: nil)
    }

    /// The same relative path under two sources is two folders, and both survive the `ForEach`;
    /// that is why the root is part of the row's identity.
    @Test func theSamePathUnderTwoSourcesIsTwoRows() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["Health"]),
                      Self.source("/Dropbox", "Dropbox", ["Health"])],
            recents: [])
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2, "two sources' Health folders share one id — one would not draw")
        #expect(rows.map(\.root) == ["/iCloud", "/Dropbox"])
    }

    /// Two sources on one root must not crash the sidebar. `SettingsManager.existingSource` keeps
    /// enabled providers off a shared root, but a hand-edited plist could still produce one, and
    /// `uniqueKeysWithValues:` traps on the duplicate on every refresh. First wins instead; the two
    /// sources here disagree on availability and name, so crediting the second would show.
    @Test func twoSourcesOnOneRootDrawWithoutTrappingAndTheFirstWins() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "Personal", ["Legal"]),
                      Self.source("/iCloud", "Impostor", ["Legal"], available: false)],
            recents: [])
        // Both favorites lists still contribute rows: membership is per source; only the lookup
        // by root collapses.
        #expect(rows.count == 2, "a duplicate root dropped rows rather than resolving them")
        #expect(rows.allSatisfy { $0.isAvailable },
                "a row took the duplicate's availability — the first listed source must win")
        // A top-level collision, so the qualifier is the owning source's name: first wins keeps it
        // reading "Personal".
        #expect(rows.allSatisfy { $0.detail == "Personal" },
                "a row was qualified by the duplicate source's name: \(rows.map(\.detail))")
    }

    /// The badge names the source once more than one contributes rows.
    @Test func theBadgeAppearsOnlyWhenMoreThanOneSourceContributes() {
        let single = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["Health"]),
                      Self.source("/Dropbox", "Dropbox", [])],   // connected, but nothing remembered
            recents: [])
        #expect(single.allSatisfy { $0.sourceName == nil },
                "a badge repeating one source down the whole column says nothing")

        let both = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["Health"]),
                      Self.source("/Dropbox", "Dropbox", ["Backup"])],
            recents: [])
        #expect(both.map(\.sourceName) == ["iCloud", "Dropbox"])
    }

    /// Both disambiguators at once, the case neither alone can carry: two `Legal` rows from two
    /// accounts, one nested and one top-level.
    @Test func aRowCanNeedBothItsBadgeAndItsParent() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/Drive", "Drive", ["Clients/Legal"]),
                      Self.source("/iCloud", "iCloud", ["Legal"])],
            recents: [])
        #expect(rows.map(\.detail) == ["Clients", "iCloud"])
        #expect(rows.map(\.sourceName) == ["Drive", "iCloud"])
    }

    /// Recents arrive ordered by the store and are not re-sorted: the rule needs a clock and lives
    /// (and is tested) in `FolderJumpStore.mostRecentAcrossRoots`. Two rules for one order would
    /// drift apart.
    @Test func recentsKeepTheOrderTheStoreGaveThem() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/a", "A", []), Self.source("/b", "B", [])],
            recents: [Self.visit("/b", "Second"), Self.visit("/a", "First")])
        #expect(rows.map(\.name) == ["Second", "First"])
    }

    /// A recent whose source has gone is dropped, not drawn unavailable. A sleeping drive exists
    /// and isn't answering; a source removed from Settings is one the app can say nothing about.
    @Test func aRecentFromAnUnknownSourceIsDropped() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", [])],
            recents: [Self.visit("/iCloud", "Health"), Self.visit("/Removed", "Ghost")])
        #expect(rows.map(\.name) == ["Health"])
    }

    /// Availability is per source, so one sleeping account does not dim the rest of the column.
    @Test func oneSleepingSourceDimsOnlyItsOwnRows() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["Health"]),
                      Self.source("/Drive", "Drive", ["Work"], available: false)],
            recents: [])
        #expect(rows.map(\.isAvailable) == [true, false])
    }

    // MARK: A folder the column already lists under another heading

    /// A recent naming a folder that Favorites or Locations already offers is not drawn again: in
    /// one 180pt column, two rows to one folder waste one of eight.
    @Test func aRecentTheColumnAlreadyListsIsNotDrawnAgain() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", [])],
            recents: [Self.visit("/iCloud", "Documents"), Self.visit("/iCloud", "Health")],
            listedElsewhere: ["/iCloud": ["Documents"]])
        #expect(FolderSidebarModel.rows(rows, in: .recents).map(\.name) == ["Health"])
    }

    /// Per root, not per path: two sources holding the same relative path are two folders, and a
    /// place listed under one says nothing about the other.
    @Test func theSubtractionIsKeyedByRoot() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", []), Self.source("/Dropbox", "Dropbox", [])],
            recents: [Self.visit("/iCloud", "Documents"), Self.visit("/Dropbox", "Documents")],
            listedElsewhere: ["/iCloud": ["Documents"]])
        let recents = FolderSidebarModel.rows(rows, in: .recents)
        #expect(recents.map(\.root) == ["/Dropbox"])
    }

    // MARK: The cap counts rows that are DRAWN

    /// The cap is applied here, after dropping recents whose source was removed; applied before, a
    /// dead entry would take one of the eight and leave the section a row short.
    @Test func aRecentFromARemovedSourceDoesNotSpendOneOfTheEight() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", [])],
            recents: [Self.visit("/Removed", "Ghost")] + (1...3).map { Self.visit("/iCloud", "F\($0)") },
            recentsLimit: 3)
        #expect(FolderSidebarModel.rows(rows, in: .recents).map(\.name) == ["F1", "F2", "F3"],
                "the ghost spent a slot the column never drew")
    }

    /// The same for the subtraction above, which would otherwise shorten the section by every row it
    /// removed.
    @Test func aSubtractedRecentDoesNotSpendOneOfTheEight() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", [])],
            recents: (1...4).map { Self.visit("/iCloud", "F\($0)") },
            listedElsewhere: ["/iCloud": ["F1", "F2"]],
            recentsLimit: 2)
        #expect(FolderSidebarModel.rows(rows, in: .recents).map(\.name) == ["F3", "F4"])
    }

    /// The cap is on Recents alone: Favorites is curated by the user, and a cap there would silently
    /// hide one they added.
    @Test func theCapDoesNotTouchFavorites() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["A", "B", "C"])],
            recents: [Self.visit("/iCloud", "F1"), Self.visit("/iCloud", "F2")],
            recentsLimit: 1)
        #expect(FolderSidebarModel.rows(rows, in: .pinned).map(\.name) == ["A", "B", "C"])
        #expect(FolderSidebarModel.rows(rows, in: .recents).map(\.name) == ["F1"])
    }

    /// A zero cap draws no recents rather than all of them: the clamp's other end.
    @Test func aZeroCapDrawsNoRecents() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["A"])],
            recents: [Self.visit("/iCloud", "F1")],
            recentsLimit: 0)
        #expect(FolderSidebarModel.rows(rows, in: .recents).isEmpty)
        #expect(FolderSidebarModel.rows(rows, in: .pinned).map(\.name) == ["A"])
    }

    // MARK: The badge counts sources that are DRAWN

    /// "Is this multi-source" is read off the rows, not the inputs: a second account whose every
    /// recent is subtracted contributes nothing visible, so it must not badge the whole column.
    @Test func aSourceWhoseEveryRecentIsSubtractedPutsNoBadgeOnTheColumn() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["Health"]),
                      Self.source("/Dropbox", "Dropbox", [])],
            recents: [Self.visit("/Dropbox", "Documents")],
            listedElsewhere: ["/Dropbox": ["Documents"]])
        #expect(rows.map(\.name) == ["Health"])
        #expect(rows.map(\.sourceName) == [nil], "a badge names a source with nothing on screen")
    }

    /// A recent always names its source, even with one source, so its badge doesn't come and go
    /// between Recents modes. A favorite from the only source stays unbadged.
    @Test func aRecentFromTheOnlySourceIsStillBadged() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["Health"])],
            recents: [Self.visit("/iCloud", "Petition")])
        #expect(FolderSidebarModel.rows(rows, in: .recents).map(\.sourceName) == ["iCloud"])
        #expect(FolderSidebarModel.rows(rows, in: .pinned).map(\.sourceName) == [nil],
                "a favorite from the only source is badged — the same word down the column says nothing")
    }

    /// The case it must not break: two sources that both draw still badge.
    @Test func twoSourcesThatBothDrawStillBadge() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["Health"]),
                      Self.source("/Dropbox", "Dropbox", [])],
            recents: [Self.visit("/Dropbox", "Documents")])
        #expect(rows.map(\.sourceName) == ["iCloud", "Dropbox"])
    }
}

/// The column, rendered: geometry can't say whether a row is dimmed or which one is current.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct FolderSidebarRenderTests {

    static let canvas = CGSize(width: FolderSidebarView.defaultWidth, height: 320)

    private func render(rows: [FolderSidebarRow], current: String = "",
                        locations: [SidebarSourceRow] = [],
                        collapsed: Set<FolderSidebarView.Section> = []) -> NSBitmapImageRep? {
        let subject = FolderSidebarView(folderRows: rows, locationRows: locations,
                                        currentRoot: "/iCloud", currentRelativePath: current,
                                        currentSourceId: "", collapsed: collapsed,
                                        accent: LiquidGlassHue.blue.accentColor,
                                        onOpen: { _, _ in }, onToggleFavorite: { _ in },
                                        onOpenSource: { _, _ in }, onToggleSection: { _ in })
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels differing from the background: "something is painted here".
    private func inked(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB) else { return 0 }
        var count = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - background.redComponent) > 0.06
                    || abs(c.greenComponent - background.greenComponent) > 0.06
                    || abs(c.blueComponent - background.blueComponent) > 0.06 { count += 1 }
            }
        }
        return count
    }

    private func rows(_ remembered: RememberedFolders) -> [FolderSidebarRow] {
        FolderSidebarModel.rows(
            sources: [.init(root: "/iCloud", name: "iCloud", favorites: remembered.pinned,
                            isAvailable: remembered.rootIsAvailable)],
            recents: remembered.recents.map {
                RememberedVisit(root: "/iCloud", relativePath: $0,
                                name: ($0 as NSString).lastPathComponent, visitedAt: nil)
            })
    }

    /// More rows paint more. Compared with a shorter list, not the empty state: the empty state's
    /// two sentences out-ink a pair of one-word rows. This fails if a row stops drawing.
    @Test func eachRowPaints() throws {
        let one = try #require(render(rows: rows(RememberedFolders(
            recents: [], pinned: ["Work"], rootIsAvailable: true))))
        let four = try #require(render(rows: rows(RememberedFolders(
            recents: ["Downloads", "Notes"], pinned: ["Work", "Archive"], rootIsAvailable: true))))
        #expect(inked(four) > inked(one) + 100,
                "four rows paint no more than one — \(inked(four)) vs \(inked(one))")
    }

    /// The empty state is not blank: a sidebar just switched on with nothing in it must say how it
    /// fills, or it reads as broken.
    @Test func theEmptyStateSaysSomething() throws {
        #expect(inked(try #require(render(rows: []))) > 120)
    }

    /// An unavailable row is dimmed, drawn rather than left to `.disabled`: under `hoverAffordance`
    /// the style doesn't dim a disabled button at all.
    @Test func anUnavailableRowIsVisiblyQuieter() throws {
        let live = try #require(render(rows: rows(RememberedFolders(
            recents: [], pinned: ["Work"], rootIsAvailable: true))))
        let asleep = try #require(render(rows: rows(RememberedFolders(
            recents: [], pinned: ["Work"], rootIsAvailable: false))))
        #expect(inked(asleep) < inked(live),
                "the unavailable row paints as strongly as the live one — \(inked(asleep)) vs \(inked(live))")
    }

    /// The current row fills the column, which is a claim about the hit area: a `hoverAffordance`
    /// row is clickable only where it paints. A test can't hover a SwiftUI button, but the
    /// current-folder highlight is drawn by the same modifier chain as the hit shape, so its width
    /// measures the row.
    @Test func theCurrentRowFillsTheColumn() throws {
        let listed = rows(RememberedFolders(recents: [], pinned: ["Work"], rootIsAvailable: true))
        let rep = try #require(render(rows: listed, current: "Work"))
        // The widest painted scanline, in device pixels; the canvas is 180pt at 2×.
        var widest = 0
        for y in 0..<rep.pixelsHigh {
            var first = -1, last = -1
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let bg = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) > 0.02
                    || abs(c.blueComponent - bg.blueComponent) > 0.02 {
                    if first < 0 { first = x }
                    last = x
                }
            }
            if first >= 0 { widest = max(widest, last - first) }
        }
        let column = rep.pixelsWide
        #expect(widest > Int(Double(column) * 0.8),
                "the widest painted row spans \(widest) of \(column) px — the row is sized to its text, so most of the column is unclickable")
    }

    /// The current folder is emphasised (semibold, accented glyph), so the column says where the
    /// pane is as well as where it could go.
    @Test func theCurrentFolderIsMarked() throws {
        let listed = rows(RememberedFolders(recents: [], pinned: ["Work"], rootIsAvailable: true))
        let elsewhere = try #require(render(rows: listed, current: "Somewhere/Else"))
        let onIt = try #require(render(rows: listed, current: "Work"))
        #expect(inked(onIt) != inked(elsewhere),
                "the row renders identically whether or not the pane is on it")
    }
}

/// Where the sidebar exists, and where it is showing: two different questions. A menu item asking
/// the second could never switch the column on; a refresh asking the first would `stat` a provider
/// root in every workspace.
///
/// Every case passes `enabled:` explicitly, since the defaulted `true && x` asserts nothing about
/// the rule; `TheSidebarIsOn` checks the switch through the defaulted calls. Which workspaces
/// support it is `Workspace.supportsFolderSidebar`, which this module can't see, so the caller
/// supplies the verdict; `WorkspaceSidebarSupportTests` in the app target pins that mapping.
@Suite struct FolderSidebarVisibilityTests {

    /// Collapsed panes get no sidebar: collapsing asks for maximum room, and a 180pt column beside a
    /// 34pt spine takes it back. Folded into `appliesTo`, not checked at the view, so the toolbar
    /// button, menu item and refresh guard can't disagree.
    @Test func collapsedPanesGetNoSidebarAnywhere() {
        #expect(!FolderSidebarModel.appliesTo(workspaceSupportsSidebar: true,
                                              panesCollapsed: true, enabled: true))
        #expect(!FolderSidebarModel.isShowing(workspaceSupportsSidebar: true, panesCollapsed: true,
                                              preference: true, enabled: true))
    }

    /// A workspace whose sidebar outlives the collapse keeps it. Edit's Text Files list follows the
    /// folded pane's folder, so the sidebar is useful with no pane open. All three questions agree,
    /// and a collapsed pane greys nothing there.
    @Test func aSidebarThatOutlivesTheCollapseStaysBesideAFoldedPane() {
        #expect(FolderSidebarModel.appliesTo(workspaceSupportsSidebar: true, panesCollapsed: true,
                                             outlivesCollapse: true, enabled: true))
        #expect(FolderSidebarModel.isShowing(workspaceSupportsSidebar: true, panesCollapsed: true,
                                             outlivesCollapse: true, preference: true, enabled: true))
        #expect(FolderSidebarModel.unavailableReason(workspaceSupportsSidebar: true, panesCollapsed: true,
                                                     outlivesCollapse: true, enabled: true) == nil)
    }

    /// The exemption is from the collapse rule only: it doesn't override a workspace without a
    /// sidebar, the preference, or the switch.
    @Test func outlivingTheCollapseOverridesNothingElse() {
        #expect(!FolderSidebarModel.appliesTo(workspaceSupportsSidebar: false, panesCollapsed: true,
                                              outlivesCollapse: true, enabled: true))
        #expect(!FolderSidebarModel.appliesTo(workspaceSupportsSidebar: true, panesCollapsed: true,
                                              outlivesCollapse: true, enabled: false))
        #expect(!FolderSidebarModel.isShowing(workspaceSupportsSidebar: true, panesCollapsed: true,
                                              outlivesCollapse: true, preference: false, enabled: true))
    }
}

/// The switch is on, asserted where it is decided. One line of production code,
/// `FolderSidebarModel.isEnabled`, decides whether the column, its menu item, toolbar button and
/// chord are reachable, and it could be flipped by someone who reads it as a leftover flag.
@Suite struct TheSidebarIsOn {

    @Test func theSwitchIsOn() {
        #expect(FolderSidebarModel.isEnabled,
                "the sidebar is v4.4's item #13 — turning this off takes the column, the ⌃⌘S chord, the View item and the toolbar button with it, and leaves four surfaces advertising a column that cannot appear")
    }

    /// Every question the app asks, in the combinations that decide the column. Through the
    /// defaulted spellings, the calls `ContentView`, `shortcutFolderSidebar` and the toolbar button
    /// make, so this fails if the switch is turned off. `appliesTo` ignores the preference by design
    /// (it answers "can this workspace have a column", which enables the menu item and button);
    /// `isShowing` consults both.
    @Test(arguments: [true, false], [true, false])
    func theColumnIsReachableExactlyWhereSupportedAndOnlyWhenAskedFor(supported: Bool, preference: Bool) {
        #expect(FolderSidebarModel.appliesTo(workspaceSupportsSidebar: supported) == supported)
        #expect(FolderSidebarModel.isShowing(workspaceSupportsSidebar: supported, preference: preference)
                == (supported && preference))
    }
}

/// What a greyed-out sidebar toggle says about itself. There are two ways to be unavailable, with
/// different remedies ("go somewhere else", "expand the pane you collapsed"), so one sentence can't
/// serve both. Neither may enumerate workspaces, since that goes stale when the set changes.
@Suite struct SidebarUnavailableReasonTests {

    @Test func anAvailableSidebarHasNoReason() {
        #expect(FolderSidebarModel.unavailableReason(workspaceSupportsSidebar: true,
                                                     panesCollapsed: false, enabled: true) == nil,
                "a reason is offered for a sidebar that is available — the tooltip would explain a state the user is not in")
    }

    /// It names no workspace on purpose: an enumeration must be re-edited every time the set
    /// changes, and nothing fails when it isn't.
    @Test func anUnsupportedWorkspaceSaysSoWithoutEnumerating() throws {
        let reason = try #require(FolderSidebarModel.unavailableReason(
            workspaceSupportsSidebar: false, panesCollapsed: false, enabled: true))
        for named in ["Browse", "Organize", "Storage", "Compare"] {
            #expect(!reason.contains(named),
                    "the reason names \(named) — an enumeration here goes stale silently: “\(reason)”")
        }
        #expect(reason.localizedCaseInsensitiveContains("sidebar"))
    }

    @Test func collapsedPanesGetTheRemedyTheyCanActOn() throws {
        let reason = try #require(FolderSidebarModel.unavailableReason(
            workspaceSupportsSidebar: true, panesCollapsed: true, enabled: true))
        #expect(reason.contains("panes"))
        #expect(!reason.contains("Browse"), "a collapsed pane was told to change workspace, which would not help")
    }

    /// Both at once resolves to the workspace: a collapsed pane in an unsupported workspace stays
    /// unavailable after expanding, so telling the user to show their panes would change nothing.
    @Test func theWorkspaceReasonWinsWhenBothApply() throws {
        let reason = try #require(FolderSidebarModel.unavailableReason(
            workspaceSupportsSidebar: false, panesCollapsed: true, enabled: true))
        #expect(!reason.contains("Show the panes"),
                "a pane the user cannot fix by expanding was told to expand it")
        #expect(reason.contains("not available here"))
    }

    /// With the whole feature switched off, the reason must not blame the user's workspace: every
    /// workspace would be equally wrong.
    @Test func aDisabledFeatureDoesNotBlameTheWorkspace() throws {
        let reason = try #require(FolderSidebarModel.unavailableReason(
            workspaceSupportsSidebar: true, panesCollapsed: false, enabled: false))
        #expect(!reason.contains("Show the panes"))
    }
}

/// The caption saying which pane Compare's sidebar acts on. Compare re-roots whichever pane holds
/// the selection, defaulting to the left, and with nothing selected nothing else on screen says
/// where a click lands. A wrong guess resets that pane's column stack, and navigation has no undo.
@Suite struct SidebarTargetTests {

    /// The header names the side, not a source: comparing a source against itself is ordinary, so a
    /// provider name can't separate the panes. The rows come from every enabled source
    /// (`refreshFolderSidebarRows`), so naming one would falsely scope them to it; the side is the
    /// only thing true of every row.
    @Test func theHeaderNamesTheSide() {
        #expect(SidebarTarget(targetsRight: false).openingDescription == "Opens on Left")
        #expect(SidebarTarget(targetsRight: true).openingDescription == "Opens on Right")
    }

    /// The glyph is a side indicator, not a direction: both panes sit to the right of this column,
    /// so an arrow would point the same way for both.
    @Test func theTwoSidesCarryDifferentGlyphs() {
        let left = SidebarTarget.symbol(targetsRight: false)
        let right = SidebarTarget.symbol(targetsRight: true)
        #expect(left != right)
        #expect(!left.contains("arrow") && !right.contains("arrow"),
                "the glyph is an arrow — both panes are to the right of this column, so it points the same way for either")
    }

    /// The line sits under the list, not over it: above the first row it would push Favorites down
    /// in Compare alone, and the column's top would stop lining up with other workspaces'.
    @Test func theLineSitsUnderTheList() throws {
        let code = try SidebarRowSideMenuTests.source()
        let body = try #require(code.range(of: "public var body: some View {"),
                                "cannot find the column's body — this scan is aimed at nothing")
        let list = try #require(code.range(of: "ScrollView {", range: body.upperBound..<code.endIndex))
        let line = try #require(code.range(of: "if let target { targetFooter(target) }",
                                           range: body.upperBound..<code.endIndex),
                                "the column no longer draws the side line")
        #expect(list.upperBound < line.lowerBound,
                "the side line is drawn before the list — Favorites no longer starts the column in Compare")
    }
}

/// "Open in Left Pane" / "Open in Right Pane" on a row, the per-row companion to the target
/// control. The control is a mode, saying where every click lands, which is the wrong shape for
/// "this one folder, over there". Asserted on the view's source rather than by opening a real menu,
/// which would test AppKit.
@Suite struct SidebarRowSideMenuTests {

    /// Comments stripped, as every source scan here does: doc comments quote the labels, and a
    /// scan that reads them asserts what the code says about itself, not what it does.
    static func source() throws -> String {
        try DashboardSource.read("FolderSidebar.swift", codeOnly: true, atLeast: 3000)
    }

    /// Remove from Recents is offered only on a recent. A favorite has its own removal verb just
    /// above, and "Remove from Recents" on it would name a list the row isn't in. Enabled on an
    /// unavailable row, unlike the items above it: a stale recent (source asleep, folder renamed
    /// away) is exactly the one worth removing.
    @Test func removeFromRecentsIsGatedOnTheRecentsGroupAndNotDisabled() throws {
        let code = try Self.source()
        let gate = try #require(code.range(of: "if row.group == .recents {"),
                                "the item is no longer gated on the group — it draws on favorites too")
        let body = String(code[gate.upperBound...].prefix(200))
        #expect(body.contains("Button(Self.forgetItemTitle(recentsMode)) { onForgetRecent(row) }"),
                "the gate no longer holds the Remove from Recents item — this scan is aimed at nothing")
        #expect(!body.contains(".disabled("),
                "the item now refuses on an unavailable row, which is the row it exists for")
    }

    /// The item names the list the heading shows, never one the user can't see.
    @Test func removeItemNamesTheShownList() {
        #expect(FolderSidebarView.forgetItemTitle(.recents) == "Remove from Recents")
        #expect(FolderSidebarView.forgetItemTitle(.revisited) == "Remove from Revisited")
        #expect(FolderSidebarView.forgetItemTitle(.frequent) == "Remove from Frequent")
    }

    /// Only where there are two panes: `target` is nil outside Compare, and offering a left and a
    /// right pane where there is one would offer a choice that doesn't exist.
    ///
    /// And the menu doesn't move the target. Picking a side for one folder says nothing about the
    /// next, and silently re-aiming would be an unseen mode change that also moves the action bar,
    /// lens scans and pane-scoped chords. Checks for any way to move the focused pane, with a
    /// premise guard so a renamed member can't make it pass over an empty window.
    @Test func theSideItemsAppearOnlyWithATargetAndDoNotRepointTheSidebar() throws {
        let code = try Self.source()
        let items = try #require(code.range(of: "private func sideItems("))
        let body = String(code[items.upperBound...].prefix(600))
        #expect(body.contains("if target != nil"),
                "the side items are not gated on there being two panes")
        try #require(body.contains("open("), "the sideItems body was not found — this scan is vacuous")
        for repointer in ["onPickSide", "noteFocusedPane", "onFocusPane"] {
            #expect(!body.contains(repointer),
                    "opening one folder on the other side also re-aimed the sidebar, via \(repointer)")
        }
    }

    /// Both row kinds offer it: a folder row and a Locations row are both things you might want on
    /// the other side.
    @Test func bothRowKindsOfferIt() throws {
        let code = try Self.source()
        #expect(code.contains("sideItems(enabled: canOpen) { onOpenRowOnSide(row, $0) }"),
                "folder rows do not offer the side items")
        #expect(code.contains("sideItems(enabled: source.isAvailable) { onOpenSourceOnSide(source, $0) }"),
                "Locations rows do not offer the side items")
    }

    /// Not the Trash: it is `revealOnly` (opens in Finder, never a pane's scope), so it can't be
    /// opened in a pane.
    @Test func theTrashOffersNoPaneItems() throws {
        #expect(try Self.source().contains("if source.state != .revealOnly {"),
                "the Trash row offers to open in a pane, which it can never do")
    }

    /// Left before Right, matching the control above it and the panes themselves.
    @Test func leftIsOfferedFirst() throws {
        let code = try Self.source()
        let left = try #require(code.range(of: "\"Open in Left Pane\""))
        let right = try #require(code.range(of: "\"Open in Right Pane\""))
        #expect(left.lowerBound < right.lowerBound)
    }
}

/// The recents-drag arming rule, read off the view's source. A recents drag becomes a favorite, a
/// persisted change, so it arms only once the pointer reaches the Favorites band; otherwise any
/// ≥5pt slip on a recent would favorite it. The rule lives in the gesture's `onChanged`, which no
/// test can drive (a `DragGesture` needs a real event stream), so this scans the file as
/// `SidebarRowSideMenuTests` does, with premise anchors so a renamed member fails loudly.
/// `SidebarInsertionIndicatorTests` proves an unarmed drag paints no line; these prove the release
/// and the overlay consult the same bit.
@Suite struct SidebarRecentsDragArmingScanTests {

    /// The rule itself: armed only above Locations' measured top, with `.infinity` when unmeasured
    /// so an unmeasured column stays armed rather than dead.
    @Test func theArmingRuleComparesAgainstLocationsTop() throws {
        let code = try SidebarRowSideMenuTests.source()
        #expect(code.contains("let willDrop = section != .recents"),
                "the arming rule is gone, or no longer exempts within-section drags")
        #expect(code.contains("value.location.y < (sectionTops[.locations] ?? .infinity)"),
                "the boundary is no longer Locations' measured top with an armed fallback — an unmeasured column would go dead, or a slip would commit")
    }

    /// The release consults the bit: `onEnded`'s `.recents` case guards on `willDrop` before
    /// `onFavoriteRecent`. An unarmed release is a cancel, and this guard is all that stands between
    /// a sloppy click and a persisted change.
    @Test func theRecentsDropGuardsOnTheArmedBit() throws {
        let code = try SidebarRowSideMenuTests.source()
        let ended = try #require(code.range(of: ".onEnded {"),
                                 "the drag's onEnded is gone — this scan is aimed at nothing")
        let recents = try #require(code.range(of: "case .recents:", range: ended.upperBound..<code.endIndex),
                                   "onEnded no longer switches into a .recents case")
        let commit = try #require(code.range(of: "onFavoriteRecent(", range: recents.upperBound..<code.endIndex),
                                  "the recents drop no longer commits at all — this scan is aimed at nothing")
        let branch = code[recents.upperBound..<commit.lowerBound]
        #expect(branch.contains("guard inFlight.willDrop else { return }"),
                "the recents drop does not guard on willDrop — every ≥5pt slip on a recent favorites it irrevocably")
    }

    /// The indicator consults the same bit, so line and release can't disagree: the line promises
    /// that releasing commits, and an unarmed drag must promise nothing.
    @Test func theIndicatorOverlayGuardsOnTheSameBit() throws {
        let code = try SidebarRowSideMenuTests.source()
        #expect(code.contains("if let drag, drag.willDrop, !collapsed.contains(dropTarget(for: drag.section))"),
                "the insertion line no longer reads willDrop — it would promise a commit the release refuses, or vice versa")
    }
}

/// The provider-settings door on a source row: offered only where the host supplied a title,
/// placed above the consequential tail, and never confirmed, since it changes nothing in SyncCloud.
/// Source scans, reusing `SidebarRowSideMenuTests`' comment-stripped read.
@Suite struct SidebarProviderSettingsMenuTests {

    /// The door opens another app's surface and changes nothing here, so it doesn't go through
    /// `arm(_:)`; a confirmation would class it with Eject and Remove.
    @Test func theDoorOpensDirectlyWithoutArmingAConfirmation() throws {
        let code = try SidebarRowSideMenuTests.source()
        let gate = try #require(code.range(of: "if let title = providerSettingsTitles[source.id]"),
                                "the item's gate was not found — this scan is vacuous")
        let body = String(code[gate.upperBound...].prefix(120))
        try #require(body.contains("onOpenProviderSettings(source)"),
                     "the item's action was not found — this scan is vacuous")
        #expect(!body.contains("arm("),
                "the provider-settings door arms a confirmation it has nothing to confirm")
    }

    /// Above Eject and Remove, which end the menu so a mis-aimed click lands on something mild;
    /// showing another app's window is milder than either.
    @Test func theDoorSitsAboveTheConsequentialTail() throws {
        let code = try SidebarRowSideMenuTests.source()
        let door = try #require(code.range(of: "providerSettingsTitles[source.id]"))
        let eject = try #require(code.range(of: "Button(\"Eject \\(source.name)…\")"))
        #expect(door.lowerBound < eject.lowerBound,
                "the provider-settings door has moved below the consequential tail")
    }
}
