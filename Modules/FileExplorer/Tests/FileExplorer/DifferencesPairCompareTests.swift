import AppKit
import Foundation
import Quartz
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The second host of the shared compare viewer: Differences' diff pane, the Duplicates compare
/// surface above its own verdict bar.
@MainActor
@Suite struct DifferencesPairCompareTests {

    private let paneNames = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")

    private func difference(type: FileDifference.DifferenceType = .differentDates,
                            enclosed: Int? = nil,
                            leftIsDirectory: Bool = false, rightIsDirectory: Bool = false,
                            left: String = "/L/Reports/Q3.pdf",
                            right: String = "/R/Reports/Q3.pdf") -> FileDifference {
        FileDifference(relativePath: "Reports/Q3.pdf", leftItemPath: left, rightItemPath: right,
                       type: type, action: .copyToRight, description: "differs",
                       enclosedItemCount: enclosed,
                       leftIsDirectory: leftIsDirectory, rightIsDirectory: rightIsDirectory)
    }

    // MARK: What can be compared

    @Test func aChangedFilePairIsComparable() throws {
        let pair = try #require(DifferencesPairCompare.pair(for: difference(),
                                                            paneNames: paneNames))
        #expect(pair.leftPath == "/L/Reports/Q3.pdf")
        #expect(pair.rightPath == "/R/Reports/Q3.pdf")
        #expect(pair.title == "Q3.pdf")
        #expect(pair.subtitle == "iCloud vs Dropbox")
    }

    /// A row missing on a side has nothing to compare. Offering it would open a pane that says "no
    /// longer at its scanned location", which is worse than not offering it.
    @Test func aRowMissingOnASideIsNotOffered() {
        #expect(DifferencesPairCompare.pair(for: difference(type: .missingOnLeft),
                                            paneNames: paneNames) == nil)
        #expect(DifferencesPairCompare.pair(for: difference(type: .missingOnRight),
                                            paneNames: paneNames) == nil)
    }

    /// A folder on either side is not offered: there is nothing to raster or diff, and Compare has a
    /// workspace for folders. The row's per-side folder facts decide, not `enclosedItemCount`, which
    /// an empty folder lacks.
    @Test func aFolderRowIsNotOffered() {
        #expect(DifferencesPairCompare.pair(for: difference(enclosed: 42, leftIsDirectory: true),
                                            paneNames: paneNames) == nil)
        #expect(DifferencesPairCompare.pair(for: difference(rightIsDirectory: true),
                                            paneNames: paneNames) == nil,
                "a folder with no count (empty) against a file is offered Compare…")
        #expect(DifferencesPairCompare.pair(for: difference(type: .nameConflict, leftIsDirectory: true,
                                                            rightIsDirectory: true),
                                            paneNames: paneNames) == nil,
                "a name-conflicted folder pair is offered Compare…")
    }

    /// The same, on rows the real engine builds: two empty folders whose names differ invisibly
    /// carry no count, and must still not be offered Compare….
    @Test func engineBuiltFolderRowsAreNotOffered() throws {
        let rows = EngineRows()
        #expect(DifferencesPairCompare.pair(for: try rows.nameConflictedFolders(), paneNames: paneNames) == nil)
        #expect(DifferencesPairCompare.pair(for: try rows.folderAgainstFile(folderHasContents: false),
                                            paneNames: paneNames) == nil)
    }

    /// A name conflict is two REAL items under names that differ only invisibly — exactly the pair
    /// a reader most wants side by side.
    @Test func aNameConflictIsComparable() {
        #expect(DifferencesPairCompare.pair(for: difference(type: .nameConflict),
                                            paneNames: paneNames) != nil)
    }

    /// Opening the same row twice is the same surface, not a second one sliding in over the first.
    @Test func thePairIdIsTheTwoPathsWhicheverOrderTheyArrive() {
        let a = DifferencePair.acrossPanes(leftPath: "/L/x", rightPath: "/R/x",
                                           leftPaneName: "A", rightPaneName: "B")
        let b = DifferencePair.acrossPanes(leftPath: "/R/x", rightPath: "/L/x",
                                           leftPaneName: "B", rightPaneName: "A")
        #expect(a.id == b.id)
    }

    // MARK: The facts come from a fresh stat

    private final class Fixture {
        let dir: URL
        let left: String
        let right: String
        init() throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DifferencesPairCompareTests-\(UUID().uuidString)")
            let l = dir.appendingPathComponent("L"), r = dir.appendingPathComponent("R")
            try FileManager.default.createDirectory(at: l, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            let one = l.appendingPathComponent("note.txt"), two = r.appendingPathComponent("note.txt")
            try Data("hello".utf8).write(to: one)
            try Data("hello there".utf8).write(to: two)
            left = one.path
            right = two.path
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
    }

    /// The facts come from a stat, not the row: `FileDifference` carries no dates, so a strip built
    /// from it would print "—" on both date rows.
    @Test func theFactsComeFromAFreshStatOfBothSides() async throws {
        let fixture = try Fixture()
        let pair = DifferencePair.acrossPanes(leftPath: fixture.left, rightPath: fixture.right,
                                              leftPaneName: "iCloud", rightPaneName: "Dropbox")
        let copies = await DifferencesPairCompare.copies(for: pair)
        #expect(copies.left.size == 5)
        #expect(copies.right.size == 11)
        #expect(copies.left.modificationDate != nil, "the date row would read “—” on both sides")
        #expect(copies.right.modificationDate != nil)
        #expect(copies.left.isRecommendedKeeper == false, "there is no keeper concept in this host")
    }

    /// A vanished side stats to nothing rather than trapping: the row can go stale between the menu
    /// being drawn and the item being clicked.
    @Test func aVanishedSideStatsToZeroRatherThanFailing() async {
        let pair = DifferencePair.acrossPanes(leftPath: "/nope/gone.txt",
                                              rightPath: "/nope/also.txt",
                                              leftPaneName: "A", rightPaneName: "B")
        let copies = await DifferencesPairCompare.copies(for: pair)
        #expect(copies.left.size == 0)
        #expect(copies.left.modificationDate == nil)
    }

    // MARK: Mounted

    /// The shared viewer really mounts in this host, with two panes and no keeper picker, so "one
    /// component, two hosts" is checked rather than assumed.
    @Test func theSharedViewerMountsWithTwoPanesAndNoKeeper() async throws {
        let fixture = try Fixture()
        let pair = DifferencePair.acrossPanes(leftPath: fixture.left, rightPath: fixture.right,
                                              leftPaneName: "iCloud", rightPaneName: "Dropbox")
        let copies = await DifferencesPairCompare.copies(for: pair)
        let view = FilePairCompareView(
            left: copies.left, right: copies.right, title: pair.title, subtitle: pair.subtitle,
            claimHeadline: nil, offersVerify: false, keeperPath: nil, allowsKeeperChoice: false,
            notice: nil, scanRoot: nil, providerName: nil, hue: .blue,
            availableSize: CGSize(width: 1200, height: 800),
            onClose: {},
            verdict: { _ in Text("Done") })
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func previews() -> [QLPreviewView] {
            func walk(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + walk($0) } }
            return walk(host).compactMap { $0 as? QLPreviewView }
        }
        // Through `LayoutPumpWait`: the panes mount on main-actor turns, and a wall-clock deadline
        // buys almost none of them under full-package load.
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 5) { previews().count == 2 }
        #expect(held, "expected two preview panes, found \(previews().count) (\(pumps) pumps)")
    }
}

