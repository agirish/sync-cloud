import AppKit
import Foundation
@testable import Sync

/// A RAM-only filesystem simulator built for Unit Tests.
/// It intercepts `FileManaging` protocol endpoints to emulate standard volume constraints,
/// read/write states, and failure behaviors without interacting with the physical local disk.
public final class MockFileManager: FileManaging, @unchecked Sendable {
    
    public struct FileStub {
        var isDirectory: Bool
        let attributes: [FileAttributeKey: Any]?
        var contents: [String]? // Child names if directory
    }
    
    // The dictionary-backed RAM virtual disk
    public var virtualDisk: [String: FileStub] = [:]
    
    public init() {}
    
    public func fileExists(atPath path: String) -> Bool {
        return virtualDisk.keys.contains(path)
    }
    
    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        if let stub = virtualDisk[path] {
            isDirectory?.pointee = ObjCBool(stub.isDirectory)
            return true
        }
        return false
    }
    
    public func attributesOfItem(atPath path: String) throws -> [FileAttributeKey : Any] {
        guard let stub = virtualDisk[path] else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        }
        var attrs = stub.attributes ?? [:]
        attrs[.type] = stub.isDirectory ? FileAttributeType.typeDirectory : FileAttributeType.typeRegular
        return attrs
    }
    
    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws {
        let path = url.path
        if let existing = virtualDisk[path] {
            if createIntermediates && existing.isDirectory {
                return // Native FileManager doesn't throw if the dir already exists and createIntermediates is true
            }
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        }
        
        // In a true mock, we'd traverse and split intermediate structures,
        // but for generic target testing, we stub it barebones.
        virtualDisk[path] = FileStub(isDirectory: true, attributes: attributes, contents: [])
    }
    
    public var calledCopyItem: Bool = false
    
    public func copyItem(at srcURL: URL, to dstURL: URL) throws {
        calledCopyItem = true
        let src = srcURL.path
        let dst = dstURL.path
        
        guard let sourceData = virtualDisk[src] else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        }
        
        if virtualDisk[dst] != nil {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        }
        
        virtualDisk[dst] = sourceData
        
        // Deep copy simulated contents
        if sourceData.isDirectory, let children = sourceData.contents {
            for child in children {
                try? copyItem(at: srcURL.appendingPathComponent(child), to: dstURL.appendingPathComponent(child))
            }
        }
    }
    
    public var shouldFailMove: Bool = false
    
    public func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if shouldFailMove {
            shouldFailMove = false
            // Emulate Cross-Device Link failure (EXDEV)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV), userInfo: nil)
        }
        
        // Simple mock of move (copy + delete)
        try copyItem(at: srcURL, to: dstURL)
        try removeItem(at: srcURL)
    }
    
    public var shouldFailTrash: Bool = false
    public var trashedPaths: [String] = []
    
    public func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        if shouldFailTrash {
            // Simulate network drive without trash bin
            throw NSError(domain: POSIXError.errorDomain, code: Int(POSIXError.ENOTSUP.rawValue))
        }
        
        let path = url.path
        guard virtualDisk[path] != nil else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        }
        
        // Emulate moving to ~/.Trash
        let trashedTarget = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(url.lastPathComponent)
        
        try moveItem(at: url, to: trashedTarget)
        trashedPaths.append(trashedTarget.path)
        
        outResultingURL?.pointee = trashedTarget as NSURL
    }
    
    public func removeItem(at URL: URL) throws {
        let path = URL.path
        guard let sourceData = virtualDisk[path] else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        }
        
        virtualDisk.removeValue(forKey: path)
        
        // Deep remove
        if sourceData.isDirectory, let children = sourceData.contents {
            for child in children {
                try? removeItem(at: URL.appendingPathComponent(child))
            }
        }
    }
    
    public func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        
        // Build flat array of child URLs
        var allChildren: [URL] = []
        let root = url.path
        
        for (key, _) in virtualDisk {
            if key.hasPrefix(root) && key != root {
                let url = URL(fileURLWithPath: key)
                if mask.contains(.skipsHiddenFiles) && url.lastPathComponent.hasPrefix(".") {
                    continue
                }
                allChildren.append(url)
            }
        }
        
        // Return a mock MockDirectoryEnumerator 
        return MockEnumerator(urls: allChildren)
    }
}

public class MockEnumerator: FileManager.DirectoryEnumerator {
    private var urls: [URL]
    private var index = 0
    
    init(urls: [URL]) {
        self.urls = urls
    }
    
    public override func nextObject() -> Any? {
        if index < urls.count {
            let item = urls[index]
            index += 1
            return item
        }
        return nil
    }
}
