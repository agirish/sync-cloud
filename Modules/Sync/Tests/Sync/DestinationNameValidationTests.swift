import Testing
import Foundation
@testable import Sync

/// The pre-write destination-name check: before a copy or move writes into a provider's folder,
/// a name that provider forbids (a trailing space on Dropbox) goes through `invalidNameResolver`,
/// which offers the sanitized name (then subject to the normal collision flow), rather than
/// silently creating an item the provider never uploads.
@MainActor
@Suite struct DestinationNameValidationTests {

    private func makeManager() throws -> (manager: FileSyncManager, fm: MockFileManager) {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/icloud"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/dropbox"), withIntermediateDirectories: true)
        let manager = FileSyncManager(fileManager: fm)
        manager.lastScanProviders = (
            left: CloudProvider(id: "l", displayName: "iCloud", imageName: "folder", rootPath: "/icloud", type: .iCloud),
            right: CloudProvider(id: "r", displayName: "Dropbox", imageName: "folder", rootPath: "/dropbox", type: .dropBox)
        )
        return (manager, fm)
    }

    private func addFile(_ fm: MockFileManager, _ path: String) {
        fm.virtualDisk[path] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
    }

    /// A missing-on-right difference whose copy would write `name` into the Dropbox root.
    private func missingOnRight(_ name: String) -> FileDifference {
        FileDifference(
            relativePath: name,
            leftItemPath: "/icloud/\(name)",
            rightItemPath: "/dropbox/\(name)",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right (Dropbox)"
        )
    }

    // MARK: - syncFile

    @Test func testSyncFilePromptsAndWritesSanitizedName() async throws {
        let (manager, fm) = try makeManager()
        addFile(fm, "/icloud/Report ")
        var received: NameViolationPrompt?
        manager.invalidNameResolver = { prompt in
            received = prompt
            return .useSanitizedName
        }

        let synced = await manager.syncFile(missingOnRight("Report "))

        #expect(synced)
        #expect(fm.virtualDisk["/dropbox/Report"] != nil)
        #expect(fm.virtualDisk["/dropbox/Report "] == nil)
        #expect(received?.itemName == "Report ")
        #expect(received?.sanitizedName == "Report")
        #expect(received?.providerName == "Dropbox")
        #expect(received?.reason.contains("space") == true)
        #expect(received?.isMove == false)
    }

    @Test func testSanitizedNameCollisionRunsTheNormalCollisionFlow() async throws {
        let (manager, fm) = try makeManager()
        addFile(fm, "/icloud/Report ")
        addFile(fm, "/dropbox/Report") // the sanitized target already exists
        manager.invalidNameResolver = { _ in .useSanitizedName }
        var collision: FileCollision?
        manager.collisionResolver = { c in
            collision = c
            return .replace
        }

        let synced = await manager.syncFile(missingOnRight("Report "))

        #expect(synced)
        // The collision prompt saw the sanitized destination: a normal collision, not a silent
        // second item beside the first.
        #expect(collision?.destinationPath == "/dropbox/Report")
        #expect(fm.virtualDisk["/dropbox/Report"] != nil)
        #expect(fm.virtualDisk["/dropbox/Report "] == nil)
    }

    /// A skip, and an unwired resolver (whose default must never create an unsyncable item, like
    /// the collision resolver's fail-safe), write nothing. The skip is an early exit of syncFile and
    /// must release the row's in-flight mark (set before any prompt): a leaked id would refuse
    /// Verify All and pane swaps for good and leave the row's spinner stuck.
    @Test(arguments: [InvalidNameResolution?.some(.skip), nil])
    func testSkipOrAnUnwiredResolverWritesNothing(_ answer: InvalidNameResolution?) async throws {
        let (manager, fm) = try makeManager()
        addFile(fm, "/icloud/Report ")
        if let answer { manager.invalidNameResolver = { _ in answer } }
        let diskBefore = Set(fm.virtualDisk.keys)

        let synced = await manager.syncFile(missingOnRight("Report "))

        #expect(!synced)
        #expect(Set(fm.virtualDisk.keys) == diskBefore)
        #expect(manager.syncingDifferenceIds.isEmpty)
    }

    @Test func testKeepOriginalNameWritesTheInvalidName() async throws {
        let (manager, fm) = try makeManager()
        addFile(fm, "/icloud/Report ")
        manager.invalidNameResolver = { _ in .keepOriginalName }

        let synced = await manager.syncFile(missingOnRight("Report "))

        #expect(synced)
        #expect(fm.virtualDisk["/dropbox/Report "] != nil)
    }

    @Test func testValidNamesNeverConsultTheResolver() async throws {
        let (manager, fm) = try makeManager()
        addFile(fm, "/icloud/Report.txt")
        var resolverRan = false
        manager.invalidNameResolver = { _ in
            resolverRan = true
            return .skip
        }

        let synced = await manager.syncFile(missingOnRight("Report.txt"))

        #expect(synced)
        #expect(!resolverRan)
        #expect(fm.virtualDisk["/dropbox/Report.txt"] != nil)
    }

    @Test func testInvalidNameForPermissiveProviderIsNotChecked() async throws {
        // Copying "Report " INTO iCloud (which allows it) must not prompt: the rule set
        // belongs to the destination provider, not to the name.
        let (manager, fm) = try makeManager()
        addFile(fm, "/dropbox/Report ") // pathological but possible: local-only invalid name
        var resolverRan = false
        manager.invalidNameResolver = { _ in
            resolverRan = true
            return .skip
        }
        let diff = FileDifference(
            relativePath: "Report ",
            leftItemPath: "/icloud/Report ",
            rightItemPath: "/dropbox/Report ",
            type: .missingOnLeft,
            action: .copyToLeft,
            description: "Missing on left (iCloud)"
        )

        let synced = await manager.syncFile(diff)

        #expect(synced)
        #expect(!resolverRan)
        #expect(fm.virtualDisk["/icloud/Report "] != nil)
    }

    @Test func testWithoutScanProvidersNoCheckRuns() async throws {
        // No scan has attributed roots to providers (tests, CLI cold start): the check stands
        // down and the transfer goes ahead unchecked.
        let (manager, fm) = try makeManager()
        manager.lastScanProviders = nil
        addFile(fm, "/icloud/Report ")
        var resolverRan = false
        manager.invalidNameResolver = { _ in
            resolverRan = true
            return .skip
        }

        let synced = await manager.syncFile(missingOnRight("Report "))

        #expect(synced)
        #expect(!resolverRan)
        #expect(fm.virtualDisk["/dropbox/Report "] != nil)
    }

    // MARK: - syncAll

    /// Sanitized or skipped, the invalid name is never written and the valid items still copy.
    @Test(arguments: [InvalidNameResolution.useSanitizedName, .skip])
    func testSyncAllHandlesTheInvalidNameAndCopiesTheRest(_ answer: InvalidNameResolution) async throws {
        let (manager, fm) = try makeManager()
        addFile(fm, "/icloud/Report ")
        addFile(fm, "/icloud/Other.txt")
        manager.invalidNameResolver = { _ in answer }

        await manager.syncAll(
            direction: .copyToRight,
            subset: [missingOnRight("Report "), missingOnRight("Other.txt")]
        )

        #expect((fm.virtualDisk["/dropbox/Report"] != nil) == (answer == .useSanitizedName))
        #expect(fm.virtualDisk["/dropbox/Report "] == nil)
        #expect(fm.virtualDisk["/dropbox/Other.txt"] != nil)
    }

    // MARK: - transferItems (pane copy / drop)

    /// Sanitized, the copy lands under the fixed name; skipped, nothing is transferred.
    @Test(arguments: [InvalidNameResolution.useSanitizedName, .skip])
    func testCopyItemsToPathSanitizesOrSkipsInvalidNames(_ answer: InvalidNameResolution) async throws {
        let (manager, fm) = try makeManager()
        addFile(fm, "/icloud/Report ")
        manager.invalidNameResolver = { _ in answer }
        let node = FileNode(id: "/icloud/Report ", name: "Report ", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], toPath: "/dropbox", fileManager: fm)

        let sanitized = answer == .useSanitizedName
        #expect(copied.count == (sanitized ? 1 : 0))
        #expect((fm.virtualDisk["/dropbox/Report"] != nil) == sanitized)
        #expect(fm.virtualDisk["/dropbox/Report "] == nil)
    }

    // MARK: - Invalid ancestor folders

    @Test func testInvalidAncestorFolderIsCaughtToo() async throws {
        // A left-only subtree under an invalid folder name: the copy would recreate the
        // invalid FOLDER on Dropbox even though the leaf name is fine.
        let (manager, fm) = try makeManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/icloud/Swimming "), withIntermediateDirectories: true)
        addFile(fm, "/icloud/Swimming /log.txt")
        var received: NameViolationPrompt?
        manager.invalidNameResolver = { prompt in
            received = prompt
            return .useSanitizedName
        }
        let diff = FileDifference(
            relativePath: "Swimming /log.txt",
            leftItemPath: "/icloud/Swimming /log.txt",
            rightItemPath: "/dropbox/Swimming /log.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right (Dropbox)"
        )

        let synced = await manager.syncFile(diff)

        #expect(synced)
        #expect(received?.itemName == "Swimming ")
        #expect(fm.virtualDisk["/dropbox/Swimming/log.txt"] != nil)
        #expect(fm.virtualDisk["/dropbox/Swimming /log.txt"] == nil)
    }
}
