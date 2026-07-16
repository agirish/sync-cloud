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
            dir("/root/Receipts"),
            // Two same-year folders: a bare year must not stand up a confident, batch-eligible home.
            dir("/root/Archive", [dir("/root/Archive/2024")]),
            dir("/root/Projects", [dir("/root/Projects/2024")]),
        ]
        let loose = [
            file("/root/Downloads/tesla registration card.pdf"),   // name matches an existing folder
            file("/root/Downloads/IMG_2831.HEIC"),                  // photo → Photos/<year>
            // Camera-sequence stems whose counter LOOKS like a year: the digits are a shot
            // number, so the year segment must come from the mtime (2024), never Photos/2023
            // or Photos/1995 — while a real year in a real name ("Wedding 2023") still wins.
            file("/root/Downloads/IMG_2023.jpg"),
            file("/root/Downloads/DSC_1995.jpg"),
            file("/root/Downloads/Wedding 2023.jpg"),
            file("/root/Downloads/Screen Shot 2024-11-02.png"),     // screenshot rides the photo rule
            file("/root/Downloads/1099-INT 2024.pdf"),             // tax doc, filename year == mtime year
            // Filename year ≠ mtime year: the filename's 2023 must win the year segment (every
            // other fixture's years coincide, which is exactly how the mtime-only bug hid).
            file("/root/Downloads/1099-INT 2023.pdf"),
            // ZERO filename years → the year segment falls back to the 2024 mtime.
            file("/root/Downloads/1099-INT.pdf"),
            // MULTIPLE filename year tokens (a range names no single year) → mtime fallback too.
            file("/root/Downloads/2021-2022 tax summary.pdf"),
            // Receipt with an existing top-level Receipts folder → high, filed by (mtime) year.
            file("/root/Downloads/amazon order receipt.pdf"),
            // Statement, no Statements/Bank folder → Finance/<filename year>; a second category
            // pinning that the filename's year outranks the mtime year.
            file("/root/Downloads/chase statement 2023.pdf"),
            // Vehicle + insurance for a brand WITHOUT an existing folder → new segments under the
            // Vehicles anchor.
            file("/root/Downloads/honda geico insurance.pdf"),
            file("/root/Downloads/2024-overview.pdf"),             // ONLY a year token → no confident home
            file("/root/Downloads/blorf.xyz"),                     // no signal at all
            // No name signal, but a content token ("invoice", read from the file) finds a home:
            // capped to medium and NEVER batch-eligible — content is a weaker signal.
            file("/root/Downloads/scan0001.pdf"),
        ]
        let contentTokens: [String: Set<String>] = [
            "/root/Downloads/scan0001.pdf": ["invoice"],
        ]

        let suggestions = FilingEngine.suggest(looseFiles: loose, taxonomy: taxonomy,
                                               providerRoot: "/root", contentTokens: contentTokens)

        // GOLDEN — captured, hand-verified, pinned. Load-bearing classes:
        //  · 1099-INT 2023 files into Taxes/2023 (filename year) while 1099-INT.pdf (no year) and
        //    "2021-2022 tax summary" (a RANGE names no single year) both fall back to the 2024
        //    mtime — the whole filenameYear contract of 87f1e2f in one block;
        //  · chase statement 2023 pins the same filename-year-wins rule in a second category;
        //  · amazon order receipt hits the HIGH path (existing Receipts folder); honda geico
        //    insurance builds new Honda/Insurance segments under the existing Vehicles anchor;
        //  · Screen Shot …png rides the photo rule into Photos/<year>;
        //  · IMG_2023 / DSC_1995 file by MTIME year (2024): a camera-sequence counter that looks
        //    like a year is not a filing year — while Wedding 2023 keeps its real filename year;
        //  · scan0001.pdf finds a home ONLY via a content token: medium-capped, marked `content`,
        //    and NOT batch — a content match must never join the blind batch;
        //  · 2024-overview (bare year) and blorf.xyz still have no confident home.
        // Re-bless only after confirming an intentional change to the filing heuristic is correct.
        let expected = """
        1099-INT 2023.pdf -> /root/Documents/Taxes/2023 [medium, batch]
        1099-INT 2024.pdf -> /root/Documents/Taxes/2024 [medium, batch]
        1099-INT.pdf -> /root/Documents/Taxes/2024 [medium, batch]
        2021-2022 tax summary.pdf -> /root/Documents/Taxes/2024 [medium, batch]
        2024-overview.pdf -> (no confident home)
        DSC_1995.jpg -> /root/Photos/2024 [high, batch]
        IMG_2023.jpg -> /root/Photos/2024 [high, batch]
        IMG_2831.HEIC -> /root/Photos/2024 [high, batch]
        Screen Shot 2024-11-02.png -> /root/Photos/2024 [high, batch]
        Wedding 2023.jpg -> /root/Photos/2023 [high, batch]
        amazon order receipt.pdf -> /root/Receipts/2024 [high, batch]
        blorf.xyz -> (no confident home)
        chase statement 2023.pdf -> /root/Finance/2023 [medium, batch]
        honda geico insurance.pdf -> /root/Documents/Vehicles/Honda/Insurance [medium, batch]
        scan0001.pdf -> /root/Receipts/2024 [medium, content]
        tesla registration card.pdf -> /root/Documents/Vehicles/Tesla [high, batch]
        """
        #expect(snapshot(suggestions) == expected)
    }
}
