import Testing
import Foundation
@testable import Sync

/// Keep Downloaded's pin and the folder-wide Download All, on a real disk under a stand-in home.
///
/// The pin is a plain extended attribute, so a test writes and reads the very attribute the app
/// does. What no test can make is a cloud-only file (`SF_DATALESS` is set only by a provider), so
/// Download All's walk is handed a `statFlags` that names which files to treat as cloud-only — the
/// walk, the listing and the selection all run as they do in the app.
@Suite struct KeepDownloadedTests {

    /// A fresh stand-in home, with an iCloud container, removed when the test ends.
    private final class Home {
        let path: String
        var container: String { path + "/Library/Mobile Documents/com~apple~CloudDocs" }

        init() throws {
            path = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("KeepDownloaded-\(UUID().uuidString)").resolvingSymlinksInPath().path
            try FileManager.default.createDirectory(atPath: path + "/Library/Mobile Documents/com~apple~CloudDocs",
                                                    withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }

        @discardableResult
        func make(_ relative: String, directory: Bool = false) throws -> String {
            let full = path + "/" + relative
            if directory {
                try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try Data("x".utf8).write(to: URL(fileURLWithPath: full))
            }
            return full
        }
    }

    // MARK: - Where the pin is offered

    @Test func aFileOutsideICloudIsNotOffered() throws {
        let home = try Home()
        let file = try home.make("Projects/notes.txt")
        #expect(KeepDownloaded.state(ofPath: file, home: home.path) == .unavailable)
        // Another provider's folder neither: the pin was measured ignored there.
        let drive = try home.make("Library/CloudStorage/GoogleDrive-a/My Drive/b.txt")
        #expect(KeepDownloaded.state(ofPath: drive, home: home.path) == .unavailable)
    }

    @Test func iCloudDriveIsOfferedButNotTheFolderThatHoldsEveryContainer() throws {
        let home = try Home()
        let file = try home.make("Library/Mobile Documents/com~apple~CloudDocs/a.txt")
        #expect(KeepDownloaded.state(ofPath: file, home: home.path) == .off)
        #expect(KeepDownloaded.state(ofPath: home.container, home: home.path) == .off)
        #expect(KeepDownloaded.state(ofPath: home.path + "/Library/Mobile Documents", home: home.path) == .unavailable)
    }

    /// `~/Desktop` and `~/Documents` are iCloud's only when Desktop & Documents sync made them so,
    /// which their domain attribute says — and only iCloud's domain counts.
    ///
    /// The domain is handed in, never staged: writing `com.apple.file-provider-domain-id` is
    /// refused on the CI runner (a launchd service) while a Terminal shell may write it, so a test
    /// that set it went red there and green here. Reading it is the next test's.
    @Test func desktopAndDocumentsAreOfferedOnlyWhenICloudOwnsThem() throws {
        let home = try Home()
        let doc = try home.make("Documents/Taxes/2026.pdf")
        let desk = try home.make("Desktop/shot.png")
        let documents = home.path + "/Documents"
        func owned(by domain: String?) -> KeepDownloaded.DomainOf {
            { [documents] in $0 == documents ? domain : nil }
        }

        #expect(KeepDownloaded.state(ofPath: doc, home: home.path, domainOf: owned(by: nil)) == .unavailable)
        #expect(KeepDownloaded.state(ofPath: doc, home: home.path,
                                     domainOf: owned(by: "com.example.provider/X")) == .unavailable)

