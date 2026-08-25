import Testing
import SwiftUI
import AppKit
import Design
@testable import Dashboard

/// **Browse's remembered-folders sidebar.**
@Suite struct FolderSidebarModelTests {

    /// The provider's display name — what a top-level folder is "in", and what the badge reads.
    static let rootName = "iCloud"
    static let root = "/iCloud"

    /// One source, which is the shape most of these assertions are about — qualification and
    /// ordering do not need two accounts to be wrong.
    private func one(recents: [String] = [], favorites: [String] = [],
                     isAvailable: Bool = true) -> [FolderSidebarRow] {
        FolderSidebarModel.rows(
            sources: [.init(root: Self.root, name: Self.rootName,
                            favorites: favorites, isAvailable: isAvailable)],
            recents: recents.map { RememberedVisit(root: Self.root, relativePath: $0,
                                                   name: ($0 as NSString).lastPathComponent,
                                                   visitedAt: nil) })
    }

    /// Favorites are curated and recents are a rolling eight, so the curated list goes first — and
    /// the order within each is the store's.
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

    /// **The case the ⌘K palette had to be rebuilt twice to see.** Two folders with the same leaf
    /// are two rows that read identically, and one of them goes somewhere the user did not mean.
    @Test func twoFoldersSharingALeafNameEachShowTheirParent() {
        #expect(one(favorites: ["Clients/Legal", "Archive/Legal"]).map(\.detail) == ["Clients", "Archive"])
    }

    /// **Found by rendering it.** A top-level folder has no parent path, so a collision between
    /// `Clients/Legal` and a root-level `Legal` drew one qualified row and one bare one — two rows
    /// reading "Legal" where only one says which. The provider's own name is what a top-level
    /// folder is in.
    @Test func aTopLevelFolderInACollisionIsQualifiedByTheProvider() {
        #expect(one(recents: ["Legal"], favorites: ["Clients/Legal"]).map(\.detail) == ["Clients", "iCloud"])
    }

    /// Counted across both groups, because the reader is looking at one column: a favorite and a
    /// recent can collide as easily as two favorites.
    @Test func theCollisionIsCountedAcrossFavoritesAndRecentsTogether() {
        #expect(one(recents: ["Archive/Legal"], favorites: ["Clients/Legal"]).map(\.detail) == ["Clients", "Archive"])
    }

    /// And the other direction, which is what stops every row growing a second line: a name nothing
    /// else shares needs no disambiguation.
    @Test func aNameNothingSharesShowsNoParent() {
        #expect(one(favorites: ["Clients/Legal", "Archive/Invoices"]).allSatisfy { $0.detail == nil })
        #expect(one(favorites: ["Work", "Work extra"]).allSatisfy { $0.detail == nil })
    }

