import Testing
import Sync
@testable import FileExplorer

@Suite struct FileExplorerTests {
    
    @MainActor
    @Test func testResolvedSelectionUsesContextNodeWhenNothingSelected() async throws {
        let nodeA = FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)
        let nodeB = FileNode(id: "/src/b.txt", name: "b.txt", isDirectory: false)
        let tree = [nodeA, nodeB]
        
        let resolved = FileContextMenu.resolvedSelection(node: nodeB, selection: [], tree: tree)
        
        #expect(resolved.count == 1)
        #expect(resolved.first?.id == nodeB.id)
    }
    
    @MainActor
    @Test func testResolvedSelectionUsesCurrentSelectionWhenNodeIncluded() async throws {
        let nodeA = FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)
        let nodeB = FileNode(id: "/src/b.txt", name: "b.txt", isDirectory: false)
        let tree = [nodeA, nodeB]
        let selection: Set<String> = [nodeA.id, nodeB.id]
        
        let resolved = FileContextMenu.resolvedSelection(node: nodeA, selection: selection, tree: tree)
        
        #expect(resolved.count == 2)
        #expect(Set(resolved.map(\.id)) == selection)
    }
    
    @MainActor
    @Test func testResolvedSelectionFallsBackToContextNodeWhenNodeNotInSelection() async throws {
        let nodeA = FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)
        let nodeB = FileNode(id: "/src/b.txt", name: "b.txt", isDirectory: false)
        let nodeC = FileNode(id: "/src/c.txt", name: "c.txt", isDirectory: false)
        let tree = [nodeA, nodeB, nodeC]
        let selection: Set<String> = [nodeA.id]
        
        let resolved = FileContextMenu.resolvedSelection(node: nodeC, selection: selection, tree: tree)
        
        #expect(resolved.count == 1)
        #expect(resolved.first?.id == nodeC.id)
    }
}
