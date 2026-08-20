import Testing
import Foundation
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
        #expect(panel.contains("PaletteRouter.rows(query: query, index: index, probe: pathProbe)"),
                "the state holds a probe and does not hand it to the router — the field types into a rule that cannot answer")
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