    /// A root that did not answer means "everything remembered, unchecked" — the rows stay and are
    /// marked, because deleting a favorite over a sleeping drive costs the user their favorites.
    @Test func aSleepingRootLeavesEveryRowListedAndUnavailable() {
        let rows = one(recents: ["Notes"], favorites: ["Work"], isAvailable: false)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.isAvailable })
        #expect(rows.allSatisfy { !FolderSidebarModel.canOpen($0) })
    }

    @Test func aLiveRootLeavesEveryRowOpenable() {
        #expect(one(favorites: ["Work"]).allSatisfy { FolderSidebarModel.canOpen($0) })
    }

    /// ⌘ opens a new tab; nothing else does. ⌥ in particular must not — it is the pane-mirroring
    /// modifier everywhere else in the app, and it is banned from chords for the reveal's sake.
    @Test func onlyCommandOpensANewTab() {
        #expect(FolderSidebarModel.opensInNewTab(.command))
        #expect(FolderSidebarModel.opensInNewTab([.command, .shift]))
        #expect(!FolderSidebarModel.opensInNewTab([]))
        #expect(!FolderSidebarModel.opensInNewTab(.option))
        #expect(!FolderSidebarModel.opensInNewTab(.shift))
    }

    /// The ids a `ForEach` runs on cannot collide across the groups — the same folder can be a
    /// favorite in one install and recent in another, and a store bug that let it be both would
    /// otherwise crash the list rather than draw it twice.
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

    /// **The same relative path under two sources is two folders**, and both must survive the
    /// `ForEach` — the root is part of the row's identity for exactly this.
    @Test func theSamePathUnderTwoSourcesIsTwoRows() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["Health"]),
                      Self.source("/Dropbox", "Dropbox", ["Health"])],
            recents: [])
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2, "two sources' Health folders share one id — one would not draw")
        #expect(rows.map(\.root) == ["/iCloud", "/Dropbox"])
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

    /// A source contributing only a *recent* still counts toward the badge — otherwise the one
    /// column would show badges on some rows and not others depending on which list a folder is in.
    @Test func aSourceContributingOnlyARecentStillCountsAsASecondSource() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/iCloud", "iCloud", ["Health"]),
                      Self.source("/Dropbox", "Dropbox", [])],
            recents: [Self.visit("/Dropbox", "Shared Docs")])
        #expect(rows.allSatisfy { $0.sourceName != nil }, "some rows are badged and some are not")
    }

    /// **Both disambiguators at once**, which is the case neither alone can carry: two rows reading
    /// `Legal`, from two accounts, one nested and one top-level.
    @Test func aRowCanNeedBothItsBadgeAndItsParent() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/Drive", "Drive", ["Clients/Legal"]),
                      Self.source("/iCloud", "iCloud", ["Legal"])],
            recents: [])
        #expect(rows.map(\.detail) == ["Clients", "iCloud"])
        #expect(rows.map(\.sourceName) == ["Drive", "iCloud"])
    }

    /// Recents arrive already ordered by the store and are not re-sorted here — the ordering rule
    /// needs a clock and lives in `FolderJumpStore.mostRecentAcrossRoots`, which is where it is
    /// tested. Two rules for one order is how they come to disagree.
    @Test func recentsKeepTheOrderTheStoreGaveThem() {
        let rows = FolderSidebarModel.rows(
            sources: [Self.source("/a", "A", []), Self.source("/b", "B", [])],
            recents: [Self.visit("/b", "Second"), Self.visit("/a", "First")])
        #expect(rows.map(\.name) == ["Second", "First"])
    }

    /// **A recent whose whole source has gone is dropped, not drawn unavailable.** A sleeping drive
    /// is a source that exists and is not answering; a source that has been removed from Settings
    /// is one the app can no longer say anything about, including whether the folder is still
    /// there.
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
}

