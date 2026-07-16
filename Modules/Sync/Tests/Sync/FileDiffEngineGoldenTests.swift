import Foundation
import Testing
@testable import Sync

/// Characterization ("golden") test for `FileDiffEngine.computeDifferences`. Pins the full diff of
/// one broad two-pane fixture as a single snapshot, so any change to which rows are produced, their
/// type, or their sync direction flips the snapshot and must be consciously re-blessed. Complements
/// the focused diff tests by catching COLLATERAL changes to the diff output.
///
/// The snapshot serializes EVERY row field a consumer depends on — relativePath, type, action,
/// BOTH item paths, both sizes, the enclosed count, and the description. The item paths are
/// load-bearing for the CLI: its `targetRelativePath` derives the name-rule-validated path from
/// the TARGET item path (5f76853), so a change to how `.nameConflict` rows carry the two sides'
/// real spellings silently re-breaks the trailing-space doppelganger sync.
@Suite struct FileDiffEngineGoldenTests {

    private let d1 = Date(timeIntervalSince1970: 1_600_000_000)
    private var d2: Date { d1.addingTimeInterval(10_000) }   // well beyond the 1s tolerance

    private func info(_ absPath: String, size: Int?, date: Date?, isDir: Bool = false,
                      unexplored: Bool = false) -> FileDiffEngine.FileInfo {
        FileDiffEngine.FileInfo(url: URL(fileURLWithPath: absPath), modificationDate: date, fileSize: size,
                                isDirectory: isDir, isUnexplored: unexplored)
    }

    private func typeLabel(_ t: FileDifference.DifferenceType) -> String {
        switch t {
        case .missingOnRight: return "missingOnRight"
        case .missingOnLeft: return "missingOnLeft"
        case .differentDates: return "differs"
        case .nameConflict: return "nameConflict"
        }
    }
    private func actionLabel(_ a: FileDifference.SyncAction) -> String {
        a == .copyToRight ? "→R" : "←L"
    }

    /// One line per row, every consumer-visible field pinned. `sz=l/r` uses `-` for nil;
    /// `encl=N` appears only when descendants collapsed into the row.
    private func snapshot(_ diffs: [FileDifference]) -> String {
        diffs.map { d in
            var line = "\(d.relativePath) | \(typeLabel(d.type)) | \(actionLabel(d.action))"
            line += " | L=\(d.leftItemPath) | R=\(d.rightItemPath)"
            line += " | sz=\(d.leftFileSize.map(String.init) ?? "-")/\(d.rightFileSize.map(String.init) ?? "-")"
            if let n = d.enclosedItemCount { line += " | encl=\(n)" }
            line += " | \(d.description)"
            return line
        }
        .sorted()
        .joined(separator: "\n")
    }

