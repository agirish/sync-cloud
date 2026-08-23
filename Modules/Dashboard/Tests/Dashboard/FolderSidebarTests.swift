import Testing
import SwiftUI
import AppKit
import Design
@testable import Dashboard

/// **Browse's remembered-folders sidebar.**
@Suite struct FolderSidebarModelTests {

    /// The provider's display name — what a top-level folder is "in".
    static let rootName = "iCloud"

    private func remembered(recents: [String] = [], pinned: [String] = [],
                            rootIsAvailable: Bool = true) -> RememberedFolders {
        RememberedFolders(recents: recents, pinned: pinned, rootIsAvailable: rootIsAvailable)
    }

    /// Pins are curated and recents are a rolling eight, so the curated list goes first — and the
    /// order within each is the store's, which is most-recent-first for recents.
    @Test func pinsComeFirstAndEachListKeepsTheStoresOrder() {
        let rows = FolderSidebarModel.rows(
            remembered(recents: ["Downloads", "Notes"], pinned: ["Work", "Archive"]), rootName: Self.rootName)
        #expect(rows.map(\.name) == ["Work", "Archive", "Downloads", "Notes"])
        #expect(rows.map(\.group) == [.pinned, .pinned, .recents, .recents])
    }

    /// The row reads the folder's own name, not the path that reaches it.
    @Test func aRowIsNamedForItsFolder() {
        let rows = FolderSidebarModel.rows(remembered(pinned: ["Clients/Acme/Legal"]), rootName: Self.rootName)
        #expect(rows.first?.name == "Legal")
        #expect(rows.first?.relativePath == "Clients/Acme/Legal")
    }

    /// **The case the ⌘K palette had to be rebuilt twice to see.** Two folders with the same leaf
    /// are two rows that read identically, and one of them goes somewhere the user did not mean.
    @Test func twoFoldersSharingALeafNameEachShowTheirParent() {
        let rows = FolderSidebarModel.rows(remembered(pinned: ["Clients/Legal", "Archive/Legal"]), rootName: Self.rootName)
        #expect(rows.map(\.detail) == ["Clients", "Archive"])
    }

    /// **Found by rendering it.** A top-level folder has no parent path, so a collision between
    /// `Clients/Legal` and a root-level `Legal` drew one qualified row and one bare one — two rows
    /// reading "Legal" where only one says which. The provider's own name is what a top-level
    /// folder is in, and it is the convention `StorageLensView.displayFolder` already uses.
    @Test func aTopLevelFolderInACollisionIsQualifiedByTheProvider() {
        let rows = FolderSidebarModel.rows(remembered(recents: ["Legal"], pinned: ["Clients/Legal"]),
                                           rootName: Self.rootName)
        #expect(rows.map(\.detail) == ["Clients", "iCloud"])
    }

    /// Counted across both groups, because the reader is looking at one column: a pin and a recent
    /// can collide as easily as two pins.
    @Test func theCollisionIsCountedAcrossPinsAndRecentsTogether() {
        let rows = FolderSidebarModel.rows(remembered(recents: ["Archive/Legal"], pinned: ["Clients/Legal"]), rootName: Self.rootName)
        #expect(rows.map(\.detail) == ["Clients", "Archive"])
    }

