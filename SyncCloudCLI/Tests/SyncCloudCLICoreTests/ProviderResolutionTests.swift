import Testing
import Foundation
import Sync
@testable import SyncCloudCLICore

/// Minimal FileManaging stub: only fileExists(atPath:isDirectory:) is consulted by provider
/// resolution. Directories and plain files are tracked separately so root validation
/// (exists AND is a directory) can be exercised for both failure shapes.
private struct StubFileManager: FileManaging {
    let directories: Set<String>
    var files: Set<String> = []

    func fileExists(atPath path: String) -> Bool {
        directories.contains(path) || files.contains(path)
    }
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        isDirectory?.pointee = ObjCBool(directories.contains(path))
        return fileExists(atPath: path)
    }
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] { [:] }
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {}
    func copyItem(at srcURL: URL, to dstURL: URL) throws {}
    func moveItem(at srcURL: URL, to dstURL: URL) throws {}
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {}
    func removeItem(at URL: URL) throws {}
    func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? { nil }
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
            fileManager: StubFileManager(directories: ["/od/docs"]))
        #expect(resolved.id == "OneDrive-Personal")
        #expect(resolved.path == "/od/docs")
    }

    @Test func testMatchesByDisplayName() throws {
        let resolved = try resolveProviderOrPath(
            value: "OneDrive (Personal)", label: "Right", providers: providers,
            fileManager: StubFileManager(directories: ["/od/docs"]))
        #expect(resolved.id == "OneDrive-Personal")
    }

    @Test func testFallsBackToExistingPath() throws {
        let resolved = try resolveProviderOrPath(
            value: "/some/dir", label: "Left", providers: providers,
            fileManager: StubFileManager(directories: ["/some/dir"]))
        #expect(resolved.id == "/some/dir")
        #expect(resolved.path == "/some/dir")
        #expect(resolved.displayName == "Left")
    }

    @Test func testExpandsTildeInPathFallback() throws {
        let home = NSHomeDirectory()
        let resolved = try resolveProviderOrPath(
            value: "~/somewhere", label: "Left", providers: providers,
            fileManager: StubFileManager(directories: ["\(home)/somewhere"]))
        #expect(resolved.path == "\(home)/somewhere")
    }

    @Test func testUnknownValueThrowsWithLabel() {
        #expect {
            try resolveProviderOrPath(
                value: "nope", label: "Right", providers: providers,
                fileManager: StubFileManager(directories: []))
        } throws: { error in
            (error as? ProviderResolutionError)?.message.contains("'nope' for Right") == true
        }
    }

    @Test func testProviderMatchWinsOverPathCheck() throws {
        // A provider id resolves even if a same-named path exists on disk.
        let resolved = try resolveProviderOrPath(
            value: "iCloud", label: "Left", providers: providers,
            fileManager: StubFileManager(directories: ["/icloud/docs", "iCloud"]))
        #expect(resolved.path == "/icloud/docs")
    }

    // MARK: Root validation
    // A missing or non-directory root scans as an empty side (getFilesInDirectory yields an
    // empty map), which sync would "correct" by mass-copying into a dead tree — so resolution
    // must refuse both shapes for provider matches and ad-hoc paths alike.

    @Test func testProviderWithMissingRootThrows() {
        #expect {
            try resolveProviderOrPath(
                value: "OneDrive-Personal", label: "Left", providers: providers,
                fileManager: StubFileManager(directories: []))
        } throws: { error in
            let message = (error as? ProviderResolutionError)?.message ?? ""
            return message.contains("/od/docs") && message.contains("unmounted")
        }
    }

    @Test func testProviderWithFileAsRootThrows() {
        #expect {
            try resolveProviderOrPath(
                value: "iCloud", label: "Right", providers: providers,
                fileManager: StubFileManager(directories: [], files: ["/icloud/docs"]))
        } throws: { error in
            let message = (error as? ProviderResolutionError)?.message ?? ""
            return message.contains("/icloud/docs") && message.contains("not a directory")
        }
    }

    @Test func testAdHocPathThatIsAFileThrows() {
        #expect {
            try resolveProviderOrPath(
                value: "/some/file.txt", label: "Left", providers: providers,
                fileManager: StubFileManager(directories: [], files: ["/some/file.txt"]))
        } throws: { error in
            let message = (error as? ProviderResolutionError)?.message ?? ""
            return message.contains("/some/file.txt") && message.contains("not a directory")
        }
    }

    @Test func testProviderRootWithTildeIsExpandedBeforeValidation() throws {
        let home = NSHomeDirectory()
        let tilded = [CloudProvider(
            id: "Dropbox", displayName: "Dropbox", imageName: "dropbox",
            path: "~/Dropbox", type: .dropBox)]
        let resolved = try resolveProviderOrPath(
            value: "Dropbox", label: "Left", providers: tilded,
            fileManager: StubFileManager(directories: ["\(home)/Dropbox"]))
        #expect(resolved.id == "Dropbox")
    }
}
