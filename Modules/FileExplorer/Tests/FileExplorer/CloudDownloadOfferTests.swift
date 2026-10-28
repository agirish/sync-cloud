import Foundation
import Sync
import Testing
@testable import FileExplorer

/// The one rule behind the row menu's Download item and File ▸ Download, and Keep Downloaded's tick
/// over a selection — pure, so each term can be flipped on its own.
@Suite struct CloudDownloadOfferTests {

    private static func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }
    private static func folder(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }
    private static func cloud(_ path: String) -> Bool { path.hasPrefix("/cloud/") }
    private static func offer(_ nodes: [FileNode], cloudOnly: Set<String> = [],
                              unknown: Set<String> = []) -> CloudDownloadOffer? {
        CloudDownloadOffer.forSelection(nodes, isCloudOnly: { unknown.contains($0) ? nil : cloudOnly.contains($0) },
                                        isInCloudLocation: cloud)
    }

    // MARK: - Download

    @Test func oneCloudOnlyFileIsDownload() {
        let o = Self.offer([Self.file("/cloud/a.pdf")], cloudOnly: ["/cloud/a.pdf"])
        #expect(o == .file(path: "/cloud/a.pdf", name: "a.pdf"))
        #expect(o?.title == "Download")
    }

    /// A file already here, or one whose badge has not answered yet, is offered nothing — and a
    /// cloud location alone does not make a FILE downloadable.
    @Test func aFileThatIsNotKnownCloudOnlyIsOfferedNothing() {
        #expect(Self.offer([Self.file("/cloud/a.pdf")]) == nil)
        #expect(Self.offer([Self.file("/cloud/a.pdf")], unknown: ["/cloud/a.pdf"]) == nil)
    }

    @Test func oneFolderInACloudLocationIsDownloadAll() {
        let o = Self.offer([Self.folder("/cloud/Work")])
        #expect(o == .all(files: [], folders: ["/cloud/Work"]))
        #expect(o?.title == "Download All")
        #expect(Self.offer([Self.folder("/local/Work")]) == nil)
    }

    /// Several items: each kind is kept by its own test, and what fails it is simply left out.
    @Test func aSelectionKeepsWhatCanBeFetchedAndDropsTheRest() {
        let nodes = [Self.file("/cloud/a.pdf"), Self.file("/cloud/here.pdf"), Self.file("/cloud/unknown.pdf"),
                     Self.folder("/cloud/Work"), Self.folder("/local/Old")]
        let o = Self.offer(nodes, cloudOnly: ["/cloud/a.pdf"], unknown: ["/cloud/unknown.pdf"])
        #expect(o == .all(files: ["/cloud/a.pdf"], folders: ["/cloud/Work"]))
    }

    /// Two cloud-only files are Download All, not a Download of the first.
    @Test func twoCloudOnlyFilesAreDownloadAll() {
        let o = Self.offer([Self.file("/cloud/a"), Self.file("/cloud/b")], cloudOnly: ["/cloud/a", "/cloud/b"])
        #expect(o == .all(files: ["/cloud/a", "/cloud/b"], folders: []))
    }

    @Test func aSelectionWithNothingToFetchIsOfferedNothing() {
        #expect(Self.offer([Self.file("/cloud/a"), Self.folder("/local/F")]) == nil)
        #expect(Self.offer([]) == nil)
    }

    // MARK: - Keep Downloaded's tick

    private static func keep(_ states: [String: KeepDownloaded.State]) -> KeepDownloadedOffer? {
        KeepDownloadedOffer.forSelection(states.keys.sorted().map { file($0) }, state: { states[$0]! })
    }

    @Test func anythingOutsideICloudWithdrawsTheItem() {
        #expect(Self.keep(["/a": .off, "/b": .unavailable]) == nil)
    }

    @Test func pastTheCapTheItemIsWithdrawn() {
        let at = Dictionary(uniqueKeysWithValues: (0..<KeepDownloadedOffer.selectionCap).map { ("/\($0)", KeepDownloaded.State.off) })
        #expect(Self.keep(at) != nil)
        var over = at; over["/over"] = .off
        #expect(Self.keep(over) == nil)
    }

    @Test func theTickIsOnOnlyWhenEveryItemIsKept() {
        #expect(Self.keep(["/a": .off, "/b": .off])?.isOn == false)
        #expect(Self.keep(["/a": .on, "/b": .off])?.isOn == false)
        let mixed = Self.keep(["/a": .on, "/b": .inherited(fromFolder: "/F")])
        #expect(mixed?.isOn == true)
        #expect(mixed?.isLocked == false, "an item kept by its own pin can be unticked")
    }

    @Test func itemsAllKeptByFoldersAreLockedAndOneNamesItsFolder() {
        let two = Self.keep(["/a": .inherited(fromFolder: "/F"), "/b": .inherited(fromFolder: "/G")])
        #expect(two?.isLocked == true)
        #expect(two?.keptBy == nil)
        let one = Self.keep(["/a": .inherited(fromFolder: "/F")])
        #expect(one?.isLocked == true)
        #expect(one?.keptBy == "/F")
    }
}

/// Keep Downloaded's click: which pins change, and what is downloaded after.
@MainActor
@Suite struct SetKeepDownloadedTests {

