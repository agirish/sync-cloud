import Events
import SwiftUI
import Foundation

extension FileSyncManager {
    
    // MARK: - Navigation Methods
    
    /// Updates the navigation state to focus on a specific relative directory path.
    /// - Parameters:
    ///   - relativePath: The directory path to drill into.
    ///   - isSource: Whether this action originated from the source pane.
    public func focusOn(relativePath: String, isSource: Bool) {
        let newSource = isSource ? relativePath : self.sourceRelativePath
        let newDest = !isSource ? relativePath : self.destRelativePath
        
        // Trim history if we're not at the end
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        
        history.append((newSource, newDest))
        historyIndex = history.count - 1
        updateStateFromHistory()
    }
    
    /// Navigates to the previous state in the directory history stack.
    @MainActor public func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        let state = history[historyIndex]
        if sourceRelativePath != state.source { sourceRelativePath = state.source }
        if destRelativePath != state.dest { destRelativePath = state.dest }
        Logger.shared.info("User navigated back to \(state.source.isEmpty ? "root" : state.source)")
        updateHistoryState()
        refreshSubject.send()
    }
    
    /// Navigates to the next state in the directory history stack.
    @MainActor public func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        let state = history[historyIndex]
        if sourceRelativePath != state.source { sourceRelativePath = state.source }
        if destRelativePath != state.dest { destRelativePath = state.dest }
        Logger.shared.info("User navigated forward to \(state.source.isEmpty ? "root" : state.source)")
        updateHistoryState()
        refreshSubject.send()
    }
    
    /// Resets the navigation state back to the root level and clears UI interaction state.
    @MainActor public func resetNavigation() {
        Logger.shared.info("User reset navigation to root.")
        if !sourceRelativePath.isEmpty { sourceRelativePath = "" }
        if !destRelativePath.isEmpty { destRelativePath = "" }
        if !selectedSourcePaths.isEmpty { selectedSourcePaths = [] }
        if !selectedDestinationPaths.isEmpty { selectedDestinationPaths = [] }
        if !sourceExpandedPaths.isEmpty { sourceExpandedPaths = [] }
        if !destExpandedPaths.isEmpty { destExpandedPaths = [] }
        
        // Reset history to root only when it is not already exactly one root entry.
        if history.count != 1 || history[0].source != "" || history[0].dest != "" {
            history = [("", "")]
        }
        if historyIndex != 0 { historyIndex = 0 }
        updateStateFromHistory()
    }
    
    func updateStateFromHistory() {
        let state = history[historyIndex]
        if sourceRelativePath != state.source { sourceRelativePath = state.source }
        if destRelativePath != state.dest { destRelativePath = state.dest }
        
        let nextCanGoBack = historyIndex > 0
        let nextCanGoForward = historyIndex < history.count - 1
        if canGoBack != nextCanGoBack { canGoBack = nextCanGoBack }
        if canGoForward != nextCanGoForward { canGoForward = nextCanGoForward }
        
        refreshSubject.send()
    }

    // This function is introduced as part of the change to update the UI state
    // after navigation actions (goBack, goForward).
    func updateHistoryState() {
        let nextCanGoBack = historyIndex > 0
        let nextCanGoForward = historyIndex < history.count - 1
        if canGoBack != nextCanGoBack { canGoBack = nextCanGoBack }
        if canGoForward != nextCanGoForward { canGoForward = nextCanGoForward }
    }
    
}
