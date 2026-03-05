import Testing
import Foundation
@testable import Settings
@testable import Sync

@Suite struct SettingsManagerTests {
    
    @Test @MainActor func testDefaultICloudProvider() async throws {
        let settings = SettingsManager()
        
        // SettingsManager starts with 1 default iCloud provider
        #expect(settings.availableProviders.count >= 1)
        #expect(settings.availableProviders.first?.id == "iCloud")
    }
    
    @Test @MainActor func testPathOverrides() async throws {
        let settings = SettingsManager()
        let testPath = "/tmp/test_override"
        
        settings.setPath(testPath, for: "iCloud")
        
        // Wait for discovery task
        try await Task.sleep(for: .milliseconds(100))
        
        #expect(settings.path(for: "iCloud") == testPath)
        
        settings.resetPath(for: "iCloud")
        try await Task.sleep(for: .milliseconds(100))
        
        #expect(settings.path(for: "iCloud") != testPath)
    }
    
    @Test @MainActor func testPathForMissingProvider() async throws {
        let settings = SettingsManager()
        #expect(settings.path(for: "NonExistent") == "")
    }
}