/// **The column, rendered.** Geometry cannot say whether a row is dimmed or which one is current.
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

    /// Pixels differing from the background — "something is painted here".
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

    /// More rows paint more.
    ///
    /// Against a **shorter list**, not against the empty state — measured, and the first cut had it
    /// backwards: the empty state is two sentences of explanation and out-inks a pair of one-word
    /// rows almost three to one (1535 against 685). "Rows paint more than nothing" is not the claim
    /// worth making anyway; this one fails if a row stops drawing.
    @Test func eachRowPaints() throws {
        let one = try #require(render(rows: rows(RememberedFolders(
            recents: [], pinned: ["Work"], rootIsAvailable: true))))
        let four = try #require(render(rows: rows(RememberedFolders(
            recents: ["Downloads", "Notes"], pinned: ["Work", "Archive"], rootIsAvailable: true))))
        #expect(inked(four) > inked(one) + 100,
                "four rows paint no more than one — \(inked(four)) vs \(inked(one))")
    }

    /// The empty state is not blank: a sidebar someone has just switched on with nothing in it must
    /// say how it fills, or it reads as broken.
    @Test func theEmptyStateSaysSomething() throws {
        #expect(inked(try #require(render(rows: []))) > 120)
    }

    /// **An unavailable row is dimmed, and the dimming is drawn rather than left to `.disabled`.**
    /// Under `hoverAffordance` a disabled button is not dimmed by the style at all, so this is the
    /// half that would silently be missing.
    @Test func anUnavailableRowIsVisiblyQuieter() throws {
        let live = try #require(render(rows: rows(RememberedFolders(
            recents: [], pinned: ["Work"], rootIsAvailable: true))))
        let asleep = try #require(render(rows: rows(RememberedFolders(
            recents: [], pinned: ["Work"], rootIsAvailable: false))))
        #expect(inked(asleep) < inked(live),
                "the unavailable row paints as strongly as the live one — \(inked(asleep)) vs \(inked(live))")
    }

    /// **The current row fills the column, and that is a claim about the hit area.**
    ///
    /// A `hoverAffordance` row is clickable only where it paints, so a row sized to its text would
    /// be readable across 180pt and clickable across forty. Nothing can hover a SwiftUI button from
    /// a test, but the current-folder highlight is drawn by the same modifier chain that carries
    /// the hit shape — so measuring how wide *it* paints measures the row.
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

    /// The current folder is emphasised — semibold and an accented glyph — so the column says where
    /// the pane is as well as where it could go.
    @Test func theCurrentFolderIsMarked() throws {
        let listed = rows(RememberedFolders(recents: [], pinned: ["Work"], rootIsAvailable: true))
        let elsewhere = try #require(render(rows: listed, current: "Somewhere/Else"))
        let onIt = try #require(render(rows: listed, current: "Work"))
        #expect(inked(onIt) != inked(elsewhere),
                "the row renders identically whether or not the pane is on it")
    }
}

/// **Where the sidebar exists, and where it is showing.** Two questions that read alike and are
/// not the same one — a menu item that asked the second could never be used to switch the column
/// on, and a refresh that asked the first would `stat` a provider root on every workspace.
///
/// Every case below passes `enabled:` rather than relying on the default, and keeps doing so now
/// that the default is `true`: `true && x` asserts nothing about the rule, exactly as `false && x`
/// asserted nothing while the column was held. `TheSidebarIsOn` asserts the switch itself, through
/// the defaulted spellings the app really calls.
///
/// **Which workspaces support it is `Workspace.supportsFolderSidebar`, not here** — this module
/// cannot see `Workspace`, so the caller supplies the verdict. `WorkspaceSidebarSupportTests` in
/// the app target pins the mapping; these pin what the verdict then means.
@Suite struct FolderSidebarVisibilityTests {

    @Test func aWorkspaceThatDoesNotSupportItGetsNoSidebar() {
        #expect(FolderSidebarModel.appliesTo(workspaceSupportsSidebar: true, enabled: true))
        #expect(!FolderSidebarModel.appliesTo(workspaceSupportsSidebar: false, enabled: true))
    }

    /// **The item stays live with the column switched off**, because it is what switches it on.
    /// This is the assertion that stops the two rules being collapsed into one.
    @Test func theToggleIsStillAvailableWhileTheColumnIsHidden() {
        #expect(FolderSidebarModel.appliesTo(workspaceSupportsSidebar: true, enabled: true))
        #expect(!FolderSidebarModel.isShowing(workspaceSupportsSidebar: true, preference: false, enabled: true))
    }

    @Test func theColumnShowsOnlyWhereSupportedAndOnlyWhenAskedFor() {
        #expect(FolderSidebarModel.isShowing(workspaceSupportsSidebar: true, preference: true, enabled: true))
        #expect(!FolderSidebarModel.isShowing(workspaceSupportsSidebar: false, preference: true, enabled: true))
        #expect(!FolderSidebarModel.isShowing(workspaceSupportsSidebar: false, preference: false, enabled: true))
    }