        let iCloud = owned(by: "com.apple.CloudDocs.iCloudDriveFileProvider/X")
        #expect(KeepDownloaded.state(ofPath: doc, home: home.path, domainOf: iCloud) == .off)
        #expect(KeepDownloaded.state(ofPath: documents, home: home.path, domainOf: iCloud) == .off)
        #expect(MaterializationStatus.isInCloudLocation(documents + "/Taxes", home: home.path, domainOf: iCloud))
        // The other folder is asked about on its own.
        #expect(KeepDownloaded.state(ofPath: desk, home: home.path, domainOf: iCloud) == .unavailable)
    }

    /// The real reader reads an attribute's bytes back as text, and answers nil for one that is
    /// absent — on an unprotected name, which any process may write.
    @Test func theDomainReaderReadsAnAttributesText() throws {
        let home = try Home()
        let folder = try home.make("Documents", directory: true)
        let name = "com.abhishekgirish.SyncCloud.test-domain"
        let value = "com.apple.CloudDocs.iCloudDriveFileProvider/X"
        #expect(setxattr(folder, name, value, value.utf8.count, 0, 0) == 0)
        #expect(KeepDownloaded.attribute(name, atPath: folder) == value)
        #expect(KeepDownloaded.attribute(name + ".absent", atPath: folder) == nil)
        // And the real domain reader asks the real attribute: absent on a folder nothing owns.
        #expect(KeepDownloaded.realDomainOf(folder) == nil)
    }

    // MARK: - The pin itself

    @Test func pinningWritesFindersAttributeAndUnpinningRemovesIt() throws {
        let home = try Home()
        let file = try home.make("Library/Mobile Documents/com~apple~CloudDocs/a.txt")

        try KeepDownloaded.set(true, atPath: file)
        #expect(KeepDownloaded.state(ofPath: file, home: home.path) == .on)
        #expect(KeepDownloaded.attribute("com.apple.fileprovider.pinned#PX", atPath: file) == "1")

        try KeepDownloaded.set(false, atPath: file)
        #expect(KeepDownloaded.state(ofPath: file, home: home.path) == .off)
        #expect(!KeepDownloaded.hasAttribute(KeepDownloaded.attributeName, atPath: file))
        // Unpinning what is not pinned is already done, not an error.
        try KeepDownloaded.set(false, atPath: file)
    }

    @Test func everythingBelowAPinnedFolderIsKeptByIt() throws {
        let home = try Home()
        let folder = try home.make("Library/Mobile Documents/com~apple~CloudDocs/Work", directory: true)
        let deep = try home.make("Library/Mobile Documents/com~apple~CloudDocs/Work/2026/q4/plan.txt")

        try KeepDownloaded.set(true, atPath: folder)
        #expect(KeepDownloaded.state(ofPath: deep, home: home.path) == .inherited(fromFolder: folder))
        #expect(KeepDownloaded.state(ofPath: folder, home: home.path) == .on)

        // Its own pin outranks the folder's: turning that off is what the item's toggle can do.
        try KeepDownloaded.set(true, atPath: deep)
        #expect(KeepDownloaded.state(ofPath: deep, home: home.path) == .on)
    }

    /// A pin above the iCloud root is not iCloud's to honour, and the walk up stops at the root.
    @Test func aPinAboveTheRootDoesNotCount() throws {
        let home = try Home()
        let file = try home.make("Library/Mobile Documents/com~apple~CloudDocs/a.txt")
        try KeepDownloaded.set(true, atPath: home.path + "/Library/Mobile Documents")
        #expect(KeepDownloaded.state(ofPath: file, home: home.path) == .off)
    }

    /// A link is pinned as the file it points to — the file the provider would fetch.
    @Test func aLinkIsPinnedAsItsTarget() throws {
        let home = try Home()
        let file = try home.make("Library/Mobile Documents/com~apple~CloudDocs/a.txt")
        let link = home.path + "/Library/Mobile Documents/com~apple~CloudDocs/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)

        try KeepDownloaded.set(true, atPath: link)
        #expect(KeepDownloaded.hasAttribute(KeepDownloaded.attributeName, atPath: file))
        #expect(KeepDownloaded.state(ofPath: link, home: home.path) == .on)
    }

    // MARK: - Where Download All is offered

    @Test func cloudLocationsAreProvidersFoldersAndICloud() throws {
        let home = try Home()
        let h = home.path
        #expect(MaterializationStatus.isInCloudLocation(h + "/Library/CloudStorage/Dropbox", home: h))
        #expect(MaterializationStatus.isInCloudLocation(h + "/Library/CloudStorage/Dropbox/Photos", home: h))
        // APFS compares names without case, and so does this.
        #expect(MaterializationStatus.isInCloudLocation(h + "/library/cloudstorage/Dropbox/Photos", home: h))
        #expect(MaterializationStatus.isInCloudLocation(home.container + "/Work", home: h))
        #expect(!MaterializationStatus.isInCloudLocation(h + "/Library/CloudStorage", home: h))
        #expect(!MaterializationStatus.isInCloudLocation(h + "/Projects", home: h))
        #expect(!MaterializationStatus.isInCloudLocation(h + "/Library/CloudStorageOld/x", home: h))
    }

    // MARK: - Download All's walk

    @Test func everyCloudOnlyFileAtAnyDepthIsRequestedAndNothingElse() throws {
        let home = try Home()
        let top = try home.make("Library/CloudStorage/P/Folder", directory: true)
        let a = try home.make("Library/CloudStorage/P/Folder/a.bin")
        let local = try home.make("Library/CloudStorage/P/Folder/local.bin")
        let deep = try home.make("Library/CloudStorage/P/Folder/sub/deeper/c.bin")
        let cloudOnlyFolder = try home.make("Library/CloudStorage/P/Folder/sub/deeper", directory: true)
        let cloudOnly: Set<String> = [a, deep, cloudOnlyFolder]

        var asked: [String] = []
        let result = MaterializationStatus.downloadContents(
            ofFolder: top,
            statFlags: { cloudOnly.contains($0) ? MaterializationStatus.datalessFlag : 0 },
            download: { asked.append($0) })

        #expect(Set(asked) == [a, deep])
        #expect(Set(result.requested) == [a, deep])
        #expect(result.refused.isEmpty)
        #expect(result.unreadable == 0)
        #expect(!asked.contains(local))
    }

    @Test func aRefusedFileIsReportedAndTheRestStillAsked() throws {
        let home = try Home()
        let top = try home.make("Library/CloudStorage/P/Folder", directory: true)
        let a = try home.make("Library/CloudStorage/P/Folder/a.bin")
        let b = try home.make("Library/CloudStorage/P/Folder/b.bin")
        struct Refused: Error {}

        let result = MaterializationStatus.downloadContents(
            ofFolder: top,
            statFlags: { _ in MaterializationStatus.datalessFlag },
            download: { if $0 == a { throw Refused() } })

        #expect(result.refused == [a])
        #expect(result.requested == [b])
    }

    /// Nothing outside the folder is fetched through a link — not a linked file, not the contents
    /// of a linked folder.
    @Test func linksAreNotFollowedOutOfTheFolder() throws {
        let home = try Home()
        let top = try home.make("Library/CloudStorage/P/Folder", directory: true)
        let outsideFile = try home.make("Elsewhere/big.mov")
        let outsideFolder = try home.make("Elsewhere/Archive", directory: true)
        let outsideInner = try home.make("Elsewhere/Archive/old.mov")
        try FileManager.default.createSymbolicLink(atPath: top + "/big.mov", withDestinationPath: outsideFile)
        try FileManager.default.createSymbolicLink(atPath: top + "/Archive", withDestinationPath: outsideFolder)
        let cloudOnly: Set<String> = [outsideFile, outsideInner, top + "/big.mov",
                                      top + "/Archive/old.mov"]
        // The link's own path is stat-ed as the link — never cloud-only — exactly as `lstat` does.
        let flags: MaterializationStatus.StatFlags = { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            if (info.st_mode & S_IFMT) == S_IFLNK { return 0 }
            return cloudOnly.contains(path) ? MaterializationStatus.datalessFlag : 0
        }

        var asked: [String] = []
        let result = MaterializationStatus.downloadContents(ofFolder: top, statFlags: flags,
                                                            download: { asked.append($0) })
        #expect(asked.isEmpty)
        #expect(result.requested.isEmpty)
    }

    @Test func aFolderTheWalkCannotReadIsCounted() throws {
        let home = try Home()
        let top = try home.make("Library/CloudStorage/P/Folder", directory: true)
        let locked = try home.make("Library/CloudStorage/P/Folder/locked", directory: true)
        try home.make("Library/CloudStorage/P/Folder/locked/x.bin")
        try home.make("Library/CloudStorage/P/Folder/open.bin")
        #expect(chmod(locked, 0) == 0)
        defer { chmod(locked, 0o755) }

        let result = MaterializationStatus.downloadContents(
            ofFolder: top, statFlags: { _ in MaterializationStatus.datalessFlag }, download: { _ in })
        #expect(result.unreadable == 1)
        #expect(result.requested == [top + "/open.bin"])
    }

    // MARK: - Download All over a selection

    /// A file selected beside its own folder, and a folder beside one inside it, are each asked
    /// for once.
    @Test func anOverlappingSelectionAsksForEachFileOnce() throws {
        let home = try Home()
        let top = try home.make("Library/CloudStorage/P/Folder", directory: true)
        let inner = try home.make("Library/CloudStorage/P/Folder/sub", directory: true)
        let a = try home.make("Library/CloudStorage/P/Folder/a.bin")
        let b = try home.make("Library/CloudStorage/P/Folder/sub/b.bin")
        let loose = try home.make("Library/CloudStorage/P/loose.bin")
        let here = try home.make("Library/CloudStorage/P/here.bin")
        let cloudOnly: Set<String> = [a, b, loose]

        var asked: [String] = []
        let result = MaterializationStatus.downloadAll(
            files: [a, loose, here], folders: [top, inner],
            statFlags: { cloudOnly.contains($0) ? MaterializationStatus.datalessFlag : 0 },
            download: { asked.append($0) })

        #expect(asked.sorted() == [a, b, loose].sorted())
        #expect(result.requested.sorted() == [a, b, loose].sorted())
        #expect(!asked.contains(here), "a file already here was asked for")
    }

    /// A selected link to a cloud-only file is asked for — as the link, which `download(atPath:)`
    /// fetches as its target, the way a single file's Download does.
    @Test func aSelectedLinkIsAskedForByItsTarget() throws {
        let home = try Home()
        let target = try home.make("Library/CloudStorage/P/big.mov")
        let link = home.path + "/Library/CloudStorage/P/link.mov"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        var asked: [String] = []
        let result = MaterializationStatus.downloadAll(
            files: [link], folders: [],
            statFlags: { $0 == target ? MaterializationStatus.datalessFlag : 0 },
            download: { asked.append($0) })
        #expect(asked == [link])
        #expect(result.requested == [link])
    }

    @Test func refusalsAndUnreadableFoldersAreSummedAcrossTheSelection() throws {
        let home = try Home()
        let f = try home.make("Library/CloudStorage/P/F", directory: true)
        let g = try home.make("Library/CloudStorage/P/G", directory: true)
        let lockedF = try home.make("Library/CloudStorage/P/F/locked", directory: true)
        let lockedG = try home.make("Library/CloudStorage/P/G/locked", directory: true)
        let x = try home.make("Library/CloudStorage/P/F/x.bin")
        #expect(chmod(lockedF, 0) == 0 && chmod(lockedG, 0) == 0)
        defer { chmod(lockedF, 0o755); chmod(lockedG, 0o755) }
        struct Refused: Error {}

        let result = MaterializationStatus.downloadAll(
            files: [], folders: [f, g], statFlags: { _ in MaterializationStatus.datalessFlag },
            download: { _ in throw Refused() })
        #expect(result.refused == [x])
        #expect(result.unreadable == 2)
    }
}
