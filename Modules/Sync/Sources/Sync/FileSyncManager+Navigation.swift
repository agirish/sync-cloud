import Events
import SwiftUI
import Foundation

extension FileSyncManager {
    
    // MARK: - Navigation Methods
    
    /// Updates the navigation state to focus on a specific relative directory path.
    /// - Parameters:
    ///   - relativePath: The directory path to drill into.
    ///   - isSource: Whether this action originated from the source pane.
    ///   - otherProviderPath: The root path of the opposite provider to attempt matching navigation.
    public func focusOn(relativePath: String, isSource: Bool, otherProviderPath: String) {
        let newSource = isSource ? relativePath : findMatchingPath(relativePath, in: otherProviderPath)
        let newDest = !isSource ? relativePath : findMatchingPath(relativePath, in: otherProviderPath)
        
        // Trim history if we're not at the end
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        
        history.append((newSource, newDest))
        historyIndex = history.count - 1
        updateStateFromHistory()
    }
    
    /// Navigates to the previous state in the directory history stack.
    public func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        updateStateFromHistory()
    }
    
    /// Navigates to the next state in the directory history stack.
    public func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        updateStateFromHistory()
    }
    
    /// Resets the navigation state back to the root level.
    public func resetNavigation() {
        focusOn(relativePath: "", isSource: true, otherProviderPath: "")
    }
    
    func updateStateFromHistory() {
        let state = history[historyIndex]
        sourceRelativePath = state.source
        destRelativePath = state.dest
        canGoBack = historyIndex > 0
        canGoForward = historyIndex < history.count - 1
    }
    
    func findMatchingPath(_ relativePath: String, in rootPath: String) -> String {
        if relativePath.isEmpty { return "" }
        let fullPath = (rootPath as NSString).expandingTildeInPath + "/" + relativePath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
            return relativePath
        }
        // If exact match not found, don't reset to root if we were already elsewhere
        return relativePath
    }
}
