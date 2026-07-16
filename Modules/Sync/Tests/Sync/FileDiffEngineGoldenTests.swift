import Foundation
import Testing
@testable import Sync

/// Characterization ("golden") test for `FileDiffEngine.computeDifferences`. Pins the full diff of
/// one broad two-pane fixture as a single snapshot, so any change to which rows are produced, their
/// type, or their sync direction flips the snapshot and must be consciously re-blessed. Complements
/// the focused diff tests by catching COLLATERAL changes to the diff output.
@Suite struct FileDiffEngineGoldenTests {

    private let d1 = Date(timeIntervalSince1970: 1_600_000_000)
    private var d2: Date { d1.addingTimeInterval(10_000) }   // well beyond the 1s tolerance

    private func info(_ absPath: String, size: Int?, date: Date?, isDir: Bool = false) -> FileDiffEngine.FileInfo {
        FileDiffEngine.FileInfo(url: URL(fileURLWithPath: absPath), modificationDate: date, fileSize: size, isDirectory: isDir)
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

    private func snapshot(_ diffs: [FileDifference]) -> String {
        diffs.map { "\($0.relativePath) | \(typeLabel($0.type)) | \(actionLabel($0.action))" }
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
        ]
        let rightInfo: [String: FileDiffEngine.FileInfo] = [
            "onlyright.txt":      info("/right/onlyright.txt", size: 100, date: d1),
            "same.txt":           info("/right/same.txt", size: 100, date: d1),          // identical → no row
            "newerdate.txt":      info("/right/newerdate.txt", size: 100, date: d2),      // newer on right
            "diffsize.txt":       info("/right/diffsize.txt", size: 200, date: d1),       // bigger on right
            "note.txt ":          info("/right/note.txt ", size: 50, date: d1),           // trailing space → nameConflict
        ]

        let diffs = FileDiffEngine.computeDifferences(
            left: left, leftURL: URL(fileURLWithPath: "/left"),
            right: right, rightURL: URL(fileURLWithPath: "/right"),
            leftFilesInfo: leftInfo, rightFilesInfo: rightInfo
        )

        // GOLDEN — captured, hand-verified, pinned. Note: identical files (same.txt) produce no row;
        // onlyleftdir collapses its child; note.txt/"note.txt " surface as one nameConflict, not two
        // "missing" rows. Re-bless only after confirming an intentional change is correct.
        let expected = """
        diffsize.txt | differs | →R
        newerdate.txt | differs | ←L
        note.txt | nameConflict | →R
        onlyleft.txt | missingOnRight | →R
        onlyleftdir | missingOnRight | →R
        onlyright.txt | missingOnLeft | ←L
        """
        #expect(snapshot(diffs) == expected)
    }
}
