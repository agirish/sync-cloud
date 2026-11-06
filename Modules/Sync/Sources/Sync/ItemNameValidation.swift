import Foundation

// MARK: - File/folder name validation (pure, shared by the engine and the UI prompts)

extension FileSyncManager {
    /// Checks whether `name` is usable as a single file or folder name: a reason for an alert, or
    /// `nil` when acceptable. `renameItem` and `createFolder` append the name to a directory URL, so
    /// "/" would address another location and "." or ".." would leave the folder (`moveItem`
    /// resolves ".." in destinations). ":" is refused as in Finder, which maps it to "/". A leading
    /// dot is fine.
    public nonisolated static func validateItemName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "A name is required."
        }
        if trimmed == "." || trimmed == ".." {
            return "“\(trimmed)” can’t be used as a name."
        }
        if trimmed.contains("/") {
            return "Names can’t contain “/”."
        }
        if trimmed.contains(":") {
            return "Names can’t contain “:”."
        }
        if trimmed.contains("\0") {
            return "Names can’t contain that character."
        }
        // The disk's limit, counted as the disk counts it: 255 UTF-16 units of the decomposed form
        // a path sends (é is two). Otherwise a long name fails only at the write, as "invalid".
        if name.decomposedStringWithCanonicalMapping.utf16.count > 255 {
            return "Names can’t be longer than 255 characters."
        }
        return nil
    }
}