    /// **Collapsed panes get no sidebar.** Collapsing asks for maximum workspace room, and a 180pt
    /// column beside a 34pt spine takes 185 of it straight back.
    ///
    /// Folded into `appliesTo` rather than checked at the view, so the toolbar button, the menu
    /// item and the refresh guard cannot come to different answers — which is the entire reason
    /// this function exists rather than three `if`s.
    @Test func collapsedPanesGetNoSidebarAnywhere() {
        #expect(!FolderSidebarModel.appliesTo(workspaceSupportsSidebar: true,
                                              panesCollapsed: true, enabled: true))
        #expect(!FolderSidebarModel.isShowing(workspaceSupportsSidebar: true, panesCollapsed: true,
                                              preference: true, enabled: true))
    }

    /// The collapse rule must not be the ONLY thing tested — an implementation returning
    /// `!panesCollapsed` alone would pass the case above and be badly wrong.
    @Test func anExpandedPaneInASupportedWorkspaceDoesGetOne() {
        #expect(FolderSidebarModel.appliesTo(workspaceSupportsSidebar: true,
                                             panesCollapsed: false, enabled: true))
    }
}

/// **The switch is on, asserted where it is decided.**
///
/// The column, its menu item, its toolbar button and its chord were built for v4.2, held on
/// 2026-08-20 so it could arrive as a place rather than as two ungrouped lists, carried past v4.3,
/// and turned on for v4.4. This suite was `TheSidebarIsHeldForV43` and asserted the opposite; it is
/// inverted rather than deleted, because the thing worth pinning never changed — **one line of
/// production code decides whether any of this is reachable**, and it is one line away from being
/// flipped by someone who reads it as a leftover flag.
@Suite struct TheSidebarIsOn {

    @Test func theSwitchIsOn() {
        #expect(FolderSidebarModel.isEnabled,
                "the sidebar is v4.4's item #13 — turning this off takes the column, the ⌃⌘S chord, the View item and the toolbar button with it, and leaves four surfaces advertising a column that cannot appear")
    }

    /// **Every question the app actually asks, in the combinations that decide the column.**
    ///
    /// The defaulted spellings and not the injected ones: these are the calls `ContentView`,
    /// `shortcutFolderSidebar` and the toolbar button make, so this is the check that the switch
    /// reaches the host rather than only the constant.
    ///
    /// `appliesTo` ignores the preference by design — it answers *can this workspace have a
    /// column*, which is what the menu item and the toolbar button are enabled by — so it is
    /// asserted against the workspace verdict alone while `isShowing` consults both.
    ///
    /// Through the DEFAULTED spellings, deliberately: this is the one place that asks the question
    /// the app actually asks, so it fails if the shipped switch is ever turned back off.
    @Test(arguments: [true, false], [true, false])
    func theColumnIsReachableExactlyWhereSupportedAndOnlyWhenAskedFor(supported: Bool, preference: Bool) {
        #expect(FolderSidebarModel.appliesTo(workspaceSupportsSidebar: supported) == supported)
        #expect(FolderSidebarModel.isShowing(workspaceSupportsSidebar: supported, preference: preference)
                == (supported && preference))
    }

    /// `browseSidebarVisible` still defaults to `true`, and that is the answer everyone already has
    /// written in their defaults — from the v4.2 builds where the item briefly existed, and from
    /// never having touched it. The hold was deliberately placed on `isEnabled` rather than on the
    /// preference so that this stayed true: switching the column on shows it to everyone, rather
    /// than to the subset who happened to tick a box during one release.
    @Test func theColumnIsShownByDefaultWhereItIsSupported() {
        #expect(FolderSidebarModel.isShowing(workspaceSupportsSidebar: true, preference: true))
    }
}

/// **What a greyed-out sidebar toggle says about itself.**
///
/// Two ways to be unavailable, with different remedies — "go somewhere else" and "expand the pane
/// you collapsed" — so one sentence cannot serve both. Until 2026-08-24 there was one, reading
/// "The sidebar is available in Browse"; it was true when written and became wrong the moment
/// Organize and Storage got one, which is the failure mode of any wording that enumerates.
@Suite struct SidebarUnavailableReasonTests {

