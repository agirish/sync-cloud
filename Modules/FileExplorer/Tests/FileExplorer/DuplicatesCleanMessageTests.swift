import Testing
@testable import FileExplorer

/// The Duplicates clean state must claim exactly what the scan covered — never wider.
/// It used to read "Nothing repeats across iCloud" under a one-folder scope: a clean claim
/// about territory the scan never visited. The subject is the scanned root when one is known,
/// following the named-reveal states that already phrase themselves via `duplicateScanRoot`.
@Suite struct DuplicatesCleanMessageTests {

    @Test func aScannedFolderIsTheSubject() {
        // The defect case: scoped scan of TODO, clean result. The claim must name TODO —
        // and must NOT reach for the provider.
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
