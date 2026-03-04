import Testing
import Foundation
@testable import Sync

@Suite struct SettingsManagerTests {
    
    @Test @MainActor func testAddAndRemoveProvidersPublishesState() async throws {
        let settings = SettingsManager()
        
        #expect(settings.providers.isEmpty)
        
        let newProvider = CloudProvider(id: UUID().uuidString, displayName: "iCloud Test", imageName: "icloud", path: "/test", type: .iCloud)
        settings.addProvider(newProvider)
        
        #expect(settings.providers.count == 1)
        #expect(settings.providers.first?.id == newProvider.id)
        
        settings.removeProvider(id: newProvider.id)
        
        #expect(settings.providers.isEmpty)
    }
}