    /// And the other direction, which is what stops every row growing a second line: a name nothing
    /// else shares needs no disambiguation, and a top-level folder has no parent to show anyway.
    @Test func aNameNothingSharesShowsNoParent() {
        let rows = FolderSidebarModel.rows(remembered(pinned: ["Clients/Legal", "Archive/Invoices"]), rootName: Self.rootName)
        #expect(rows.allSatisfy { $0.detail == nil })
        #expect(FolderSidebarModel.rows(remembered(pinned: ["Work", "Work extra"]), rootName: Self.rootName)
                .allSatisfy { $0.detail == nil })
    }

    /// A root that did not answer means "everything remembered, unchecked" — the rows stay and are
    /// marked, because deleting a pin over a sleeping drive costs the user their pins.
    @Test func aSleepingRootLeavesEveryRowListedAndUnavailable() {
        let rows = FolderSidebarModel.rows(
            remembered(recents: ["Notes"], pinned: ["Work"], rootIsAvailable: false), rootName: Self.rootName)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.isAvailable })
        #expect(rows.allSatisfy { !FolderSidebarModel.canOpen($0) })
    }

    @Test func aLiveRootLeavesEveryRowOpenable() {
        let rows = FolderSidebarModel.rows(remembered(pinned: ["Work"]), rootName: Self.rootName)
        #expect(rows.allSatisfy { FolderSidebarModel.canOpen($0) })
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

    /// The two ids a `ForEach` runs on cannot collide across the groups — the same folder can be
    /// pinned in one install and recent in another, and a store bug that let it be both would
    /// otherwise crash the list rather than draw it twice.
    @Test func rowIdsAreUniqueEvenIfAFolderAppearsInBothLists() {
        let rows = FolderSidebarModel.rows(remembered(recents: ["Work"], pinned: ["Work"]), rootName: Self.rootName)
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}

/// **The column, rendered.** Geometry cannot say whether a row is dimmed or which one is current.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct FolderSidebarRenderTests {

    static let canvas = CGSize(width: FolderSidebarView.width, height: 320)

    private func render(rows: [FolderSidebarRow], current: String = "") -> NSBitmapImageRep? {
        let subject = FolderSidebarView(rows: rows, currentRelativePath: current,
                                        accent: LiquidGlassHue.blue.accentColor,
                                        onOpen: { _, _ in }, onTogglePin: { _ in })
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
        FolderSidebarModel.rows(remembered, rootName: "iCloud")
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
        #expect(inked(try #require(render(rows: []))) > 200)
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
/// Every case below passes `enabled:` rather than relying on the default, because the default is
/// `false` while the column is held for v4.3 and `false && anything` would assert nothing about
/// either rule. `TheSidebarIsHeldForV43` asserts the hold itself.
@Suite struct FolderSidebarVisibilityTests {

    @Test func theSidebarBelongsToBrowseAlone() {
        #expect(FolderSidebarModel.appliesTo(isBrowse: true, enabled: true))
        #expect(!FolderSidebarModel.appliesTo(isBrowse: false, enabled: true))
    }

    /// **The item stays live on Browse with the column switched off**, because it is what switches
    /// it on. This is the assertion that stops the two rules being collapsed into one.
    @Test func theToggleIsStillAvailableWhileTheColumnIsHidden() {
        #expect(FolderSidebarModel.appliesTo(isBrowse: true, enabled: true))
        #expect(!FolderSidebarModel.isShowing(isBrowse: true, preference: false, enabled: true))
    }

    @Test func theColumnShowsOnlyOnBrowseAndOnlyWhenAskedFor() {
        #expect(FolderSidebarModel.isShowing(isBrowse: true, preference: true, enabled: true))
        #expect(!FolderSidebarModel.isShowing(isBrowse: false, preference: true, enabled: true))
        #expect(!FolderSidebarModel.isShowing(isBrowse: false, preference: false, enabled: true))
    }
}

/// **The v4.2 hold, asserted where it is decided.**
///
/// The column, its menu item and its chord were all built and reviewed, and then held for v4.3 so
/// it can arrive as a Finder-shaped sidebar rather than as two ungrouped lists. What makes that a
/// hold rather than a preference is that **no answer the app can give reaches the column** — which
/// is one line of production code and therefore one line away from being undone by someone tidying
/// up an "unused" constant.
@Suite struct TheSidebarIsHeldForV43 {

    @Test func theHoldIsOn() {
        #expect(FolderSidebarModel.isEnabled == false,
                "the sidebar is scheduled for v4.3 — turning this on ships half of it, and the menu item and ⌃⌘S it needs are not there to be found")
    }

    /// **Every question the app actually asks, in every combination, answers no.**
    ///
    /// The defaulted spellings and not the injected ones: these are the calls `ContentView` and
    /// `shortcutFolderSidebar` make, so this is the check that the hold reaches the host rather
    /// than only the constant.
    ///
    /// **`preference: true` is the case that matters and it is why this is parameterised.**
    /// `browseSidebarVisible` still exists and still defaults to `true`, so everyone who ran a
    /// build while the item existed — and everyone who never touched it — has "yes" written in
    /// their defaults. If the hold ever moved to the preference instead (re-defaulting it to
    /// `false`, say), the column would come back for exactly those people and for nobody else,
    /// which is the worst of both. That case is `(isBrowse: true, preference: true)` below rather
    /// than a test of its own, because a second test asserting the same expression is one more
    /// place to update and no more coverage.
    @Test(arguments: [true, false], [true, false])
    func nothingReachesTheColumn(isBrowse: Bool, preference: Bool) {
        #expect(!FolderSidebarModel.appliesTo(isBrowse: isBrowse))
        #expect(!FolderSidebarModel.isShowing(isBrowse: isBrowse, preference: preference))
    }
}
