import Testing
import Foundation
import AppKit
import SwiftUI
import Design
import FileExplorer
@testable import SyncCloud

/// Go to Folder's wiring, where the feature can silently stop existing. The rule, `PalettePath`, is
/// tested in FileExplorer against fixtures; this covers what the app must supply for it to work.
/// Each fails silently if it goes: no probe means no path row ever, and a provider with no `root`
/// means every typed path answers "Not in any source", with every routing test still green.
@MainActor
@Suite struct GoToFolderCallSiteTests {
    private static func temporaryTree() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synccloud-goto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Legal"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: base.appendingPathComponent("Legal/invoice.pdf"))
        return base
    }

    // MARK: The probe, against the real disk

    /// `pathKind` is the one place Go to Folder touches the filesystem, and its three answers are
    /// three different rows. Run against a real tree, since FileExplorer's suite already uses a fake
    /// and can't show this function agrees with it.
    @Test func theProbeTellsAFolderFromAFileFromNothingAtAll() throws {
        let base = try Self.temporaryTree()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(ContentView.pathKind(base.appendingPathComponent("Legal").path) == .directory)
        #expect(ContentView.pathKind(base.appendingPathComponent("Legal/invoice.pdf").path) == .file)
        #expect(ContentView.pathKind(base.appendingPathComponent("Nope").path) == .missing)
    }

    /// No tilde expansion here: `PalettePath.absolute` has already expanded against the index's
    /// `home`, and a second expansion would be a second rule. A `~` reaching this function is a path
    /// that really has one in its name.
    @Test func theProbeDoesNotExpandATildeOfItsOwn() {
        // Asserted as a contrast: `~` answering `.missing` alone proves nothing (any nonsense string
        // does, and a broken probe would too). The home it would expand to is a directory; `~` isn't.
        #expect(ContentView.pathKind(NSHomeDirectory()) == .directory,
                "the home directory did not read as one — this contrast cannot mean anything")
        #expect(ContentView.pathKind("~") == .missing,
                "the probe expands tildes as well — two rules for one question, and they will disagree")
    }

    // MARK: The whole path, through the state the field drives

    /// End to end: a real folder, a real provider root and the app's own probe, asked the way the
    /// toolbar field asks. Fails if any single link is dropped.
    @Test func typingARealPathIntoTheFieldRoutesToThatFolder() throws {
        let base = try Self.temporaryTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.path
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "temp", name: "Scratch", isMounted: true,
                                        isCurrent: true, root: root)],
            providerRoot: root, folders: [], home: NSHomeDirectory(),
            isScanning: false, hasSurvey: true)
        let state = CommandPaletteState(index: index, pathProbe: ContentView.pathKind)

        state.setQuery("\(root)/Legal")
        #expect(state.rows.first?.route == .folder(path: "\(root)/Legal"),
                "a typed path did not route to the folder it names — got \(String(describing: state.rows.first?.route))")
        #expect(state.rows.first?.isAvailable == true,
                "refused with: \(state.rows.first?.unavailable ?? "nothing")")

        // A pasted file path lands on the folder that holds it.
        state.setQuery("\(root)/Legal/invoice.pdf")
        #expect(state.rows.first?.route == .folder(path: "\(root)/Legal"))

        // And a path that is not there refuses rather than offering itself.
        state.setQuery("\(root)/Nope")
        #expect(state.rows.first?.unavailable == "No folder at that path")
    }

    /// A state built without a probe offers no path rows: the shape other palette tests use,
    /// asserted so "it worked in the app" can't be mistaken for "the default is fine".
    @Test func aStateWithNoProbeOffersNoPathRows() throws {
        let base = try Self.temporaryTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "temp", name: "Scratch", isMounted: true,
                                        isCurrent: true, root: base.path)],
            providerRoot: base.path, folders: [], home: NSHomeDirectory(),
            isScanning: false, hasSurvey: true)
        let state = CommandPaletteState(index: index)
        state.setQuery("\(base.path)/Legal")
        #expect(!state.rows.contains { $0.id.hasPrefix("path.") })
    }

    // MARK: The two supplies the app has to keep making

    /// `MacApp/` is in no SPM package, so these supplies are reachable only as text. Each pins a
    /// supply, not a spelling of the rule: without the probe there is no path row, and without
    /// `root` on the providers every typed path answers "Not in any source".
    @Test func theHostSuppliesTheProbeAndTheProviderRoots() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        #expect(host.contains("CommandPaletteState(index: index, pathProbe: Self.pathKind)"),
                "the palette is built without a path probe — Go to Folder silently offers nothing, on every query")
        // The source's root, not its landing folder: a typed path is judged against the whole
        // account, so any path above a source's documents tree would answer "Not in any source".
        #expect(host.contains("root: (provider.rootPath as NSString).expandingTildeInPath)"),
                "the sources reach the router with no path on them — every typed path answers \"Not in any source\"")

        let panel = try macAppFile("CommandPalettePanel.swift")
        #expect(panel.contains("probe: pathProbe == nil ? nil : { [self] in probeKind($0) }"),
                "the state holds a probe and does not hand it to the router — the field types into a rule that cannot answer")
    }

    // MARK: How often the disk is actually asked

    /// An arrow key must not re-`stat` an unchanged path, which costs latency on a slow network
    /// share. `rows` is read twice per change (by `setQuery` and by the SwiftUI body), so this drives
    /// the mounted controller; calling only `setQuery` would measure one read.
    @Test func movingTheHighlightDoesNotAskTheDiskAgain() async {
        final class Counter: @unchecked Sendable {
            var calls: [String] = []
        }
        let counter = Counter()
        let (state, controller, host) = await mountedPalette(
            folders: ["Legal"], probe: { counter.calls.append($0); return .directory })
        defer { controller.dismiss(); host.orderOut(nil) }

        // The view's read is made here rather than waited for: under load a sleep could end before
        // the body ran, and one recorded call would pass for the wrong reason.
        controller.setQuery("/Users/x/Documents/Legal")
        _ = state.rows                                   // the view's read, made to happen
        let afterTyping = counter.calls.count
        #expect(afterTyping >= 1, "the path was never checked at all — the fixture proves nothing")
        #expect(afterTyping == 1,
                "one keystroke cost \(afterTyping) disk checks; `rows` is read twice per change — once to re-seat the selection, once by the view — and the memo is what makes the second free")

        controller.move(by: 1)
        _ = state.rows
        controller.move(by: -1)
        _ = state.rows
        #expect(counter.calls.count == afterTyping,
                "moving the highlight re-checked the disk \(counter.calls.count - afterTyping) time(s) for a path that had not changed")

        // The mounted view must not re-check the disk on its own while nothing changes. Asserted
        // separately so a change in SwiftUI's evaluation can't hide behind the counts above.
        let beforeIdle = counter.calls.count
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(counter.calls.count == beforeIdle,
                "the mounted view re-checked the disk on its own \(counter.calls.count - beforeIdle) time(s) while nothing changed")
    }

    /// A palette over `folders` of one Documents source, mounted on an off-screen host and placed,
    /// so its view is really reading the rows. The caller dismisses it.
    private func mountedPalette(folders: [String], probe: PalettePathProbe? = nil) async
        -> (CommandPaletteState, CommandPalettePanelController, NSWindow) {
        let host = NSWindow(contentRect: CGRect(x: -9_000, y: -9_000, width: 900, height: 600),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let controller = CommandPalettePanelController()
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "p", name: "Docs", isMounted: true,
                                        isCurrent: true, root: "/Users/x/Documents")],
            providerRoot: "/Users/x/Documents", folders: folders, home: "/Users/x",
            isScanning: false, hasSurvey: true)
        let state = CommandPaletteState(index: index, pathProbe: probe)
        controller.present(over: host, state: state, accent: .blue, glassLevel: .frosted,
                           anchor: { CGRect(x: host.frame.minX + 60, y: host.frame.maxY - 80,
                                            width: 420, height: 28) },
                           onRun: { _ in }, onDismiss: {})
        await waitUntil("the panel was placed, so the view is really reading the rows") {
            (host.childWindows?.first?.frame.width ?? 0) == 420
        }
        return (state, controller, host)
    }

    /// A few main-queue turns, so the mounted panel re-renders and its body really reads the rows
    /// before anything is counted.
    private func settle() async {
        for _ in 0..<3 { try? await Task.sleep(for: .milliseconds(30)) }
    }

    /// A keystroke ranks the folders once, and an arrow key not at all: ranking scores every surveyed
    /// folder (~16 ms over 3,000), and `rows` is read by `setQuery`, the body and every ↑ ↓. Mounted,
    /// so the body's read is real.
    @Test func typingRanksOnceAndMovingRanksNothing() async {
        let (state, controller, host) = await mountedPalette(
            folders: ["Legal", "Legal/Contracts", "Taxes", "Taxes/2025", "Health"])
        defer { controller.dismiss(); host.orderOut(nil) }

        let before = state.rankingRuns
        controller.setQuery("le")
        await settle()                                   // the mounted panel's own body read
        _ = state.rows                                   // and one more, made to happen
        #expect(state.rows.contains { $0.title.contains("Legal") },
                "the query matched nothing — the fixture proves nothing about ranking")
        #expect(state.rankingRuns - before == 1,
                "one keystroke ranked the folders \(state.rankingRuns - before) times")

        let afterTyping = state.rankingRuns
        controller.move(by: 1)
        await settle()
        _ = state.rows
        controller.move(by: -1)
        await settle()
        _ = state.rows
        #expect(state.rankingRuns == afterTyping,
                "moving the highlight re-ranked \(state.rankingRuns - afterTyping) time(s) for a query that had not changed")

        // A new query is a new question: the memo must not answer it with the old rows.
        controller.setQuery("tax")
        #expect(state.rankingRuns == afterTyping + 1)
        #expect(state.rows.contains { $0.title.contains("Taxes") }
                    && !state.rows.contains { $0.title.contains("Legal") },
                "the rows still answer the previous query")
    }
}
