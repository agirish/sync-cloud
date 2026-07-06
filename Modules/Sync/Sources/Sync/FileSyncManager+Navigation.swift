import Events
import SwiftUI
import Foundation

extension FileSyncManager {
    
    // MARK: - Navigation Methods
    
    /// Sets the focused subfolder for one pane and appends to the back/forward history.
    /// - Parameters:
    ///   - relativePath: Subfolder path relative to the pane root (e.g. `"Documents/Projects"`).
    ///   - isLeft: `true` if the user drilled into this folder from the left pane; `false` for the right pane.
    public func focusOn(relativePath: String, isLeft: Bool) {
        ignoredPaths.removeAll()
        let newLeft = isLeft ? relativePath : self.leftRelativePath
        let newRight = !isLeft ? relativePath : self.rightRelativePath
        
        // Trim history if we're not at the end
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        
        history.append((newLeft, newRight))
        historyIndex = history.count - 1
        updateStateFromHistory()
    }
    
    /// Navigates to the previous state in the directory history stack.
    @MainActor public func goBack() {
        guard historyIndex > 0 else { return }
        ignoredPaths.removeAll()
        historyIndex -= 1
        let state = history[historyIndex]
        Logger.shared.info("User navigated back to \(state.left.isEmpty ? "root" : state.left)")
        updateStateFromHistory()
    }

    /// Navigates to the next state in the directory history stack.
    @MainActor public func goForward() {
        guard historyIndex < history.count - 1 else { return }
        ignoredPaths.removeAll()
        historyIndex += 1
        let state = history[historyIndex]
        Logger.shared.info("User navigated forward to \(state.left.isEmpty ? "root" : state.left)")
        updateStateFromHistory()
    }

    /// Resets both panes to root, clears selection, and resets back/forward history.
    @MainActor public func resetNavigation() {
        Logger.shared.info("User reset navigation to root.")
        ignoredPaths.removeAll()
        if !leftRelativePath.isEmpty { leftRelativePath = "" }
        if !rightRelativePath.isEmpty { rightRelativePath = "" }
        if !selectedLeftPaths.isEmpty { selectedLeftPaths = [] }
        if !selectedRightPaths.isEmpty { selectedRightPaths = [] }

        // Reset history to root only when it is not already exactly one root entry.
        if history.count != 1 || history[0].left != "" || history[0].right != "" {
            history = [("", "")]
        }
        if historyIndex != 0 { historyIndex = 0 }
        updateStateFromHistory()
    }
    
    func updateStateFromHistory() {
        let state = history[historyIndex]
        if leftRelativePath != state.left { leftRelativePath = state.left }
        if rightRelativePath != state.right { rightRelativePath = state.right }
        
        let nextCanGoBack = historyIndex > 0
        let nextCanGoForward = historyIndex < history.count - 1
        if canGoBack != nextCanGoBack { canGoBack = nextCanGoBack }
        if canGoForward != nextCanGoForward { canGoForward = nextCanGoForward }
        
        refreshSubject.send()
    }

}