    @Test func diffSnapshotIsStable() {
        let left = CloudProvider(id: "L", displayName: "Left", imageName: "folder", path: "/left", type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "Right", imageName: "folder", path: "/right", type: .iCloud)

        let leftInfo: [String: FileDiffEngine.FileInfo] = [
            "onlyleft.txt":       info("/left/onlyleft.txt", size: 100, date: d1),
            "same.txt":           info("/left/same.txt", size: 100, date: d1),          // identical → no row
            "newerdate.txt":      info("/left/newerdate.txt", size: 100, date: d1),      // same size, diff date
            "diffsize.txt":       info("/left/diffsize.txt", size: 100, date: d1),       // diff size
            "onlyleftdir":        info("/left/onlyleftdir", size: nil, date: d1, isDir: true),
            "onlyleftdir/inner.txt": info("/left/onlyleftdir/inner.txt", size: 100, date: d1), // collapses into the dir row
            "note.txt":           info("/left/note.txt", size: 50, date: d1),            // near-name of "note.txt " on right
            // Date delta EXACTLY at the 1s tolerance → compares equal (no row); just past → row.
            "attolerance.txt":    info("/left/attolerance.txt", size: 100, date: d1),
            "pasttolerance.txt":  info("/left/pasttolerance.txt", size: 100, date: d1),
            // Type mismatch, equal dates: a DIRECTORY on the left vs a file on the right — the
            // folder side wins the default. Its child collapses into the mismatch row (either
            // resolution handles the subtree in one action).
            "mixdir":             info("/left/mixdir", size: nil, date: d1, isDir: true),
            "mixdir/child.txt":   info("/left/mixdir/child.txt", size: 100, date: d1),
            // Type mismatch where the RIGHT side (a file) is newer beyond tolerance → date wins.
            "mixnewer":           info("/left/mixnewer", size: nil, date: d1, isDir: true),
            // Present on both sides, but the RIGHT copy could not be LISTED (permission denied):
            // this file's absence over there is unknowable, so NO row may appear for it.
            "lockeddir":          info("/left/lockeddir", size: nil, date: d1, isDir: true),
            "lockeddir/inside.txt": info("/left/lockeddir/inside.txt", size: 100, date: d1),
        ]
        let rightInfo: [String: FileDiffEngine.FileInfo] = [
            "onlyright.txt":      info("/right/onlyright.txt", size: 100, date: d1),
            "same.txt":           info("/right/same.txt", size: 100, date: d1),          // identical → no row
            "newerdate.txt":      info("/right/newerdate.txt", size: 100, date: d2),      // newer on right
            "diffsize.txt":       info("/right/diffsize.txt", size: 200, date: d1),       // bigger on right
            "note.txt ":          info("/right/note.txt ", size: 50, date: d1),           // trailing space → nameConflict
            "attolerance.txt":    info("/right/attolerance.txt", size: 100, date: d1.addingTimeInterval(1)),
            "pasttolerance.txt":  info("/right/pasttolerance.txt", size: 100, date: d1.addingTimeInterval(2)),
            "mixdir":             info("/right/mixdir", size: 60, date: d1),
            "mixnewer":           info("/right/mixnewer", size: 60, date: d2),
            "lockeddir":          info("/right/lockeddir", size: nil, date: d1, isDir: true, unexplored: true),
        ]

        let diffs = FileDiffEngine.computeDifferences(
            left: left, leftURL: URL(fileURLWithPath: "/left"),
            right: right, rightURL: URL(fileURLWithPath: "/right"),
            leftFilesInfo: leftInfo, rightFilesInfo: rightInfo
        )

        // GOLDEN — captured, hand-verified, pinned. Load-bearing details:
        //  · identical files (same.txt) produce no row; onlyleftdir collapses its child (encl=1);
        //  · note.txt/"note.txt " surface as ONE nameConflict, not two "missing" rows, and its
        //    L/R item paths carry each side's REAL spelling (the CLI validates the TARGET's);
        //  · attolerance.txt (delta exactly 1s = the tolerance) produces NO row — the comparison
        //    is `> tolerance`, not `>=`; pasttolerance.txt (2s) does;
        //  · mixdir (dir vs file, dates equal) defaults to the folder side (→R) and collapses the
        //    dir side's child into the row (encl=1); mixnewer (right file newer past tolerance)
        //    goes ←L — the date outranks the folder default. Both surface as `differs` rows;
        //  · lockeddir (unlistable on the right, `isUnexplored`) contributes NO rows at all — not
        //    for itself and not for lockeddir/inside.txt, whose absence on the right is unknowable
        //    (a phantom Missing row would offer to copy into a folder nobody can read).
        // Re-bless only after confirming an intentional change is correct.
        let expected = """
        diffsize.txt | differs | →R | L=/left/diffsize.txt | R=/right/diffsize.txt | sz=100/200 | Sizes differ
        mixdir | differs | →R | L=/left/mixdir | R=/right/mixdir | sz=-/60 | encl=1 | Type mismatch; defaulting to the folder from Left
        mixnewer | differs | ←L | L=/left/mixnewer | R=/right/mixnewer | sz=-/60 | Right item is newer (type mismatch)
        newerdate.txt | differs | ←L | L=/left/newerdate.txt | R=/right/newerdate.txt | sz=100/100 | Right file is newer
        note.txt | nameConflict | →R | L=/left/note.txt | R=/right/note.txt  | sz=50/50 | Names differ by a trailing space: "note.txt" (Left) vs "note.txt " (Right)
        onlyleft.txt | missingOnRight | →R | L=/left/onlyleft.txt | R=/right/onlyleft.txt | sz=100/- | Missing on right (Right)
        onlyleftdir | missingOnRight | →R | L=/left/onlyleftdir | R=/right/onlyleftdir | sz=-/- | encl=1 | Folder missing on right (Right)
        onlyright.txt | missingOnLeft | ←L | L=/left/onlyright.txt | R=/right/onlyright.txt | sz=-/100 | Missing on left (Left)
        pasttolerance.txt | differs | ←L | L=/left/pasttolerance.txt | R=/right/pasttolerance.txt | sz=100/100 | Right file is newer
        """
        #expect(snapshot(diffs) == expected)
    }

