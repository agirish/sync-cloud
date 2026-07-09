import Events
import Foundation

/// Back/forward stack for one pane's focused relative path. Each pane owns an independent
/// history, so the back button in a pane's header only undoes that pane's navigation.
public struct PaneNavigationHistory: Equatable {
    /// Visited relative paths, oldest first. Always contains at least the root entry `""`.
    public private(set) var entries: [String] = [""]
    /// Index of the current entry.
    public private(set) var index: Int = 0

    public init() {}

    public var current: String { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    /// Appends `path` as the new current entry, trimming any forward entries first.
    public mutating func push(_ path: String) {
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(path)
        index = entries.count - 1
    }

    /// Steps back one entry; no-op at the oldest entry.
    public mutating func goBack() {
        if canGoBack { index -= 1 }
    }

    /// Steps forward one entry; no-op at the newest entry.
    public mutating func goForward() {
        if canGoForward { index += 1 }
    }

    /// Back to the initial root-only state.
    public mutating func reset() {
        entries = [""]
        index = 0
    }
}

extension FileSyncManager {

    // MARK: - Navigation Methods

    /// Sets the focused subfolder for one pane and appends to that pane's history.
    /// - Parameters:
    ///   - relativePath: Subfolder path relative to the pane root (e.g. `"Documents/Projects"`).
    ///   - isLeft: `true` if the user drilled into this folder from the left pane; `false` for the right pane.
    public func focusOn(relativePath: String, isLeft: Bool) {
        ignoredPaths.removeAll()
        if isLeft {
            leftHistory.push(relativePath)
        } else {
            rightHistory.push(relativePath)
        }
        syncPathsFromHistory()
    }

    /// Sets the focused subfolder for both panes at once (⌥-click on a pane breadcrumb).
    /// Panes already focused on `relativePath` keep their history untouched, so Back in each
    /// pane still undoes exactly that pane's last move. No-op when both panes are already there.
    public func focusBoth(relativePath: String) {
        guard leftRelativePath != relativePath || rightRelativePath != relativePath else { return }
        ignoredPaths.removeAll()
        if leftRelativePath != relativePath { leftHistory.push(relativePath) }
        if rightRelativePath != relativePath { rightHistory.push(relativePath) }
        syncPathsFromHistory()
    }

    /// Navigates one pane to the previous entry in its own history stack.
    @MainActor public func goBack(isLeft: Bool) {
        if isLeft {
            guard leftHistory.canGoBack else { return }
            leftHistory.goBack()
        } else {
            guard rightHistory.canGoBack else { return }
            rightHistory.goBack()
        }
        ignoredPaths.removeAll()
        let pane = isLeft ? "left" : "right"
        let target = (isLeft ? leftHistory : rightHistory).current
        Logger.shared.info("User navigated \(pane) pane back to \(target.isEmpty ? "root" : target)")
        syncPathsFromHistory()
    }

    /// Navigates one pane to the next entry in its own history stack.
    @MainActor public func goForward(isLeft: Bool) {
        if isLeft {
            guard leftHistory.canGoForward else { return }
            leftHistory.goForward()
        } else {
            guard rightHistory.canGoForward else { return }
            rightHistory.goForward()
        }
        ignoredPaths.removeAll()
        let pane = isLeft ? "left" : "right"
        let target = (isLeft ? leftHistory : rightHistory).current
        Logger.shared.info("User navigated \(pane) pane forward to \(target.isEmpty ? "root" : target)")
        syncPathsFromHistory()
    }

    /// Resets both panes to root, clears selection, and resets both history stacks.
    @MainActor public func resetNavigation() {
        Logger.shared.info("User reset navigation to root.")
        ignoredPaths.removeAll()
        if !selectedLeftPaths.isEmpty { selectedLeftPaths = [] }
        if !selectedRightPaths.isEmpty { selectedRightPaths = [] }

        if leftHistory != PaneNavigationHistory() { leftHistory.reset() }
        if rightHistory != PaneNavigationHistory() { rightHistory.reset() }
        syncPathsFromHistory()
    }

    /// Swaps the left and right panes wholesale: focused relative paths, selections, and each
    /// pane's navigation history all move to the opposite side in one synchronous update, so
    /// observers never see a half-swapped intermediate (e.g. the new left path against the old
    /// left history). The provider ids live in @AppStorage (ContentView) and are swapped there
    /// in lockstep; this method owns only the manager's paired @Published state. It does not
    /// itself trigger a rescan — the caller drives the single post-swap refresh once the
    /// provider ids are swapped too.
    @MainActor public func swapPanes() {
        Logger.shared.info("User swapped the left and right panes")

        let relPath = leftRelativePath
        leftRelativePath = rightRelativePath
        rightRelativePath = relPath

        let selection = selectedLeftPaths
        selectedLeftPaths = selectedRightPaths
        selectedRightPaths = selection

        let history = leftHistory
        leftHistory = rightHistory
        rightHistory = history
    }

    /// Publishes each pane's current history entry into its relative path and triggers a refresh.
    func syncPathsFromHistory() {
        if leftRelativePath != leftHistory.current { leftRelativePath = leftHistory.current }
        if rightRelativePath != rightHistory.current { rightRelativePath = rightHistory.current }
        refreshSubject.send()
    }

}
