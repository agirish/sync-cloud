import Testing
import Foundation
import AppKit
import SwiftUI
import Design
import FileExplorer
@testable import SyncCloud

/// **Go to Folder's wiring**, which is where this feature can silently stop existing.
///
/// The rule itself is `PalettePath`, tested in the FileExplorer suite against fixtures. Everything
/// here is the three things the app has to supply for that rule to do anything at all — and each of
/// them fails *silently* if it goes: no probe means no path row ever, and a provider with no `root`
/// means every typed path answers "Not in any source". Neither would fail a single routing test.
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

    /// `pathKind` is the one place Go to Folder touches the filesystem, and the three answers are
    /// three different rows. Run against a real tree rather than a fake, because a fake is what the
    /// FileExplorer suite already uses — what is unproven there is that this function agrees with it.
    @Test func theProbeTellsAFolderFromAFileFromNothingAtAll() throws {
        let base = try Self.temporaryTree()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(ContentView.pathKind(base.appendingPathComponent("Legal").path) == .directory)
        #expect(ContentView.pathKind(base.appendingPathComponent("Legal/invoice.pdf").path) == .file)
        #expect(ContentView.pathKind(base.appendingPathComponent("Nope").path) == .missing)
    }

    /// **No tilde expansion here, deliberately** — `PalettePath.absolute` has already done it
    /// against the index's `home`, and a second expansion would be a second rule. A `~` reaching
    /// this function is a path that genuinely has one in its name.
    @Test func theProbeDoesNotExpandATildeOfItsOwn() {
        #expect(ContentView.pathKind("~") == .missing,
                "the probe expands tildes as well — two rules for one question, and they will disagree")
    }

    // MARK: The whole path, through the state the field drives

    /// End to end: a real folder, a real provider root, the app's own probe, asked the way the
    /// toolbar field asks it. This is the test that fails if any single link is dropped.
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

    /// A state built without a probe offers no path rows — the shape every existing palette test
    /// uses, asserted here so "it worked in the app" cannot be confused with "the default is fine".
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

    /// `MacApp/` is in no SPM package, so these two are reachable from a test only as text. Each
    /// pins a **supply**, not a spelling of the rule: without the probe there is no path row at
    /// all, and without `root` on the providers every typed path answers "Not in any source" — and
    /// neither failure would trip a single routing test.
    @Test func theHostSuppliesTheProbeAndTheProviderRoots() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("CommandPaletteState(index: index, pathProbe: Self.pathKind)"),
                "the palette is built without a path probe — Go to Folder silently offers nothing, on every query")
        #expect(host.contains("root: (provider.path as NSString).expandingTildeInPath)"),
                "the sources reach the router with no path on them — every typed path answers \"Not in any source\"")

        let panel = try Self.source("CommandPalettePanel.swift")
        #expect(panel.contains("probe: pathProbe == nil ? nil : { [self] in probeKind($0) }"),
                "the state holds a probe and does not hand it to the router — the field types into a rule that cannot answer")
    }

    // MARK: How often the disk is actually asked

    /// **An arrow key must not re-`stat` a path that has not changed.**
    ///
    /// Measured 2026-08-19 through a live presentation, before the memo existed: one keystroke cost
    /// **two** probe calls and one ↓ cost **two more**. `rows` is a computed property read twice
    /// per change — once by `setQuery` to re-seat the selection, once by the SwiftUI body — so
    /// moving the highlight re-ran the whole router, and its disk question, against a query nobody
    /// had touched. On a mounted-but-slow network share that is latency for a keystroke that asked
    /// nothing new.
    ///
    /// Driven through the controller the toolbar field drives, not through `state.rows` directly:
    /// the second read is the *view's*, and a test that only called `setQuery` would measure one
    /// call and prove nothing.
    @Test func movingTheHighlightDoesNotAskTheDiskAgain() async {
        final class Counter: @unchecked Sendable {
            var calls: [String] = []
        }
        let counter = Counter()
        let host = NSWindow(contentRect: CGRect(x: -9_000, y: -9_000, width: 900, height: 600),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let controller = CommandPalettePanelController()
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "p", name: "Docs", isMounted: true,
                                        isCurrent: true, root: "/Users/x/Documents")],
            providerRoot: "/Users/x/Documents", folders: ["Legal"], home: "/Users/x",
            isScanning: false, hasSurvey: true)
        let state = CommandPaletteState(index: index,
                                        pathProbe: { counter.calls.append($0); return .directory })
        controller.present(over: host, state: state, accent: .blue, glassLevel: .frosted,
                           anchor: { CGRect(x: host.frame.minX + 60, y: host.frame.maxY - 80,
                                            width: 420, height: 28) },
                           onRun: { _ in }, onDismiss: {})
        await waitUntil("the panel was placed, so the view is really reading the rows") {
            (host.childWindows?.first?.frame.width ?? 0) == 420
        }
        defer { controller.dismiss(); host.orderOut(nil) }

        controller.setQuery("/Users/x/Documents/Legal")
        for _ in 0..<8 { try? await Task.sleep(nanoseconds: 20_000_000) }
        let afterTyping = counter.calls.count
        #expect(afterTyping >= 1, "the path was never checked at all — the fixture proves nothing")
        #expect(afterTyping == 1,
                "one keystroke cost \(afterTyping) disk checks; `rows` is read twice per change and the memo is what makes the second free")

        controller.move(by: 1)
        controller.move(by: -1)
        for _ in 0..<8 { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(counter.calls.count == afterTyping,
                "moving the highlight re-checked the disk \(counter.calls.count - afterTyping) time(s) for a path that had not changed")
    }

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — the checks below would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short")
        return text
    }
}
