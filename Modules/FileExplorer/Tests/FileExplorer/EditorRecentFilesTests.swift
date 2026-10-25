import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer
import FileExplorerTestSupport

/// **Edit's recent files (TE58): the store's rules, its words, and the empty page that draws it.**
///
/// The store copies the sidebar Recents' rules (`FolderJumpStore`), so the cases are its cases:
/// move-to-front with a cap, missing files hidden but kept, a moved file followed, and bytes this
/// build cannot read kept rather than written over.
@MainActor
@Suite(.serialized) struct EditorRecentFilesTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func store(_ defaults: UserDefaults? = nil,
                       missing: Set<String> = []) -> EditorRecentFiles {
        EditorRecentFiles(defaults: defaults, exists: { !missing.contains($0) })
    }

    // MARK: Order and cap

    /// **Opening a file again moves it to the top, once** — and the cap drops the OLDEST. The file
    /// opened again sits LAST before it is reopened, so a rule that appended instead of moving
    /// would leave it there.
    @Test func reopeningMovesAFileToTheTopAndTheCapDropsTheOldest() {
        let recents = store()
        for i in 0..<EditorRecentFiles.maxStored {
            recents.record(path: "/n/\(i).md", kind: .text, at: t0.addingTimeInterval(Double(i)))
        }
        #expect(recents.stored.count == 20)
        #expect(recents.stored.last?.path == "/n/0.md")
        recents.record(path: "/n/0.md", kind: .text, at: t0.addingTimeInterval(100))
        #expect(recents.stored.first?.path == "/n/0.md", "reopening did not move the file to the top")
        #expect(recents.stored.filter { $0.path == "/n/0.md" }.count == 1, "the file is listed twice")
        #expect(recents.stored.first?.openedAt == t0.addingTimeInterval(100), "the row kept its old date")
        recents.record(path: "/n/new.md", kind: .pdf, at: t0.addingTimeInterval(200))
        #expect(recents.stored.count == 20, "the cap did not hold")
        #expect(!recents.stored.contains { $0.path == "/n/1.md" }, "the cap dropped something other than the oldest")
        #expect(recents.stored.first?.kind == .pdf)
        // Ten shown of the twenty kept.
        #expect(recents.shown.map(\.path) == Array(recents.stored.prefix(10)).map(\.path))
    }

    /// A path that is not absolute is no file to offer again.
    @Test func aRelativePathIsNotRecorded() {
        let recents = store()
        recents.record(path: "notes.md", kind: .text, at: t0)
        recents.record(path: "", kind: .text, at: t0)
        #expect(recents.stored.isEmpty)
    }

    // MARK: Persistence

    /// **What is written is what the next launch reads** — asserted on the bytes under the key,
    /// decoded independently, not on the store's own copy (`decoded ≠ preserved`).
    @Test func theListSurvivesARelaunch() throws {
        let defaults = ScratchDefaults("EditorRecentFiles")
        let first = store(defaults)
        first.record(path: "/n/Pasta.md", kind: .text, at: t0)
        first.record(path: "/n/Scan.pdf", kind: .pdf, at: t0.addingTimeInterval(60))
        let data = try #require(defaults.data(forKey: "editorRecentFiles"), "nothing was written under the key")
        let written = try JSONDecoder().decode([EditorRecentFile].self, from: data)
        #expect(written == [EditorRecentFile(path: "/n/Scan.pdf", openedAt: t0.addingTimeInterval(60), kind: .pdf),
                            EditorRecentFile(path: "/n/Pasta.md", openedAt: t0, kind: .text)])
        let second = store(defaults)
        #expect(second.stored == written)
    }

    /// **Unreadable bytes are kept, once, and the store carries on empty** — the next open must not
    /// be what destroys them, and a SECOND unreadable launch must not overwrite the first stash,
    /// which is the one holding the real list.
    @Test func unreadableBytesAreKeptRatherThanWrittenOver() throws {
        let defaults = ScratchDefaults("EditorRecentFiles")
        let original = Data("not json at all".utf8)
        defaults.set(original, forKey: "editorRecentFiles")
        let recents = store(defaults)
        #expect(recents.stored.isEmpty)
        #expect(defaults.data(forKey: "editorRecentFiles.unreadable") == original, "the unreadable bytes were not kept")
        recents.record(path: "/n/After.md", kind: .text, at: t0)
        #expect(defaults.data(forKey: "editorRecentFiles.unreadable") == original, "an open wrote over the kept bytes")
        // Unreadable again, differently: the first stash stays.
        defaults.set(Data("[{\"broken".utf8), forKey: "editorRecentFiles")
        _ = store(defaults)
        #expect(defaults.data(forKey: "editorRecentFiles.unreadable") == original, "a later failure replaced the first stash")
    }

    /// **A kind from another build reads as text**, and every other row survives — one row this
    /// build cannot name must not send the whole list to the stash.
    @Test func anUnknownKindReadsAsTextAndKeepsTheList() throws {
        let defaults = ScratchDefaults("EditorRecentFiles")
        let json = #"[{"path":"/n/Deck.key","openedAt":0,"kind":"slides"},{"path":"/n/A.pdf","openedAt":0,"kind":"pdf"}]"#
        defaults.set(Data(json.utf8), forKey: "editorRecentFiles")
        let recents = store(defaults)
        #expect(recents.stored.map(\.path) == ["/n/Deck.key", "/n/A.pdf"])
        #expect(recents.stored.map(\.kind) == [.text, .pdf])
        #expect(defaults.data(forKey: "editorRecentFiles.unreadable") == nil)
    }

    // MARK: Missing files

    /// **A missing file is hidden but kept** — and the shown ten are the first ten THERE, so a
    /// missing one at the top lets the eleventh in. The missing file is the newest, so a rule that
    /// hid nothing would show it first.
    @Test func aMissingFileIsHiddenButKept() async {
        let recents = store(missing: ["/n/19.md"])
        for i in 0..<EditorRecentFiles.maxStored {
            recents.record(path: "/n/\(i).md", kind: .text, at: t0.addingTimeInterval(Double(i)))
        }
        await recents.refreshShown()
        #expect(recents.stored.contains { $0.path == "/n/19.md" }, "the missing file was forgotten")
        #expect(!recents.shown.contains { $0.path == "/n/19.md" }, "the missing file is still listed")
        #expect(recents.shown.count == 10)
        #expect(recents.shown.first?.path == "/n/18.md")
        #expect(recents.shown.last?.path == "/n/9.md", "the eleventh file did not take the missing one's place")
    }

    // MARK: Moves, removal, Clear Menu

    /// **A moved file keeps its place and its date**, and an older row at the new path goes so the
    /// path is listed once.
    @Test func aMovedFileIsFollowedInPlace() {
        let recents = store()
        recents.record(path: "/n/Old name.md", kind: .text, at: t0)
        recents.record(path: "/n/Other.md", kind: .text, at: t0.addingTimeInterval(1))
        recents.record(path: "/n/Middle.md", kind: .text, at: t0.addingTimeInterval(2))
        recents.move(from: "/n/Middle.md", to: "/n/Old name.md")
        #expect(recents.stored.map(\.path) == ["/n/Old name.md", "/n/Other.md"])
        #expect(recents.stored.first?.openedAt == t0.addingTimeInterval(2), "the moved row lost its date")
        recents.move(from: "/n/Other.md", to: "/archive/Other.md")
        #expect(recents.stored.map(\.path) == ["/n/Old name.md", "/archive/Other.md"])
        // A path nobody lists moves nothing.
        recents.move(from: "/n/Nope.md", to: "/n/Elsewhere.md")
        #expect(recents.stored.count == 2)
    }

    /// Remove from Recents takes one row; Clear Menu takes every row, the hidden ones too.
    @Test func removeTakesOneRowAndClearTakesTheHiddenOnesToo() async throws {
        let defaults = ScratchDefaults("EditorRecentFiles")
        let recents = store(defaults, missing: ["/gone/B.md"])
        recents.record(path: "/n/A.md", kind: .text, at: t0)
        recents.record(path: "/gone/B.md", kind: .text, at: t0.addingTimeInterval(1))
        recents.record(path: "/n/C.md", kind: .text, at: t0.addingTimeInterval(2))
        await recents.refreshShown()
        recents.remove(path: "/n/A.md")
        #expect(recents.stored.map(\.path) == ["/n/C.md", "/gone/B.md"])
        #expect(recents.shown.map(\.path) == ["/n/C.md"], "the removed row is still drawn")
        recents.clear()
        #expect(recents.stored.isEmpty && recents.shown.isEmpty)
        let data = try #require(defaults.data(forKey: "editorRecentFiles"))
        #expect(try JSONDecoder().decode([EditorRecentFile].self, from: data).isEmpty, "Clear Menu was not written")
    }

    // MARK: Words

    /// **When a row was opened, in the fewest words** — the rule, on a fixed calendar and zone so
    /// the days are this test's and not the Mac's. The words that are the app's own are pinned
    /// literally; the time, weekday and date are the reader's own format.
    @Test func theTimeColumnSaysWhenInTheFewestWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Wednesday 21 October 2026, 15:00 UTC.
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!
        func bucket(_ seconds: TimeInterval) -> EditorRecentFiles.When {
            EditorRecentFiles.bucket(now.addingTimeInterval(-seconds), now: now, calendar: calendar)
        }
        #expect(bucket(20) == .justNow)
        #expect(bucket(2 * 60 + 5) == .minutes(2))
        #expect(bucket(3 * 3600) == .today)
        // 19:00 the day before is yesterday, though not 24 hours ago.
        #expect(bucket(20 * 3600) == .yesterday)
        #expect(bucket(3 * 86400) == .thisWeek)
        #expect(bucket(6 * 86400) == .thisWeek)
        #expect(bucket(7 * 86400) == .thisYear)
        #expect(bucket(400 * 86400) == .older)
        func when(_ seconds: TimeInterval) -> String {
            EditorRecentFiles.when(now.addingTimeInterval(-seconds), now: now, calendar: calendar)
        }
        #expect(when(20) == "Just now")
        #expect(when(2 * 60 + 5) == "2 min ago")
        #expect(when(20 * 3600) == "Yesterday")
        // The year only when it is not this one: a 2025 date carries it, a September one does not.
        #expect(when(400 * 86400).contains("2025"))
        #expect(!when(23 * 86400).contains("2026"))
    }

    /// Two rows of one name carry their folders in the menu; a lone name does not.
    @Test func theMenuNamesTheFolderOnlyWhereTwoNamesMeet() {
        let files = [EditorRecentFile(path: "/a/SyncCloud/README.md", openedAt: t0, kind: .text),
                     EditorRecentFile(path: "/b/Notes/README.md", openedAt: t0, kind: .text),
                     EditorRecentFile(path: "/b/Notes/Pasta.md", openedAt: t0, kind: .text),
                     EditorRecentFile(path: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Plan.pdf",
                                      openedAt: t0, kind: .pdf)]
        #expect(EditorRecentFiles.menuTitles(files)
                == ["README.md — SyncCloud", "README.md — Notes", "Pasta.md", "Plan.pdf"])
        #expect(files[3].folderName == "iCloud Drive")
    }

    /// The page's sentence, as decided: where New Text File's file goes, then ⌘O from the chord itself.
    @Test func theCaptionSaysWhereNewTextFileGoesThenHowToOpenAnother() {
        let open = AppChord.openInEditor.display
        #expect(EditorRecentFilesPage<EmptyView>.caption(folderName: "Recipes")
                == "New Text File asks for a name, then makes the file in Recipes. To open a different file, select a text file "
                + "or a PDF file in Browse, Compare or Organize and press \(open).")
        // No folder to name: ⌘N goes to Notes, and the sentence says so.
        #expect(EditorRecentFilesPage<EmptyView>.caption(folderName: "").contains("makes the file in Notes."))
    }

    // MARK: The page

    /// **The empty page draws the list once there is one, and its old sentence until then** — read
    /// in pixels, against the same workspace with nothing remembered. A source scan pins that the
    /// page is the workspace's, wired to the host's two closures and ⌘N's.
    @Test func theEmptyPageDrawsTheListOnlyWhenThereIsOne() throws {
        let empty = store()
        let full = store()
        full.record(path: "/n/Recipes/Pasta.md", kind: .text, at: Date().addingTimeInterval(-120))
        full.record(path: "/n/Scans/Lease.pdf", kind: .pdf, at: Date().addingTimeInterval(-90_000))
        let blank = try #require(render(EditorWorkspaceView.fixture(recentFiles: empty, onOpenRecent: { _ in }),
                                        width: 520, name: "te58-empty"))
        let listed = try #require(render(EditorWorkspaceView.fixture(recentFiles: full, onOpenRecent: { _ in }),
                                         width: 520, name: "te58-listed"))
        let withoutStore = try #require(render(EditorWorkspaceView.fixture(), width: 520, name: "te58-nostore"))
        #expect(differing(blank, withoutStore) == 0, "an empty list changed the page it falls back to")
        #expect(differing(blank, listed) > 2_000, "the list is not drawn")

        let code = try ChromeGlassWiringTests.source("EditorWorkspaceView.swift")
        #expect(code.contains("EditorRecentFilesPage(recents: recentFiles, open: onOpenRecent, newNote: onNewTextFile,"),
                "the page is not handed the host's open and ⌘N's closure")
        #expect(code.contains("newNoteFolder: newFileFolderLabel,"), "New Text File names a folder other than the ＋'s")
        // A row's right-click: the body never runs offscreen, so its one act is read off the code.
        let page = try ChromeGlassWiringTests.source("EditorRecentFilesPage.swift")
        #expect(page.contains("Button(Self.removeTitle) { recents.remove(path: file.path) }"),
                "Remove from Recents does not remove the row it was chosen on")
        #expect(page.contains("Button { open(file.path) } label: {"), "a row's click opens something other than its file")
        #expect(EditorRecentFilesPage<EmptyView>.removeTitle == "Remove from Recents")
    }

    /// **A drop on the empty page hands its files to the host, and only files** (TE198). A web
    /// address dragged from a browser is a URL too; a drop with no file in it, or with no host to
    /// take it, is refused so Finder slides it back. The page takes it whole, not just the list.
    @Test func aDropOnTheEmptyPageHandsOverItsFiles() throws {
        var handed: [[URL]] = []
        let take: ([URL]) -> Void = { handed.append($0) }
        let file = URL(fileURLWithPath: "/n/Recipes/Pasta.md")
        let web = try #require(URL(string: "https://example.com/a.md"))
        #expect(EditorWorkspaceView.takesDrop([web, file], onDropFiles: take))
        #expect(handed == [[file]])
        #expect(!EditorWorkspaceView.takesDrop([web], onDropFiles: take))
        #expect(!EditorWorkspaceView.takesDrop([file], onDropFiles: nil))
        #expect(handed.count == 1, "a refused drop was handed over")

        let code = try ChromeGlassWiringTests.source("EditorWorkspaceView.swift")
        let page = try #require(code.range(of: "} else if document.path == nil {"))
        let rest = code[page.upperBound...]
        let drop = try #require(rest.range(of: ".dropDestination(for: URL.self) { urls, _ in"))
        let open = try #require(rest.range(of: "} else {\n            VStack(spacing: 0) {"))
        #expect(drop.lowerBound < open.lowerBound, "the drop is not on the empty page")
        #expect(rest[..<drop.lowerBound].contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"),
                "the drop takes only what the page draws, not the whole page")
    }

    /// **The narrowest column, 260pt, still reads** — rendered for a look, and the folder column
    /// goes below its width rather than squeezing the name.
    @Test func theNarrowestColumnKeepsTheName() throws {
        #expect(EditorRecentFilesPage<EmptyView>.folderColumnMinimumListWidth > 260 - 32)
        let full = store()
        full.record(path: "/n/Recipes/A rather long recipe name.md", kind: .text, at: Date().addingTimeInterval(-120))
        full.record(path: "/n/Scans/Lease.pdf", kind: .pdf, at: Date().addingTimeInterval(-90_000))
        _ = try #require(render(EditorWorkspaceView.fixture(recentFiles: full, onOpenRecent: { _ in }),
                                width: 260, name: "te58-narrow"))
    }

    // MARK: Rendering

    private struct Pixels { let bytes: [UInt8]; let width: Int; let height: Int }

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat = 420, name: String) -> Pixels? {
        let size = CGSize(width: width, height: height)
        let host = NSHostingView(rootView: view
            .environment(\.controlActiveState, .key)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.buryUnderEverything()
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        // Two passes: the list's width is measured on the first, and the folder column follows it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print("[te58-render] \(out)")
        guard let data = rep.bitmapData else { return nil }
        return Pixels(bytes: Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh)),
                      width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    private func differing(_ a: Pixels, _ b: Pixels) -> Int {
        guard a.bytes.count == b.bytes.count else { return .max }
        return zip(a.bytes, b.bytes).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }
}
