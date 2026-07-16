import Foundation
import Testing
@testable import Sync

/// Characterization ("golden") test for `FilingEngine.suggest`. Pins the classification of a broad
/// set of loose files against one taxonomy as a single snapshot — destination, confidence, and
/// batch-eligibility per file — so a change to the filing heuristic (a token rule, the year handling,
/// the confidence/batch gate) flips the snapshot and must be consciously re-blessed. Guards the class
/// of regression the year-misfile fix addressed: a file becoming (or ceasing to be) batch-eligible.
@Suite struct FilingEngineGoldenTests {

    // Mid-2024 so the derived year is 2024 in every timezone.
    private let y2024 = Date(timeIntervalSince1970: 1_720_000_000)

    private func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                 modificationDate: y2024, fileSize: 8192)
    }
    private func dir(_ path: String, _ children: [FileNode] = []) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
    }

    private func confLabel(_ c: FilingConfidence) -> String {
        switch c {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        }
    }

    private func line(_ s: FilingSuggestion) -> String {
        guard let b = s.best else { return "\(s.fileName) -> (no confident home)" }
        var flags = [confLabel(b.confidence)]
        if b.fromAI { flags.append("ai") }
        if b.fromContent { flags.append("content") }
        if s.isBatchEligible { flags.append("batch") }
        return "\(s.fileName) -> \(b.path) [\(flags.joined(separator: ", "))]"
    }

    private func snapshot(_ suggestions: [FilingSuggestion]) -> String {
        suggestions.map(line).sorted().joined(separator: "\n")
    }

    @Test func filingSnapshotIsStable() {
        let taxonomy = [
            dir("/root/Documents", [dir("/root/Documents/Vehicles", [dir("/root/Documents/Vehicles/Tesla")])]),
            dir("/root/Photos"),
            dir("/root/Finance"),
            // Two same-year folders: a bare year must not stand up a confident, batch-eligible home.
            dir("/root/Archive", [dir("/root/Archive/2024")]),
            dir("/root/Projects", [dir("/root/Projects/2024")]),
        ]
        let loose = [
            file("/root/Downloads/tesla registration card.pdf"),   // name matches an existing folder
            file("/root/Downloads/IMG_2831.HEIC"),                  // photo → Photos/<year>
            file("/root/Downloads/1099-INT 2024.pdf"),             // tax doc
            file("/root/Downloads/2024-overview.pdf"),             // ONLY a year token → no confident home
            file("/root/Downloads/blorf.xyz"),                     // no signal at all
        ]

        let suggestions = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root")

        // GOLDEN — captured, hand-verified, pinned. Re-bless only after confirming an intentional
        // change to the filing heuristic is correct.
        let expected = """
        1099-INT 2024.pdf -> /root/Documents/Taxes/2024 [medium, batch]
        2024-overview.pdf -> (no confident home)
        IMG_2831.HEIC -> /root/Photos/2024 [high, batch]
        blorf.xyz -> (no confident home)
        tesla registration card.pdf -> /root/Documents/Vehicles/Tesla [high, batch]
        """
        #expect(snapshot(suggestions) == expected)
    }
}
