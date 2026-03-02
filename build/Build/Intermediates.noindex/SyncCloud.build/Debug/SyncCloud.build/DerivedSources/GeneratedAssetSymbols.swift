import Foundation
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "dropbox" asset catalog image resource.
    static let dropbox = DeveloperToolsSupport.ImageResource(name: "dropbox", bundle: resourceBundle)

    /// The "googledrive" asset catalog image resource.
    static let googledrive = DeveloperToolsSupport.ImageResource(name: "googledrive", bundle: resourceBundle)

    /// The "icloud" asset catalog image resource.
    static let icloud = DeveloperToolsSupport.ImageResource(name: "icloud", bundle: resourceBundle)

    /// The "onedrive" asset catalog image resource.
    static let onedrive = DeveloperToolsSupport.ImageResource(name: "onedrive", bundle: resourceBundle)

}

