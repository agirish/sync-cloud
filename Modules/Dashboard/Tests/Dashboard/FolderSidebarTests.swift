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
@Suite struct FolderSidebarRenderTests {

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
    /// More rows paint more.
    ///
    /// Against a **shorter list**, not against the empty state — measured, and the first cut had it
    /// backwards: the empty state is two sentences of explanation and out-inks a pair of one-word
    /// rows almost three to one (1535 against 685). "Rows paint more than nothing" is not the claim
    /// worth making anyway; this one fails if a row stops drawing.
    @Test func dumpForInspection() throws {
        let listed = rows(RememberedFolders(recents: ["Downloads", "Q3 Report", "Legal"],
                                            pinned: ["Work", "Clients/Legal"], rootIsAvailable: true))
        let rep = try #require(render(rows: listed, current: "Work"))
        try rep.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: "/private/tmp/claude-501/-Users-abhishek-Projects-SyncCloud/e3acceb2-2dca-4195-9255-571f7a997cf1/scratchpad/sidebar.png"))
    }

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
