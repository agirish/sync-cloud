import Testing
import Foundation
@testable import Sync

/// The picker's recent-destinations list: per provider, most recent first, and never offering a
/// folder that has since gone away.
@Suite struct DestinationRecentsTests {

    private func defaults() -> ScratchDefaults { ScratchDefaults("DestinationRecentsTests") }

    /// A disk where every recorded folder exists, so `load` is testing ordering rather than pruning.
    private func liveDisk(_ paths: [String]) throws -> MockFileManager {
        let fm = MockFileManager()
        for path in paths {
            try fm.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        }
        return fm
    }

    @Test func testMostRecentComesFirst() throws {
        let d = defaults()
        let fm = try liveDisk(["/p/A", "/p/B"])
        DestinationRecents.record("/p/A", providerRoot: "/p", in: d)
        DestinationRecents.record("/p/B", providerRoot: "/p", in: d)
        #expect(DestinationRecents.load(providerRoot: "/p", in: d, fileManager: fm) == ["/p/B", "/p/A"])
    }

    /// Re-filing into the folder you used two moves ago promotes it rather than duplicating it.
    @Test func testRecordingAgainPromotesRatherThanDuplicates() throws {
        let d = defaults()
        let fm = try liveDisk(["/p/A", "/p/B"])
        DestinationRecents.record("/p/A", providerRoot: "/p", in: d)
        DestinationRecents.record("/p/B", providerRoot: "/p", in: d)
        DestinationRecents.record("/p/A", providerRoot: "/p", in: d)
        #expect(DestinationRecents.load(providerRoot: "/p", in: d, fileManager: fm) == ["/p/A", "/p/B"])
    }

    @Test func testTheListIsTrimmedToTheLimit() throws {
        let d = defaults()
        let paths = (1...8).map { "/p/F\($0)" }
        let fm = try liveDisk(paths)
        for path in paths { DestinationRecents.record(path, providerRoot: "/p", in: d) }
        let loaded = DestinationRecents.load(providerRoot: "/p", in: d, fileManager: fm)
        #expect(loaded.count == DestinationRecents.limit)
        #expect(loaded.first == "/p/F8")
    }

    /// Providers keep separate lists — switching provider must not offer the other one's folders.
    @Test func testProvidersDoNotShareALists() throws {
        let d = defaults()
        let fm = try liveDisk(["/p/A", "/q/B"])
        DestinationRecents.record("/p/A", providerRoot: "/p", in: d)
        DestinationRecents.record("/q/B", providerRoot: "/q", in: d)
        #expect(DestinationRecents.load(providerRoot: "/p", in: d, fileManager: fm) == ["/p/A"])
        #expect(DestinationRecents.load(providerRoot: "/q", in: d, fileManager: fm) == ["/q/B"])
    }

    /// A folder that has gone away since it was recorded is dropped on read, so the picker never
    /// offers a destination the transfer would refuse.
    @Test func testVanishedFoldersArePrunedOnRead() throws {
        let d = defaults()
        DestinationRecents.record("/p/Gone", providerRoot: "/p", in: d)
        DestinationRecents.record("/p/Here", providerRoot: "/p", in: d)
        let fm = try liveDisk(["/p/Here"])
        #expect(DestinationRecents.load(providerRoot: "/p", in: d, fileManager: fm) == ["/p/Here"])
    }

    /// A path that is now a FILE is not a destination either.
    @Test func testAPathThatBecameAFileIsPruned() throws {
        let d = defaults()
        DestinationRecents.record("/p/WasAFolder", providerRoot: "/p", in: d)
        let fm = MockFileManager()
        fm.virtualDisk["/p/WasAFolder"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        #expect(DestinationRecents.load(providerRoot: "/p", in: d, fileManager: fm).isEmpty)
    }

    /// The system-panel escape can land anywhere; this list is a per-provider shortcut, so a
    /// destination outside the provider is not remembered.
    @Test func testDestinationsOutsideTheProviderAreNotRecorded() throws {
        let d = defaults()
        let fm = try liveDisk(["/elsewhere/X"])
        DestinationRecents.record("/elsewhere/X", providerRoot: "/p", in: d)
        #expect(DestinationRecents.load(providerRoot: "/p", in: d, fileManager: fm).isEmpty)
    }

    /// Prefix aliasing: "/p" must not accept a destination in "/pictures".
    @Test func testASiblingSharingAPrefixIsNotInsideTheProvider() throws {
        let d = defaults()
        let fm = try liveDisk(["/pictures/X"])
        DestinationRecents.record("/pictures/X", providerRoot: "/p", in: d)
        #expect(DestinationRecents.load(providerRoot: "/p", in: d, fileManager: fm).isEmpty)
    }

    /// An empty root would otherwise collect every provider's destinations under one key.
    @Test func testAnEmptyRootStoresNothing() throws {
        let d = defaults()
        let fm = try liveDisk(["/p/A"])
        DestinationRecents.record("/p/A", providerRoot: "", in: d)
        #expect(DestinationRecents.load(providerRoot: "", in: d, fileManager: fm).isEmpty)
    }

    /// The key must be a literal, not derived from the root by hashing: `String.hashValue` is
    /// seeded per process, so a hashed key would change on every launch and the list would read
    /// back empty forever while appearing to save correctly.
    @Test func testTheStorageKeyIsStableAcrossReads() throws {
        let d = defaults()
        let fm = try liveDisk(["/p/A"])
        DestinationRecents.record("/p/A", providerRoot: "/p", in: d)
        let raw = d.dictionary(forKey: DestinationRecents.defaultsKey) as? [String: [String]]
        #expect(raw?["/p"] == ["/p/A"])
        #expect(DestinationRecents.load(providerRoot: "/p", in: d, fileManager: fm) == ["/p/A"])
    }
}
