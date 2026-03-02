import Foundation
import SwiftUI

/// Represents a cloud storage provider (e.g., iCloud, OneDrive) configured within the application.
struct CloudProvider: Identifiable, Hashable {
    /// A unique identifier for the provider.
    let id: String
    /// The user-facing display name for the provider.
    let displayName: String
    /// The SF Symbol icon name used to represent the provider in the UI.
    let imageName: String
    /// The absolute file system path mapping to the provider's root directory.
    var path: String
    /// The specific service platform type of the provider.
    let type: ProviderType
    
    /// Defines the supported cloud storage platforms.
    enum ProviderType: String {
        case iCloud = "iCloud"
        case oneDrive = "OneDrive"
        case dropBox = "Dropbox"
        case googleDrive = "Google Drive"
    }
}

