//
//  FileManaging.swift
//  SyncCloud
//

import AppKit
import Foundation

/// A protocol declaring the `FileManager` primitives required by the Sync engine,
/// enabling fully decoupled RAM-based Unit Testing without mutating the physical disk.
public protocol FileManaging: Sendable {
    func fileExists(atPath path: String) -> Bool
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey : Any]
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws
    func removeItem(at URL: URL) throws
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator?
}

// Swift Protocols don't allow default implementations directly in the requirement, 
// so we provide an extension to fulfill the exact `FileManager` call-stubs.
extension FileManaging {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: nil)
    }
    
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) -> FileManager.DirectoryEnumerator? {
        return enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: nil)
    }
}

// Ensure the real macOS FileManager strictly conforms to this interface.
extension FileManager: FileManaging {}
