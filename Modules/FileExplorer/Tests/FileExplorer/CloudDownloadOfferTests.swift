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

    private final class Log {
        var pins: [(Bool, String)] = []
        var downloads: [CloudDownloadOffer] = []
    }

    private func run(_ kept: Bool, _ nodes: [FileNode], states: [String: KeepDownloaded.State],
                     cloudOnly: Set<String> = [], failing: Set<String> = []) -> Log {
        let log = Log()
        struct Refused: Error {}
        CloudDownloadRequest.setKeepDownloaded(
            kept, for: nodes, from: .left, through: NotificationCenter(),
            state: { states[$0]! },
            pin: { on, path in
                if failing.contains(path) { throw Refused() }
                log.pins.append((on, path))
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
    @Test func tickingPinsWhatIsNotKeptAndDownloadsIt() {
        let log = run(true, [a, b, f, kid],
                      states: [a.id: .off, b.id: .on, f.id: .off, kid.id: .inherited(fromFolder: "/i/K")],
                      cloudOnly: [a.id])
        #expect(log.pins.map(\.1) == [a.id, f.id])
        #expect(log.pins.allSatisfy { $0.0 })
        #expect(log.downloads == [.all(files: [a.id], folders: [f.id])])
    }

    /// One file pinned is that file's own Download, so its badge watch runs — and a pinned file
    /// already on this Mac has nothing to fetch.
    @Test func oneFilePinnedIsItsDownloadAndALocalOneFetchesNothing() {
        #expect(run(true, [a], states: [a.id: .off], cloudOnly: [a.id]).downloads
                == [.file(path: a.id, name: "a.pdf")])
        #expect(run(true, [a], states: [a.id: .off]).downloads.isEmpty)
    }

    /// Unticking removes only the items' own pins — a folder's pin above is not this item's to
    /// remove — and downloads nothing.
    @Test func untickingRemovesOnlyOwnPinsAndFetchesNothing() {
        let log = run(false, [a, b, kid], states: [a.id: .on, b.id: .off, kid.id: .inherited(fromFolder: "/i/K")])
        #expect(log.pins.map(\.1) == [a.id])
        #expect(log.pins.allSatisfy { !$0.0 })
        #expect(log.downloads.isEmpty)
    }

    /// A pin the filesystem refused is not downloaded as if it had been kept.
    @Test func aRefusedPinIsNotDownloaded() {
        let log = run(true, [a, b], states: [a.id: .off, b.id: .off], cloudOnly: [a.id, b.id], failing: [a.id])
        #expect(log.downloads == [.file(path: b.id, name: "b.pdf")])
    }
}