    /// Second fixture run with `caseInsensitive: true` — pins the case-variant pairing paths the
    /// flag switches on: case-variant leaves compare as ONE row (never two phantom "missing"
    /// rows), identical children under case-variant FOLDERS produce no rows at all, and exact
    /// matches still own their keys ahead of any variant.
    @Test func caseInsensitiveDiffSnapshotIsStable() {
        let left = CloudProvider(id: "L", displayName: "Left", imageName: "folder", path: "/left", type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "Right", imageName: "folder", path: "/right", type: .iCloud)

        let leftInfo: [String: FileDiffEngine.FileInfo] = [
            // Leaf case variant, same size+date → one "names differ only by case" row.
            "Readme.md":      info("/left/Readme.md", size: 100, date: d1),
            // Leaf case variant where the right is newer past tolerance → ←L with the case note.
            "Notes.txt":      info("/left/Notes.txt", size: 100, date: d1),
            // Ancestor-only case difference: identical children under case-variant folders
            // must produce NO rows (the difference is the folder's, not every descendant's).
            "Docs":           info("/left/Docs", size: nil, date: d1, isDir: true),
            "Docs/a.txt":     info("/left/Docs/a.txt", size: 100, date: d1),
            // Exact-case identical pair → no row (control).
            "same.txt":       info("/left/same.txt", size: 100, date: d1),
            // Genuinely one-sided items keep their plain missing rows.
            "onlyleft.txt":   info("/left/onlyleft.txt", size: 100, date: d1),
        ]
        let rightInfo: [String: FileDiffEngine.FileInfo] = [
            "readme.md":      info("/right/readme.md", size: 100, date: d1),
            "notes.TXT":      info("/right/notes.TXT", size: 100, date: d2),
            "docs":           info("/right/docs", size: nil, date: d1, isDir: true),
            "docs/a.txt":     info("/right/docs/a.txt", size: 100, date: d1),
            "same.txt":       info("/right/same.txt", size: 100, date: d1),
            "onlyright.txt":  info("/right/onlyright.txt", size: 100, date: d1),
        ]

        let diffs = FileDiffEngine.computeDifferences(
            left: left, leftURL: URL(fileURLWithPath: "/left"),
            right: right, rightURL: URL(fileURLWithPath: "/right"),
            leftFilesInfo: leftInfo, rightFilesInfo: rightInfo,
            caseInsensitive: true
        )

        // GOLDEN — captured, hand-verified, pinned. Notably ABSENT: any row for Docs/docs or
        // their identical children, and any missing-row double for the case-variant leaves.
        let expected = """
        Notes.txt | differs | ←L | L=/left/Notes.txt | R=/right/notes.TXT | sz=100/100 | Right file is newer (names differ only by case)
        Readme.md | differs | →R | L=/left/Readme.md | R=/right/readme.md | sz=100/100 | Names differ only by case
        onlyleft.txt | missingOnRight | →R | L=/left/onlyleft.txt | R=/right/onlyleft.txt | sz=100/- | Missing on right (Right)
        onlyright.txt | missingOnLeft | ←L | L=/left/onlyright.txt | R=/right/onlyright.txt | sz=-/100 | Missing on left (Left)
        """
        #expect(snapshot(diffs) == expected)
    }
}
