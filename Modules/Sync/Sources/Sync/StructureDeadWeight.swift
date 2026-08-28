import Foundation

/// The crowding classification — dead weight by shape alone (ROADMAP_V5 §5.2).
///
/// Three classes, and only the empties carry an action, because only their rule survives contact
/// with this tree's history: a single-file leaf can be a destination waiting for its next file
/// (`Supporting Documents/Resume` was put back on 6 Aug after exactly that mistake), and hoisting
/// a pass-through folder renames every path beneath it for a defect that costs one click in a
/// column view. Say the number, offer the list, offer no button — except for the empties, which
/// get §5.5's removal sheet with the date-bucket / category split.
enum StructureDeadWeight {

    /// Path → class, for every folder that has one. Pure counting; the profile already carries
    /// both numbers.
    static func classify(_ profile: FolderProfile) -> [String: DeadWeightClass] {
        var out: [String: DeadWeightClass] = [:]
        out.reserveCapacity(profile.folders.count / 4)
        for (path, entry) in profile.folders {
            // The root describes the tree, not a folder in it.
            guard path != "." else { continue }
            switch (entry.fileCount, entry.subfolderCount) {
            case (0, 0): out[path] = .empty
            case (1, 0): out[path] = .singleFileLeaf
            case (0, 1): out[path] = .passThrough
            default: break
            }
        }
        return out
    }
}