/// The compare viewer's seams: no keeper arrows where there is no keeper, and a trash confirmation
/// a test can drive and decline.
@MainActor
@Suite struct FilePairCompareSeamTests {

    private final class Recorder: @unchecked Sendable {
        var keeperPicks: [String] = []
        var confirmations: [(copy: String, keeper: String, location: String)] = []
        var answer = false
    }

    private func copy(_ path: String, keeper: Bool = false) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 100, itemCount: 1, modificationDate: Date(timeIntervalSince1970: 1),
                      uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper)
    }

    private func send(_ window: NSWindow, keyCode: UInt16, characters: String,
                      modifiers: NSEvent.ModifierFlags = []) {
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)!)
    }

    /// A surface with no keeper must not answer ←/→: the Differences host keeps nothing, so taking
    /// the arrows would swallow keys for an act that does not exist.
    @Test(arguments: [false, true])
    func aHostWithNoKeeperIgnoresTheKeeperArrows(allowsChoice: Bool) async throws {
        // The `true` case is the one that matters: with `allowsKeeperChoice: false` (the real
        // Differences configuration) the flag alone refuses the key, so only with it true does
        // deleting the `keeperPath != nil` guard make this fail.
        let recorder = Recorder()
        let view = FilePairCompareView(
            left: copy("/L/x.txt"), right: copy("/R/x.txt"), title: "x.txt", subtitle: "A vs B",
            claimHeadline: nil, offersVerify: false,
            keeperPath: nil, allowsKeeperChoice: allowsChoice, notice: nil,
            scanRoot: nil, providerName: nil, hue: .blue,
            availableSize: CGSize(width: 900, height: 600),
            onChooseKeeper: { recorder.keeperPicks.append($0) },
            onClose: {},
            probe: { _ in .missing }, hash: { _ in .hashed("a") },
            verdict: { _ in Text("Done") })
        let host = NSHostingView(rootView: AnyView(view.frame(width: 900, height: 600)))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let (focused, pumps) = await LayoutPumpWait.pump(window, upTo: 3) {
            window.firstResponder !== window && !(window.firstResponder is NSText)
        }
        try #require(focused, "the surface never claimed focus (\(pumps) pumps)")
        send(window, keyCode: 124, characters: "\u{f703}", modifiers: [.numericPad, .function])
        #expect(recorder.keeperPicks.isEmpty, "a host with no keeper answered → anyway")
    }

    /// A declined confirmation trashes nothing. Driven through the `confirmTrash` seam, because the
    /// real `confirmDestructive` is a blocking modal a test would hang on.
    @Test func decliningTheConfirmationTrashesNothing() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FilePairCompareSeamTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: a)
        try Data("x".utf8).write(to: b)

        let recorder = Recorder()
        recorder.answer = false
        let manager = FileSyncManager()
        let keeper = copy(a.path, keeper: true), other = copy(b.path)
        manager.duplicateGroups = [DuplicateGroup(matchType: .identical, name: "a.txt",
                                                  isDirectory: false, copies: [keeper, other],
                                                  reclaimableBytes: 100)]
        let overlay = CompareCopiesOverlay(
            syncManager: manager,
            pair: DuplicateComparePair(keeper: keeper, other: other, matchType: .identical,
                                       groupName: "a.txt"),
            scanRoot: dir.path, providerName: "iCloud",
            onClose: {},
            confirmTrash: { copy, keep, location in
                recorder.confirmations.append((copy.path, keep.path, location))
                return recorder.answer
            })

        overlay.trash(other, keeper: keeper)

        #expect(recorder.confirmations.count == 1, "the confirmation was skipped entirely")
        #expect(recorder.confirmations.first?.copy == b.path)
        #expect(recorder.confirmations.first?.keeper == a.path)
        #expect(recorder.confirmations.first?.location.contains("iCloud") == true,
                "the dialog would not say where the kept copy lives")
        // Give any (wrongly) started work a few main-actor turns to land before asserting absence.
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(FileManager.default.fileExists(atPath: b.path),
                "a declined confirmation removed the copy anyway")
        #expect(manager.duplicateGroups.count == 1)
    }
}