    @Test func anAvailableSidebarHasNoReason() {
        #expect(FolderSidebarModel.unavailableReason(workspaceSupportsSidebar: true,
                                                     panesCollapsed: false, enabled: true) == nil,
                "a reason is offered for a sidebar that is available — the tooltip would explain a state the user is not in")
    }

    /// **It names no workspace**, and that is the fix rather than an omission. The sentence has
    /// been wrong twice — "available in Browse", then "in Browse, Organize and Storage" — because
    /// an enumeration has to be re-edited every time the set changes and nothing makes it fail when
    /// it is not.
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

    /// **Both at once resolves to the workspace**, and that ordering is the point: a collapsed pane
    /// in Compare is unavailable twice over, and only one of those is something expanding a pane
    /// would fix. Telling that user to show their panes sends them to do work that changes nothing.
    @Test func theWorkspaceReasonWinsWhenBothApply() throws {
        let reason = try #require(FolderSidebarModel.unavailableReason(
            workspaceSupportsSidebar: false, panesCollapsed: true, enabled: true))
        #expect(!reason.contains("Show the panes"),
                "a pane the user cannot fix by expanding was told to expand it")
        #expect(reason.contains("not available here"))
    }

    /// With the whole feature switched off, the reason must not blame the workspace the user is in
    /// — every workspace would be equally wrong.
    @Test func aDisabledFeatureDoesNotBlameTheWorkspace() throws {
        let reason = try #require(FolderSidebarModel.unavailableReason(
            workspaceSupportsSidebar: true, panesCollapsed: false, enabled: false))
        #expect(!reason.contains("Show the panes"))
    }
}

/// **The caption that makes Compare's sidebar defensible.**
///
/// Compare re-roots whichever pane holds the selection, defaulting to the left — a rule that is
/// invisible in the case that matters most, since with nothing selected nothing on screen says
/// where a click will land. Getting it wrong resets that pane's column stack, and navigation has no
/// undo. So the column says which pane it acts on, and these pin what it must be able to say.
@Suite struct SidebarTargetTests {

    /// **The side is all there is, and that is the design.** Comparing a source against itself is
    /// ordinary here — the log shows "comparing Dropbox and Dropbox" — so a provider name could
    /// never separate the two panes. It carried one anyway until 2026-08-24; see
    /// `theHeaderNamesTheSide`.
    @Test func theSideSeparatesTwoPanesOnOneProvider() {
        #expect(SidebarTarget(targetsRight: false) != SidebarTarget(targetsRight: true),
                "the two panes are indistinguishable — the side must separate them")
        #expect(SidebarTarget.label(targetsRight: false) == "Left")
        #expect(SidebarTarget.label(targetsRight: true) == "Right")
    }

    /// **The header names the SIDE, and naming the source instead was a regression.**
    ///
    /// "Opens in Google Drive (Preserve)" shipped for one build and read as a scoping claim: the
    /// rows below come from EVERY enabled source (`refreshFolderSidebarRows`), so naming one says
    /// these are that source's folders, which is false. The side is the only thing true of every
    /// row in the column.
    @Test func theHeaderNamesTheSide() {
        #expect(SidebarTarget(targetsRight: false).openingDescription == "Opens on Left")
        #expect(SidebarTarget(targetsRight: true).openingDescription == "Opens on Right")
    }

    /// The two sides must not describe themselves identically — the whole line exists to separate
    /// them, and two panes on one source is ordinary here.
    @Test func theTwoSidesDescribeThemselvesDifferently() {
        #expect(SidebarTarget(targetsRight: false).openingDescription
                    != SidebarTarget(targetsRight: true).openingDescription)
    }

    /// **The glyph is a side indicator, not a direction.** Both panes sit to the RIGHT of this
    /// column, so `arrow.left` / `arrow.right` would point the same way for both and mean nothing.
    @Test func theTwoSidesCarryDifferentGlyphs() {
        let left = SidebarTarget.symbol(targetsRight: false)
        let right = SidebarTarget.symbol(targetsRight: true)
        #expect(left != right)
        #expect(!left.contains("arrow") && !right.contains("arrow"),
                "the glyph is an arrow — both panes are to the right of this column, so it points the same way for either")
    }
}

