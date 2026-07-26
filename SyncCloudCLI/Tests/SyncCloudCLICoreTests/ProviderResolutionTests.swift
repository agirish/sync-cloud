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

    // MARK: Provider type of a path-addressed root
    // `-R <path>` used to produce a provider hard-typed `.iCloud`, which silently switched OFF the
    // two guards that key off the type: the destination name check (`ProviderNameRules.violation`,
    // applied in CommandRunner before every write) and the Google Drive date-noise filter. The same
    // OneDrive folder therefore skipped `CON.txt` when named by id and copied it when named by
    // path. The type now comes from whichever discovered provider contains the path.

    private static let cloudProviders = [
        CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                      path: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs", type: .iCloud),
        CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)", imageName: "onedrive",
                      path: "/Users/u/Library/CloudStorage/OneDrive-Personal/Documents", type: .oneDrive),
        CloudProvider(id: "GoogleDrive-me", displayName: "Google Drive (me)", imageName: "googledrive",
                      path: "/Users/u/Library/CloudStorage/GoogleDrive-me/My Drive/Documents", type: .googleDrive),
    ]

    @Test func testPathAddressedProviderRootKeepsItsProviderType() throws {
        let path = "/Users/u/Library/CloudStorage/OneDrive-Personal/Documents"
        let resolved = try resolveProviderOrPath(
            value: path, label: "Right", providers: Self.cloudProviders,
            fileManager: StubFileManager(directories: [path]))
        #expect(resolved.type == .oneDrive)
        // The guard the type gates is now live for this root.
        #expect(ProviderNameRules.violation(inRelativePath: "CON.txt", for: resolved.type) != nil)
    }

    @Test func testPathInsideTheAccountFolderButOutsideTheProviderRootStillResolves() throws {
        // A sibling of the discovered root (which is .../Documents) belongs to the same account.
        let path = "/Users/u/Library/CloudStorage/OneDrive-Personal/Photos"
        let resolved = try resolveProviderOrPath(
            value: path, label: "Right", providers: Self.cloudProviders,
            fileManager: StubFileManager(directories: [path]))
        #expect(resolved.type == .oneDrive)
    }

    @Test func testPathAddressedGoogleDriveRootIsTypedForTheDateNoiseFilter() throws {
        let path = "/Users/u/Library/CloudStorage/GoogleDrive-me/My Drive"
        let resolved = try resolveProviderOrPath(
            value: path, label: "Right", providers: Self.cloudProviders,
            fileManager: StubFileManager(directories: [path]))
        // DifferenceProcessing drops Drive's date-only noise only when this is `.googleDrive`.
        #expect(resolved.type == .googleDrive)
    }

    @Test func testOrdinaryLocalPathKeepsThePermissiveFallbackType() throws {
        // No provider claims it, so the rule-free type stands — an ordinary folder must not
        // inherit some other provider's name restrictions.
        let resolved = try resolveProviderOrPath(
            value: "/Users/u/inbox", label: "Left", providers: Self.cloudProviders,
            fileManager: StubFileManager(directories: ["/Users/u/inbox"]))
        #expect(resolved.type == .iCloud)
        #expect(ProviderNameRules.violation(inRelativePath: "CON.txt", for: resolved.type) == nil)
    }

    @Test func testSiblingSharingOnlyAStringPrefixIsNotClaimed() throws {
        // "/Users/u/Library/CloudStorage/OneDrive-Personal-old" is NOT inside "…/OneDrive-Personal".
        let path = "/Users/u/Library/CloudStorage/OneDrive-Personal-old"
        let resolved = try resolveProviderOrPath(
            value: path, label: "Left", providers: Self.cloudProviders,
            fileManager: StubFileManager(directories: [path]))
        #expect(resolved.type == .iCloud)
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
