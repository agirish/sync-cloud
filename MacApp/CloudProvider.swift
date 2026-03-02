import Foundation
import SwiftUI

struct CloudProvider: Identifiable, Hashable {
    let id: String
    let displayName: String
    let imageName: String
    var path: String
    let type: ProviderType
    
    enum ProviderType: String {
        case iCloud = "iCloud"
        case oneDrive = "OneDrive"
        case dropBox = "Dropbox"
        case googleDrive = "Google Drive"
    }
}

