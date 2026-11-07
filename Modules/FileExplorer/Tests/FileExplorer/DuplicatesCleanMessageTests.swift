import Testing
@testable import FileExplorer

/// The Duplicates clean state claims exactly what the scan covered, never wider: "Nothing repeats
/// across iCloud" after a one-folder scan would vouch for places it never visited. The subject is
/// the scanned root when known, as in the named-reveal states that use `duplicateScanRoot`.
@Suite struct DuplicatesCleanMessageTests {

    @Test func aScannedFolderIsTheSubject() {
        // A scoped scan of TODO, clean: the claim names TODO, not the provider.
        let message = LensWorkspaceView.duplicatesCleanMessage(scanRootName: "TODO", providerName: "iCloud")
        #expect(message.contains("in “TODO”"))
        #expect(!message.contains("iCloud"))
    }

    @Test func noKnownRootFallsBackToTheProvider() {
        // With no completed scan root recorded there is no narrower true claim available.
        let message = LensWorkspaceView.duplicatesCleanMessage(scanRootName: nil, providerName: "iCloud")
        #expect(message.contains("across iCloud"))
    }

    @Test func noRootAndNoProviderStillReadsAsASentence() {
        let message = LensWorkspaceView.duplicatesCleanMessage(scanRootName: nil, providerName: nil)
        #expect(message.contains("across this provider"))
    }
}
