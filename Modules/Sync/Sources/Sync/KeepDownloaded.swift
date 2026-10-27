import Foundation

/// Finder's **Keep Downloaded**: a pin that makes the provider fetch an item — a folder's whole tree
/// — and keep it on this Mac.
///
/// **The pin is an extended attribute, and it is the one Finder writes.** Measured 2026-10-27 on
/// macOS 27: Finder's pinned folders (`~/Documents`, `~/Desktop`) carry
/// `com.apple.fileprovider.pinned#PX` = `"1"`, and writing that attribute on a cloud-only iCloud
/// folder downloaded every file in it, two levels deep, within 15 s; removing it leaves the files
/// where they are. The `#PX` suffix is part of the name — `xattr_name_with_flags` flags, P never
/// preserved and X never exported — so a pin belongs to this Mac and is not copied or synced.
///
/// **iCloud Drive only, because it is the only provider measured to honour it.** The same attribute
/// on a cloud-only Google Drive file left it cloud-only for 24 s, and on OneDrive for 60 s, while a
/// plain download of each landed at once. Dropbox could not be staged (it refused to evict a file).
/// Offering the item there would be a promise nothing keeps.
///
/// **A pin does not stop an explicit eviction**: `evictUbiquitousItem` on a pinned file succeeded
/// and it stayed cloud-only for 40 s. What it stops, per `NSFileProviderContentPolicy`'s
/// "keep downloaded" policy, is the system's own eviction — low disk, Optimize Mac Storage — which
/// cannot be staged here.
public enum KeepDownloaded {
    /// The attribute Finder's Keep Downloaded writes, flags suffix and all.
    public static let attributeName = "com.apple.fileprovider.pinned#PX"
    /// Names the File Provider domain at a domain's root — iCloud's on `~/Desktop` and `~/Documents`
    /// when Desktop & Documents sync is on.
    static let domainAttributeName = "com.apple.file-provider-domain-id"
    static let iCloudDomainPrefix = "com.apple.CloudDocs."

    /// The File Provider domain a folder roots, read from its attribute. Only ever READ: writing
    /// that attribute is refused to a process without the right privacy grant — the CI runner, a
    /// launchd service, was refused while a Terminal shell was not — so a test hands in its own
    /// answer here rather than staging the attribute.
    public typealias DomainOf = @Sendable (String) -> String?
    public static let realDomainOf: DomainOf = { attribute(domainAttributeName, atPath: $0) }

    public enum State: Equatable, Sendable {
        /// Not in iCloud Drive, so no pin is offered.
        case unavailable
        case off
        /// Pinned itself.
        case on
        /// Not pinned itself, but a folder above it is — so it is kept regardless, and turning it
        /// off here would change nothing.
        case inherited(fromFolder: String)
    }

    /// Whether the item at `path` is kept downloaded.
    ///
    /// Asked by a row's context menu, which is built every time the row renders, so it is cheap: a
    /// path outside iCloud costs string comparisons (and, under `~/Desktop` or `~/Documents`, one
    /// `getxattr` on that folder); one inside costs an `lstat` and a `getxattr` per folder between
    /// it and the iCloud root. A link in iCloud is asked about as the file it points to, which is
    /// the file the pin would fetch; a link elsewhere is not offered, wherever it points.
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
            // The container is the first component below; `Mobile Documents` itself is not iCloud
            // Drive, it is the folder that holds every app's container.
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
