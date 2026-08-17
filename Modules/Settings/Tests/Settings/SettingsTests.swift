import Testing
@testable import Settings

@MainActor
@Test func testResetPathKeepsProviderDiscoverable() async throws {
    let test = TestDefaults()
    defer { test.wipe() }
    let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })

    settings.resetPath(for: "iCloud")
    await settings.discoverProviders()
    #expect(settings.availableProviders.contains(where: { $0.id == "iCloud" }))
}
