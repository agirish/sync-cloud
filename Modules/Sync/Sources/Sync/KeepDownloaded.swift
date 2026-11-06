import Foundation

/// Finder's Keep Downloaded: a pin that makes the provider fetch an item (a folder's whole tree) and
/// keep it on this Mac.
///
/// The pin is the extended attribute Finder writes, `com.apple.fileprovider.pinned#PX` = `"1"`.
/// Setting it on a cloud-only iCloud folder downloads everything in it; removing it leaves the files
/// where they are. The `#PX` suffix is part of the name (`xattr_name_with_flags`: never preserved,
/// never exported), so a pin belongs to this Mac and is not copied or synced.
///
/// iCloud Drive only: Google Drive and OneDrive ignored the attribute, and Dropbox couldn't be
/// tested, so offering it there would be a promise nothing keeps. A pin doesn't stop an explicit
/// `evictUbiquitousItem`; it stops the system's own eviction (low disk, Optimize Mac Storage).
public enum KeepDownloaded {
    /// The attribute Finder's Keep Downloaded writes, flags suffix and all.
    public static let attributeName = "com.apple.fileprovider.pinned#PX"
    /// Names the File Provider domain at a domain's root — iCloud's on `~/Desktop` and `~/Documents`
    /// when Desktop & Documents sync is on.
    static let domainAttributeName = "com.apple.file-provider-domain-id"
    static let iCloudDomainPrefix = "com.apple.CloudDocs."

    /// The File Provider domain a folder roots, read from its attribute. Only ever read: writing it
    /// needs a privacy grant the CI runner lacks, so a test hands in its own answer here.
    public typealias DomainOf = @Sendable (String) -> String?
    public static let realDomainOf: DomainOf = { attribute(domainAttributeName, atPath: $0) }

    public enum State: Equatable, Sendable {
        /// Not in iCloud Drive, so no pin is offered.
        case unavailable
        case off
        /// Pinned itself.
        case on
        /// Not pinned itself, but a folder above it is, so turning it off here would change nothing.
        case inherited(fromFolder: String)
    }

    /// Whether the item at `path` is kept downloaded. A right-click waits on this while the context
    /// menu is built, so it stays cheap: string compares outside iCloud, and inside an `lstat` plus
    /// one `getxattr` per folder up to the iCloud root. A link in iCloud is asked about as its
    /// target, the file the pin would fetch; a link elsewhere is not offered.
    public static func state(ofPath path: String, home: String = NSHomeDirectory(),
                             domainOf: DomainOf = realDomainOf) -> State {
        guard iCloudRoot(containing: path, home: home, domainOf: domainOf) != nil else { return .unavailable }
        let path = MaterializationStatus.linkTarget(of: path)
        guard let root = iCloudRoot(containing: path, home: home, domainOf: domainOf) else { return .unavailable }
        if hasAttribute(attributeName, atPath: path) { return .on }
        var folder = path
        while folder.count > root.count {
            folder = (folder as NSString).deletingLastPathComponent
            if hasAttribute(attributeName, atPath: folder) { return .inherited(fromFolder: folder) }
        }
        return .off
    }

    /// Pins or unpins the item at `path`. Pinning starts the provider's download by itself; a
    /// caller that wants the row's badge to follow requests the download too.
    public static func set(_ kept: Bool, atPath path: String) throws {
        let path = MaterializationStatus.linkTarget(of: path)
        let status: Int32 = kept
            ? setxattr(path, attributeName, "1", 1, 0, XATTR_NOFOLLOW)
            : removexattr(path, attributeName, XATTR_NOFOLLOW)
        // Unpinning an item that was never pinned is already done.
        if status != 0, !(kept == false && errno == ENOATTR) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
    }

    /// The iCloud folder `path` is in — a container under `~/Library/Mobile Documents`, or
    /// `~/Desktop` / `~/Documents` when their domain is iCloud's — or nil when it is in none.
    static func iCloudRoot(containing path: String, home: String,
                           domainOf: DomainOf = realDomainOf) -> String? {
        let mobileDocuments = home + "/Library/Mobile Documents"
        if let rest = descendant(path, of: mobileDocuments) {
            // The container is the first component below; `Mobile Documents` itself only holds
            // every app's container.
            guard let container = rest.split(separator: "/").first else { return nil }
            return mobileDocuments + "/" + container
        }
        for name in ["Desktop", "Documents"] {
            let root = home + "/" + name
            if descendant(path, of: root) != nil || path.caseInsensitiveCompare(root) == .orderedSame,
               domainOf(root)?.hasPrefix(iCloudDomainPrefix) == true {
                return root
            }
        }
        return nil
    }

    /// What follows `folder + "/"` in `path`, compared without case as APFS compares names, or nil
    /// when `path` is not below `folder`.
    static func descendant(_ path: String, of folder: String) -> Substring? {
        let prefix = folder + "/"
        guard path.count > prefix.count,
              path.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else { return nil }
        return path.dropFirst(prefix.count)
    }

    static func hasAttribute(_ name: String, atPath path: String) -> Bool {
        getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    static func attribute(_ name: String, atPath path: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