// MARK: - Esc while the opening stat is outstanding

/// Esc must close the overlay while its opening stat is still outstanding. The surface's keys live
/// on the pair view, which isn't mounted until the stat lands, and a dead SMB or unmounted cloud
/// volume can block that stat indefinitely: exactly when the reader wants out.
///
/// Driven through a real window's responder chain, like `CompareCopiesKeyTests`, because the
/// question is whether the key arrives.
@MainActor
@Suite(.serialized) struct DifferencesPairCompareWaitingKeyTests {

    private final class Recorder: @unchecked Sendable { var closes = 0 }

    private func pair() -> DifferencePair {
        DifferencesPairCompare.pair(
            for: FileDifference(relativePath: "Reports/Q3.pdf",
                                leftItemPath: "/L/Reports/Q3.pdf",
                                rightItemPath: "/R/Reports/Q3.pdf",
                                type: .differentDates, action: .copyToRight,
                                description: "differs", enclosedItemCount: nil),
            paneNames: PaneProviderNames(leftName: "iCloud", rightName: "Dropbox"))!
    }

    private func host(_ view: some View) -> NSWindow {
        let size = CGSize(width: 1200, height: 800)
        let hostView = NSHostingView(rootView: AnyView(view.frame(width: size.width,
                                                                  height: size.height)))
        hostView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostView
        hostView.layoutSubtreeIfNeeded()
        return window
    }

    private func sendEscape(_ window: NSWindow) {
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!)
    }

    /// A stat that never returns — the dead-mount case the off-main hop exists for.
    private func blockedOverlay(_ recorder: Recorder) -> DifferencesPairCompareOverlay {
        DifferencesPairCompareOverlay(
            pair: pair(), hue: .blue, onClose: { recorder.closes += 1 },
            copies: { _ in
                // Long enough that the placeholder is certainly still what is mounted, and
                // cancelled with the view rather than leaked.
                try? await Task.sleep(for: .seconds(600))
                return (DuplicateCopy(id: "l", name: "l", isDirectory: false, size: 0, itemCount: 1,
                                      modificationDate: nil, uniqueItemCount: 0, depth: 0,
                                      isRecommendedKeeper: false),
                        DuplicateCopy(id: "r", name: "r", isDirectory: false, size: 0, itemCount: 1,
                                      modificationDate: nil, uniqueItemCount: 0, depth: 0,
                                      isRecommendedKeeper: false))
            })
    }

    @Test func escClosesTheOverlayWhileTheStatIsStillOutstanding() async {
        let recorder = Recorder()
        let window = host(blockedOverlay(recorder))
        let (focused, pumps) = await LayoutPumpWait.pump(window, upTo: 10) {
            window.firstResponder !== window
        }
        #expect(focused, "the placeholder never claimed focus (\(pumps) pumps)")
        sendEscape(window)
        #expect(recorder.closes == 1)
    }

    /// The control for the test above: a modified esc is refused by `isPlainKeystroke` (the guard
    /// every handler on the pair view carries), while a plain one on the same view still closes.
    @Test func aModifiedEscIsIgnored() async {
        let recorder = Recorder()
        let window = host(blockedOverlay(recorder))
        _ = await LayoutPumpWait.pump(window, upTo: 10) { window.firstResponder !== window }
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!)
        #expect(recorder.closes == 0)
        // The plain key still works, so the refusal above is the modifier being read, not the
        // handler being absent.
        sendEscape(window)
        #expect(recorder.closes == 1)
    }
}
