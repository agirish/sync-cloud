import Events
import Foundation

public struct CloudProvider: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let imageName: String
    public var path: String
    public let type: ProviderType

    public init(id: String, displayName: String, imageName: String, path: String, type: ProviderType) {
        self.id = id
        self.displayName = displayName
        self.imageName = imageName
        self.path = path
        self.type = type
    }

    public enum ProviderType: String, Sendable {
        case iCloud = "iCloud"
        case oneDrive = "OneDrive"
        case dropBox = "Dropbox"
        case googleDrive = "Google Drive"
    }
}
