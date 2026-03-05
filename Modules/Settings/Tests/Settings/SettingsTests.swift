import Testing
@testable import Settings

@MainActor
@Test func testResetPathKeepsProviderDiscoverable() async throws {
    let settings = SettingsManager()
    settings.resetPath(for: "iCloud")
    
    try await Task.sleep(for: .milliseconds(100))
    #expect(settings.availableProviders.contains(where: { $0.id == "iCloud" }))
}
