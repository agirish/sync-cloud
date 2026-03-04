import Testing
import Foundation
@testable import Sync

@Suite struct FileDiffEngineTests {
    
    @Test func testSameFilesNoDifferences() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let now = Date()
        let attributes: [FileAttributeKey: Any] = [
            .modificationDate: now,
            .size: 1024
        ]
        
        mockFM.virtualDisk["/src/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attributes, contents: nil)
        mockFM.virtualDisk["/dst/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attributes, contents: nil)
        
        let srcProvider = CloudProvider(id: UUID().uuidString, displayName: "Local Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: UUID().uuidString, displayName: "Local Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        
        let diffs = FileDiffEngine.computeDifferences(
            source: srcProvider, sourceURL: URL(fileURLWithPath: "/src"),
            destination: dstProvider, destinationURL: URL(fileURLWithPath: "/dst"),
            sourceFilesInfo: srcFiles, destinationFilesInfo: dstFiles
        )
        
        #expect(diffs.isEmpty)
    }
    
    @Test func testDateTolerance() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let now = Date()
        let almostNow = now.addingTimeInterval(0.5) // Less than 1 second diff
        let veryDifferent = now.addingTimeInterval(5.0) // More than 1 second diff
        
        let attrSrc: [FileAttributeKey: Any] = [.modificationDate: now, .size: 1024]
        let attrDstClose: [FileAttributeKey: Any] = [.modificationDate: almostNow, .size: 1024]
        let attrDstFar: [FileAttributeKey: Any] = [.modificationDate: veryDifferent, .size: 1024]
        
        mockFM.virtualDisk["/src/file1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrSrc, contents: nil)
        mockFM.virtualDisk["/dst/file1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrDstClose, contents: nil)
        
        mockFM.virtualDisk["/src/file2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrSrc, contents: nil)
        mockFM.virtualDisk["/dst/file2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrDstFar, contents: nil)
        
        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        
        let diffs = FileDiffEngine.computeDifferences(
            source: srcProvider, sourceURL: URL(fileURLWithPath: "/src"),
            destination: dstProvider, destinationURL: URL(fileURLWithPath: "/dst"),
            sourceFilesInfo: srcFiles, destinationFilesInfo: dstFiles
        )
        
        // Only file2.txt should have a difference because its date diff is > 1s
        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "file2.txt")
        #expect(diffs.first?.type == .differentDates)
    }
    
    @Test func testSizeDiscrepancy() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let now = Date()
        
        let attrSrc: [FileAttributeKey: Any] = [.modificationDate: now, .size: 1024]
        let attrDst: [FileAttributeKey: Any] = [.modificationDate: now, .size: 2048]
        
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: attrSrc, contents: nil)
        mockFM.virtualDisk["/dst/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: attrDst, contents: nil)
        
        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        
        let diffs = FileDiffEngine.computeDifferences(
            source: srcProvider, sourceURL: URL(fileURLWithPath: "/src"),
            destination: dstProvider, destinationURL: URL(fileURLWithPath: "/dst"),
            sourceFilesInfo: srcFiles, destinationFilesInfo: dstFiles
        )
        
        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "data.bin")
        #expect(diffs.first?.type == .differentDates) // Current engine labels size diffs under the "differentDates/size" generic catch-all
    }
    
    @Test func testEmptyDirectorySync() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        // Create an empty directory in source
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/empty_folder"), withIntermediateDirectories: true)
        
        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        
        // Verify the empty folder is found by scan
        #expect(srcFiles["empty_folder"] != nil)
        #expect(srcFiles["empty_folder"]?.isDirectory == true)
        
        let diffs = FileDiffEngine.computeDifferences(
            source: srcProvider, sourceURL: URL(fileURLWithPath: "/src"),
            destination: dstProvider, destinationURL: URL(fileURLWithPath: "/dst"),
            sourceFilesInfo: srcFiles, destinationFilesInfo: dstFiles
        )
        
        // Should find 1 difference (the missing directory)
        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "empty_folder")
        #expect(diffs.first?.action == .copyToDestination)
    }
}
