import Events
import Foundation

public struct CloudProvider: Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let imageName: String
    public var path: String
    public let type: ProviderType
    public var size: String = "0 B"
    public var availableSpace: String = "0 B"
    public var usedSpace: String = "0 B"
    public var iconName: String
    
    public init(id: String, displayName: String, imageName: String, path: String, type: ProviderType) {
        self.id = id
        self.displayName = displayName
        self.imageName = imageName
        self.path = path
        self.type = type
        self.size = "0 B"
        self.availableSpace = "0 B"
        self.usedSpace = "0 B"
        self.iconName = imageName
    }

    public enum ProviderType: String {
        case iCloud = "iCloud"
        case oneDrive = "OneDrive"
        case dropBox = "Dropbox"
        case googleDrive = "Google Drive"
    }
}
