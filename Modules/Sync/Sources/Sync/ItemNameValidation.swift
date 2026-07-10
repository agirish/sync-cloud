import Foundation

// MARK: - File/folder name validation (pure, shared by the engine and the UI prompts)

extension FileSyncManager {
    /// Checks whether `name` is usable as a single file or folder name.
    ///
    /// Returns a human-readable failure reason suitable for an alert, or `nil` when the
    /// name is acceptable. `renameItem`/`createFolder` append the name to a directory URL,
    /// so a "/" would silently address a different location and "." / ".." would traverse
    /// out of the visible folder (`FileManager.moveItem` resolves ".." in destinations).
    /// ":" is rejected to match Finder, which maps it to "/" per HFS+ semantics. A leading
    /// dot is fine — hidden files are legitimate names.
    public nonisolated static func validateItemName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "A name is required."
        }
        if trimmed == "." || trimmed == ".." {
            return "\"\(trimmed)\" can't be used as a name."
        }
        if trimmed.contains("/") {
            return "Names can't contain \"/\"."
        }
        if trimmed.contains(":") {
            return "Names can't contain \":\"."
        }
        if trimmed.contains("\0") {
            return "Names can't contain that character."
        }
        return nil
    }
}
