import Foundation

/// Namespace for the module's one cached file-size formatter, shared by the tree rows
/// (FileRowView) and the Differences table's Size column (DifferenceSizeCell).
enum FileSizeFormat {
    /// `ByteCountFormatter` carries internal state, so allocating one per row body would
    /// churn — rows render lazily but scroll fast.
    @MainActor static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