/// **"Open in Left Pane" / "Open in Right Pane" on a row**, the per-row companion to the target
/// control.
///
/// Both exist because they answer different questions. The control is a MODE — it says where every
/// click lands — and a mode is the wrong shape for "this one folder, over there": flipping it to
/// open one folder and flipping it back is exactly the friction the menu removes. Asserted on the
/// view's declared inputs rather than by opening a real menu, which would be testing AppKit.
@Suite struct SidebarRowSideMenuTests {

    static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Dashboard/FolderSidebar.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read FolderSidebar.swift — this scan would be vacuous")
        try #require(raw.count > 3000, "the file is implausibly short — the scan is vacuous")
        // **Comments stripped**, as every other source scan in this project does. `leftIsOfferedFirst`
        // failed against correct code because a doc comment 600 lines above the buttons quotes the
        // labels while explaining them — so the scan found the prose, not the menu. A scan that
        // reads comments is asserting about what the code SAYS about itself.
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    @Test func theScanCanSeeAKnownSymbol() throws {
        #expect(try Self.source().contains("private func sideItems("))
    }

    /// **Only where there are two panes.** `target` is nil outside Compare, and naming a left and a
    /// right pane in a workspace with one would offer a choice that does not exist.
    @Test func theSideItemsAppearOnlyWhenThereIsATarget() throws {
        let code = try Self.source()
        let items = try #require(code.range(of: "private func sideItems("))
        let body = String(code[items.upperBound...].prefix(600))
        #expect(body.contains("if target != nil"),
                "the side items are not gated on there being two panes")
    }

    /// **The menu does not move the target.** Picking a side for one folder is not a statement
    /// about the next one, and silently re-aiming from a context menu would be a mode change the
    /// user did not ask for and would not see — and the target now carries the action bar, the lens
    /// scans and the pane-scoped chords with it, so the mode change would be a large one.
    ///
    /// **This asserted the absence of `onPickSide`, and went vacuous when that was deleted.** The
    /// symbol no longer exists anywhere in the module, so the check could not fail for any edit at
    /// all. What can do the damage now is the column being handed a way to move the focused pane,
    /// so that is what is named — plus a premise guard, because a renamed member would otherwise
    /// take this straight back to passing over an empty window.
    @Test func theMenuDoesNotRepointTheSidebar() throws {
        let code = try Self.source()
        let items = try #require(code.range(of: "private func sideItems("))
        let body = String(code[items.upperBound...].prefix(600))
        try #require(body.contains("open("), "the sideItems body was not found — this scan is vacuous")
        for repointer in ["onPickSide", "noteFocusedPane", "onFocusPane"] {
            #expect(!body.contains(repointer),
                    "opening one folder on the other side also re-aimed the sidebar, via \(repointer)")
        }
    }

    /// Both row kinds offer it — a folder row and a Locations row are both things you might want on
    /// the other side, and offering it on one only would be arbitrary.
    @Test func bothRowKindsOfferIt() throws {
        let code = try Self.source()
        #expect(code.contains("sideItems(enabled: canOpen) { onOpenRowOnSide(row, $0) }"),
                "folder rows do not offer the side items")
        #expect(code.contains("sideItems(enabled: source.isAvailable) { onOpenSourceOnSide(source, $0) }"),
                "Locations rows do not offer the side items")
    }

    /// **Not the Trash.** It is `revealOnly` — it opens in Finder and is never a pane's scope — so
    /// offering to open it in a pane would name an action that cannot happen.
    @Test func theTrashOffersNoPaneItems() throws {
        #expect(try Self.source().contains("if source.state != .revealOnly {"),
                "the Trash row offers to open in a pane, which it can never do")
    }

    /// Left before Right, matching the control above it and the panes themselves. Trivial, and the
    /// kind of thing that reads as a bug when it is wrong.
    @Test func leftIsOfferedFirst() throws {
        let code = try Self.source()
        let left = try #require(code.range(of: "\"Open in Left Pane\""))
        let right = try #require(code.range(of: "\"Open in Right Pane\""))
        #expect(left.lowerBound < right.lowerBound)
    }
}
