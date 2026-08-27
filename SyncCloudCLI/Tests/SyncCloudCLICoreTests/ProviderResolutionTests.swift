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
    CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud", rootPath: "/icloud/docs", type: .iCloud),
    CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)", imageName: "onedrive", rootPath: "/od/docs", type: .oneDrive),
]

@Suite struct ProviderResolutionTests {

    @Test func testMatchesById() throws {
        let resolved = try resolveProviderOrPath(
            value: "OneDrive-Personal", label: "Left", providers: providers,
            fileManager: StubFileManager(directories: ["/od/docs"]))
        #expect(resolved.id == "OneDrive-Personal")
        #expect(resolved.landingPath == "/od/docs")
    }

    /// **`-L <source>` scans that source's LANDING folder, not the account above it.**
    ///
    /// Every other fixture here has an empty `openAt`, which makes `rootPath` and `landingPath` the
    /// same string and so cannot tell the two apart — this is the one case that can. It matters
    /// because a source's root widened to the whole account: `synccloud -L OneDrive-Personal` used
    /// to scan the Documents folder, and reading `rootPath` in `CommandRunner.scanForDifferences`
    /// would silently point every provider-addressed run at the entire account instead, with
    /// nothing on screen to say the subject had changed.
    @Test func testAProviderAddressedRootResolvesToItsLandingFolderNotItsRoot() throws {
        let withOpenAt = [
            CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)",
                          imageName: "onedrive", rootPath: "/od", openAt: "Documents",
                          type: .oneDrive),
        ]
        let resolved = try resolveProviderOrPath(
            value: "OneDrive-Personal", label: "Left", providers: withOpenAt,
            fileManager: StubFileManager(directories: ["/od", "/od/Documents"]))
        #expect(resolved.landingPath == "/od/Documents")
        #expect(resolved.rootPath == "/od", "the root is still the whole account")
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
        #expect(resolved.landingPath == "/some/dir")
        #expect(resolved.displayName == "Left")
    }

    @Test func testExpandsTildeInPathFallback() throws {
        let home = NSHomeDirectory()
        let resolved = try resolveProviderOrPath(
            value: "~/somewhere", label: "Left", providers: providers,
            fileManager: StubFileManager(directories: ["\(home)/somewhere"]))
        #expect(resolved.landingPath == "\(home)/somewhere")
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

    /// **This used to assert that the provider wins, and that is the behaviour being changed.**
    ///
    /// It read "a provider id resolves even if a same-named path exists on disk" — stated, with no
    /// reason given for preferring one reading. The fixture is the hazardous case: a directory
    /// named `iCloud` in the working directory against a provider rooted somewhere else entirely.
    /// `sync` is a mass copy, so resolving that silently is one whole tree written into another,
    /// and neither precedence is defensible — reversing it only moves the misfire onto whoever
    /// meant the provider. It is refused now, with both disambiguating spellings named.
    ///
    /// The narrower case where both readings are the SAME folder still resolves — see below.
    @Test func testAProviderThatShadowsADifferentSameNamedDirectoryIsRefused() {
        #expect(throws: ProviderResolutionError.self) {
            try resolveProviderOrPath(
                value: "iCloud", label: "Left", providers: providers,
                fileManager: StubFileManager(directories: ["/icloud/docs", "iCloud"]))
        }
    }

    /// **`~/iCloud` symlinked to iCloud Drive is a common convention, and there is no hazard in
    /// it** — both readings are one folder, so the guard must not fire. Compared after resolving
    /// symlinks, which is what makes the two identical rather than merely similar.
    @Test func testAProviderWhoseRootIsTheSameFolderAsThePathStillResolves() throws {
        // The provider's root IS what the relative value canonicalises to, which is the shape the
        // symlink convention produces on a real machine.
        let sameTree = canonicalPath("iCloud")
        let shadowing = [CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                                       rootPath: sameTree, type: .iCloud)]
        let resolved = try resolveProviderOrPath(
            value: "iCloud", label: "Left", providers: shadowing,
            fileManager: StubFileManager(directories: [sameTree, "iCloud"]))
        #expect(resolved.id == "iCloud", "one folder named two ways was refused as an ambiguity")
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
                      rootPath: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs", type: .iCloud),
        CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)", imageName: "onedrive",
                      rootPath: "/Users/u/Library/CloudStorage/OneDrive-Personal/Documents", type: .oneDrive),
        CloudProvider(id: "GoogleDrive-me", displayName: "Google Drive (me)", imageName: "googledrive",
                      rootPath: "/Users/u/Library/CloudStorage/GoogleDrive-me/My Drive/Documents", type: .googleDrive),
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
            rootPath: "~/Dropbox", type: .dropBox)]
        let resolved = try resolveProviderOrPath(
            value: "Dropbox", label: "Left", providers: tilded,
            fileManager: StubFileManager(directories: ["\(home)/Dropbox"]))
        #expect(resolved.id == "Dropbox")
    }

    // MARK: - An argument that names both is refused, not guessed

    /// **`-L Dropbox` beside a local folder called `Dropbox` addressed the PROVIDER.**
    ///
    /// The provider branch wins by position, so the CLI silently took the provider's root instead
    /// of the directory in front of the user — and `sync` is a mass copy, so guessing wrong is not
    /// a wrong listing, it is one whole tree written into another.
    ///
    /// Reversing the precedence would move the same silent misfire onto whoever meant the
    /// provider, so neither order is defensible and the ambiguity is refused instead. The cost is
    /// one re-run with a disambiguating spelling; the cost of being wrong is a sync.
    @Test func testRefusesAValueThatIsBothAProviderAndADirectory() {
        let fm = StubFileManager(directories: ["/icloud/docs", "iCloud"])
        #expect(throws: ProviderResolutionError.self) {
            try resolveProviderOrPath(value: "iCloud", label: "Left", providers: providers,
                                      fileManager: fm)
        }
    }

    /// The refusal has to be usable: it names both readings and the spelling that picks each.
    @Test func testTheAmbiguityMessageOffersBothWaysOut() {
        let fm = StubFileManager(directories: ["/icloud/docs", "iCloud"])
        do {
            _ = try resolveProviderOrPath(value: "iCloud", label: "Left", providers: providers,
                                          fileManager: fm)
            Issue.record("expected a refusal")
        } catch let error as ProviderResolutionError {
            #expect(error.message.contains("/icloud/docs"), "the provider reading is not named")
            #expect(error.message.contains("./iCloud"), "the message does not say how to mean the directory")
        } catch {
            Issue.record("expected ProviderResolutionError, got \(error)")
        }
    }

    /// **And the way out actually works.** A provider id never contains a slash, so `./name` misses
    /// the provider branch and resolves as a path — asserted, because a refusal that pointed at a
    /// spelling which also failed would be worse than the guess it replaced.
    @Test func testTheDotSlashSpellingResolvesToTheDirectory() throws {
        let fm = StubFileManager(directories: ["/icloud/docs", "./iCloud"])
        let resolved = try resolveProviderOrPath(value: "./iCloud", label: "Left",
                                                 providers: providers, fileManager: fm)
        #expect(resolved.landingPath == "./iCloud", "the escape hatch the refusal offers does not work")
    }

    /// An unambiguous provider name still resolves — the guard fires only where both readings
    /// exist, and must not have made every provider argument a refusal.
    @Test func testAProviderWithNoSameNamedDirectoryStillResolves() throws {
        let resolved = try resolveProviderOrPath(
            value: "iCloud", label: "Left", providers: providers,
            fileManager: StubFileManager(directories: ["/icloud/docs"]))
        #expect(resolved.id == "iCloud")
    }
}