    /// Written from the click's queue, read here once the click returns.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _pins: [(Bool, String)] = []
        private var _onMain: [Bool] = []
        var downloads: [CloudDownloadOffer] = []
        var pins: [(Bool, String)] { lock.withLock { _pins } }
        /// Whether each read and pin ran on the main thread.
        var onMain: [Bool] { lock.withLock { _onMain } }
        func pinned(_ on: Bool, _ path: String) { lock.withLock { _pins.append((on, path)); _onMain.append(Thread.isMainThread) } }
        func read() { lock.withLock { _onMain.append(Thread.isMainThread) } }
    }

    private func run(_ kept: Bool, _ nodes: [FileNode], states: [String: KeepDownloaded.State],
                     cloudOnly: Set<String> = [], failing: Set<String> = []) async -> Log {
        let log = Log()
        struct Refused: Error {}
        await CloudDownloadRequest.setKeepDownloaded(
            kept, for: nodes, from: .left, through: NotificationCenter(),
            state: { log.read(); return states[$0]! },
            pin: { on, path in
                if failing.contains(path) { throw Refused() }
                log.pinned(on, path)
            },
            isCloudOnly: { cloudOnly.contains($0) },
            download: { log.downloads.append($0) })
        return log
    }

    private let a = FileNode(id: "/i/a.pdf", name: "a.pdf", isDirectory: false)
    private let b = FileNode(id: "/i/b.pdf", name: "b.pdf", isDirectory: false)
    private let f = FileNode(id: "/i/F", name: "F", isDirectory: true)
    private let kid = FileNode(id: "/i/K/c.pdf", name: "c.pdf", isDirectory: false)

    /// Ticking pins only what is not kept, and downloads what it pinned: the folder walked, the
    /// cloud-only file fetched. An item already kept, by itself or a folder, is left alone.
    @Test func tickingPinsWhatIsNotKeptAndDownloadsIt() async {
        let log = await run(true, [a, b, f, kid],
                            states: [a.id: .off, b.id: .on, f.id: .off, kid.id: .inherited(fromFolder: "/i/K")],
                            cloudOnly: [a.id])
        #expect(log.pins.map(\.1) == [a.id, f.id])
        #expect(log.pins.allSatisfy { $0.0 })
        #expect(log.downloads == [.all(files: [a.id], folders: [f.id])])
    }

    /// One file pinned is that file's own Download, so its badge watch runs — and a pinned file
    /// already on this Mac has nothing to fetch.
    @Test func oneFilePinnedIsItsDownloadAndALocalOneFetchesNothing() async {
        #expect(await run(true, [a], states: [a.id: .off], cloudOnly: [a.id]).downloads
                == [.file(path: a.id, name: "a.pdf")])
        #expect(await run(true, [a], states: [a.id: .off]).downloads.isEmpty)
    }

    /// Unticking removes only the items' own pins — a folder's pin above is not this item's to
    /// remove — and downloads nothing.
    @Test func untickingRemovesOnlyOwnPinsAndFetchesNothing() async {
        let log = await run(false, [a, b, kid], states: [a.id: .on, b.id: .off, kid.id: .inherited(fromFolder: "/i/K")])
        #expect(log.pins.map(\.1) == [a.id])
        #expect(log.pins.allSatisfy { !$0.0 })
        #expect(log.downloads.isEmpty)
    }

    /// A pin the filesystem refused is not downloaded as if it had been kept.
    @Test func aRefusedPinIsNotDownloaded() async {
        let log = await run(true, [a, b], states: [a.id: .off, b.id: .off], cloudOnly: [a.id, b.id], failing: [a.id])
        #expect(log.downloads == [.file(path: b.id, name: "b.pdf")])
    }

    /// **The click's reads and pins never run on the main thread**, which is where it arrives: each
    /// is a call into iCloud Drive's File Provider, and a wedged one holds them for seconds.
    @Test func theClickReadsAndPinsOffTheMainThread() async {
        let log = await run(true, [a, b], states: [a.id: .off, b.id: .on])
        #expect(log.onMain.count == 3, "the click read and pinned \(log.onMain.count) times")
        #expect(!log.onMain.contains(true), "a read or a pin ran on the main thread: \(log.onMain)")
    }

    /// **The click measures from the home it is handed** — the menu's `cloudHome`, the one its tick
    /// was read from. Below a scratch home's iCloud Drive the item is pinnable; measured from the
    /// real home, the same path is in no iCloud folder and nothing would be pinned.
    @Test func theClickMeasuresFromTheHomeItIsHanded() async throws {
        let home = NSTemporaryDirectory() + "keep-home-" + UUID().uuidString
        let drive = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        try FileManager.default.createDirectory(atPath: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = drive + "/kept.txt"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        let log = Log()
        await CloudDownloadRequest.setKeepDownloaded(
            true, for: [FileNode(id: file, name: "kept.txt", isDirectory: false)],
            from: .left, through: NotificationCenter(), home: home,
            pin: { on, path in log.pinned(on, path) },
            isCloudOnly: { _ in false }, download: { log.downloads.append($0) })
        #expect(log.pins.map(\.1) == [file], "the scratch home's iCloud Drive was not the one asked")
    }
}
