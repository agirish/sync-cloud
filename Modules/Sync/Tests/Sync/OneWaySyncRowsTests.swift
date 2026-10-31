import Darwin
import Foundation
import Testing
@testable import Sync

/// What Now says after a look, and what the lister and setup read off the disk.
@Suite struct OneWaySyncRowsTests {
    typealias Sync = OneWaySyncRunTests.Sync
    let run = OneWaySyncRunTests()

    @Test func anEditInDropboxIsAFileRowWithChooseAVersion() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Legal/POA.pdf", "iCloud's", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        try run.write(world, .dropbox, "Legal/POA.pdf", "edited", modified: OneWayDiskWorld.day0)
        let rows = OneWaySyncRows.rows(for: sync.look(), knownUnsynced: [], at: sync.now)
        #expect(rows.map(\.id) == ["ows:file:Legal/POA.pdf"])
        #expect(rows.first?.title == "POA.pdf was edited in Dropbox")
        #expect(rows.first?.buttons == [.chooseAVersion])
        #expect(rows.first?.scope == .file(folder: "Legal", path: "Legal/POA.pdf"))
    }

    @Test func overTheLimitInOneFolderIsOneRowForTheFolder() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        for index in 0..<30 { try run.write(world, .iCloud, "Legal/\(index).pdf", "file \(index)") }
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        for index in 0..<30 { try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Legal/\(index).pdf")) }
        try await sync.run()
        sync.now = sync.now.addingTimeInterval(31 * 60)
        let rows = OneWaySyncRows.rows(for: sync.look(), knownUnsynced: [], at: sync.now)
        #expect(rows.map(\.id) == ["ows:folder:Legal:limit"])
        #expect(rows.first?.title == "Legal: 30 removals wait for you")
        #expect(rows.first?.buttons == [.review])
    }

    @Test func aNewICloudFolderAndDropboxOnlyFilesAreForYourInformation() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try FileManager.default.createDirectory(at: world.iCloud.appendingPathComponent("Taxes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: world.iCloud.appendingPathComponent("Work"), withIntermediateDirectories: true)
        try run.write(world, .dropbox, "Finance/mine.pdf", "mine")
        let rows = OneWaySyncRows.rows(for: sync.look(), knownUnsynced: ["Work"], at: sync.now)
        #expect(rows.map(\.id) == ["ows:info:dropbox-only", "ows:info:new-folder:Taxes"])
        #expect(rows.map(\.kind) == [.information, .information])
        #expect(rows.last?.detail == "Not synced. Dropbox has no Taxes folder.")
    }

    @Test func symlinksAndNamesDropboxWontTakeAreSkippedAndSaidSo() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/real.pdf", "real")
        try run.write(world, .iCloud, "Finance/desktop.ini", "x")
        try run.write(world, .iCloud, "Finance/.DS_Store", "x")
        try FileManager.default.createSymbolicLink(atPath: world.iCloud.appendingPathComponent("Finance/link").path, withDestinationPath: "/tmp")
        let side = OneWaySyncLister(side: .iCloud, parent: world.iCloud).list(syncedFolders: ["Finance"])
        #expect(side.listing.items.map(\.path) == ["Finance", "Finance/real.pdf"])
        #expect(side.skipped.map(\.path).sorted() == ["Finance/desktop.ini", "Finance/link"])
        #expect(OneWaySyncRows.skippedDetail(side.skipped) == "desktop.ini (Dropbox won’t take it), 1 symlink · nothing else waits")
    }

    @Test func aPackageIsOneFileAndASharedFolderIsExcluded() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/Deck.key/Index.zip", "one")
        try run.write(world, .iCloud, "Finance/Deck.key/Data/a.png", "two!")
        try run.write(world, .iCloud, "Finance/Shared/x.pdf", "x")
        var lister = OneWaySyncLister(side: .iCloud, parent: world.iCloud)
        lister.isShared = { $0.lastPathComponent == "Shared" }
        let items = lister.list(syncedFolders: ["Finance"]).listing.items
        let deck = try #require(items.first { $0.path == "Finance/Deck.key" })
        #expect(deck.kind == .file)
        #expect(deck.size == 7)
        #expect(!items.contains { $0.path.hasPrefix("Finance/Deck.key/") })
        #expect(items.first { $0.path == "Finance/Shared/x.pdf" }?.isExcluded == true)
        // Contents of a package hash over what is inside it, by path.
        let hash = OneWaySyncContents.hash(at: world.iCloud.appendingPathComponent("Finance/Deck.key").path)
        #expect(hash != nil)
        try run.write(world, .iCloud, "Finance/Deck.key/Data/a.png", "two?")
        #expect(OneWaySyncContents.hash(at: world.iCloud.appendingPathComponent("Finance/Deck.key").path) != hash)
    }

    @Test func setupOffersFoldersInBothButNotSharedOrDropboxManagedOnes() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        for name in ["Family", "Shared", "Apps"] {
            for base in [world.iCloud, world.dropbox] {
                try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
            }
        }
        try FileManager.default.createDirectory(at: world.iCloud.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        var iCloudLister = OneWaySyncLister(side: .iCloud, parent: world.iCloud)
        iCloudLister.isShared = { $0.lastPathComponent == "Shared" }
        let choices = OneWaySyncSetup.choices(iCloud: iCloudLister.list(syncedFolders: []),
                                              dropbox: OneWaySyncLister(side: .dropbox, parent: world.dropbox).list(syncedFolders: []))
        #expect(choices.map(\.name) == ["Apps", "Family", "Notes", "Shared"])
        #expect(choices.filter(\.canTick).map(\.name) == ["Family"])
        #expect(choices.first { $0.name == "Shared" }?.notOffered == "shared")
        #expect(choices.first { $0.name == "Apps" }?.notOffered == "managed by Dropbox")
        #expect(choices.first { $0.name == "Notes" }?.place == .onlyInICloud)
    }

    @Test func aParentReachedThroughALinkStopsWhenTheLinkLeadsElsewhere() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let link = world.root.appendingPathComponent("Documents link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: world.iCloud)
        let parent = OneWaySyncSetup.parentRecord(link)
        #expect(parent.linkTarget == world.iCloud.path)
        #expect(OneWaySyncSetup.parentProblem(parent) == nil)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: world.dropbox)
        #expect(OneWaySyncSetup.parentProblem(parent) == "Documents link now leads to another folder")
    }

    @Test func theAccountFolderIsTheOneDirectlyInCloudStorage() {
        let url = URL(fileURLWithPath: "/Users/me/Library/CloudStorage/Dropbox/Documents/SyncCloud Test")
        #expect(OneWaySyncSetup.accountFolder(containing: url)?.path == "/Users/me/Library/CloudStorage/Dropbox")
        #expect(OneWaySyncSetup.accountFolder(containing: URL(fileURLWithPath: "/Users/me/Documents")) == nil)
    }
}
