import Testing
import Foundation
import Sync
@testable import SyncCloudCLICore

/// Minimal FileManaging stub: only fileExists is consulted by provider resolution.
private struct StubFileManager: FileManaging {
    let existingPaths: Set<String>

    func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        existingPaths.contains(path)
    }
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] { [:] }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {}
    func copyItem(at srcURL: URL, to dstURL: URL) throws {}
    func moveItem(at srcURL: URL, to dstURL: URL) throws {}
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {}
    func removeItem(at URL: URL) throws {}
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? { nil }
}

private let providers = [
    CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud", path: "/icloud/docs", type: .iCloud),
    CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)", imageName: "onedrive", path: "/od/docs", type: .oneDrive),
]

@Suite struct ProviderResolutionTests {

    @Test func testMatchesById() throws {
        let resolved = try resolveProviderOrPath(
            value: "OneDrive-Personal", label: "Left", providers: providers,
            fileManager: StubFileManager(existingPaths: []))
        #expect(resolved.id == "OneDrive-Personal")
        #expect(resolved.path == "/od/docs")
    }

    @Test func testMatchesByDisplayName() throws {
        let resolved = try resolveProviderOrPath(
            value: "OneDrive (Personal)", label: "Right", providers: providers,
            fileManager: StubFileManager(existingPaths: []))
        #expect(resolved.id == "OneDrive-Personal")
    }

    @Test func testFallsBackToExistingPath() throws {
        let resolved = try resolveProviderOrPath(
            value: "/some/dir", label: "Left", providers: providers,
            fileManager: StubFileManager(existingPaths: ["/some/dir"]))
        #expect(resolved.id == "/some/dir")
        #expect(resolved.path == "/some/dir")
        #expect(resolved.displayName == "Left")
    }

    @Test func testExpandsTildeInPathFallback() throws {
        let home = NSHomeDirectory()
        let resolved = try resolveProviderOrPath(
            value: "~/somewhere", label: "Left", providers: providers,
            fileManager: StubFileManager(existingPaths: ["\(home)/somewhere"]))
        #expect(resolved.path == "\(home)/somewhere")
    }

    @Test func testUnknownValueThrowsWithLabel() {
        #expect {
            try resolveProviderOrPath(
                value: "nope", label: "Right", providers: providers,
                fileManager: StubFileManager(existingPaths: []))
        } throws: { error in
            (error as? ProviderResolutionError)?.message.contains("'nope' for Right") == true
        }
    }

    @Test func testProviderMatchWinsOverPathCheck() throws {
        // A provider id resolves even if a same-named path exists on disk.
        let resolved = try resolveProviderOrPath(
            value: "iCloud", label: "Left", providers: providers,
            fileManager: StubFileManager(existingPaths: ["iCloud"]))
        #expect(resolved.path == "/icloud/docs")
    }
}
