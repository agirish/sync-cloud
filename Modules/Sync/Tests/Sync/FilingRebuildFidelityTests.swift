import Foundation
import Testing
@testable import Sync

/// **What a re-answer must carry forward.**
///
/// Four places give a suggestion a new list of homes: a verdict promotion (`applyVerdicts`), a
/// route (`routed`), a re-ask (`replaceFilingSuggestion`, behind "Try another" and "Read scan"),
/// and the rename pass re-naming the incoming file. Each rebuilt the value member by member, and
/// each therefore dropped `alreadyFiledAt` — the folders that already hold this same document by
/// content, which only the end-of-scan marking pass produces.
///
/// So a marked list that was refined, or a card the user pressed "Try another" on, came back with
/// `isAlreadyFiled == false`: the warning that stops a second copy being filed disappeared, and
/// with it the `isBatchEligible` guard that keeps such a document out of the blind batch. Filing a
/// second copy is not undone by moving it back — it lands under a name of its own in a folder that
/// legitimately fits, with nothing about it saying it is a copy.
///
/// `replacingCandidates(_:)` is now the one way to do it, and these hold it to that.
@Suite struct FilingRebuildFidelityTests {

    static let root = "/root"

    static func suggestion(alreadyFiledAt: [String] = ["Legal/Immigration"]) -> FilingSuggestion {
        FilingSuggestion(filePath: "\(root)/TODO/eOCI.pdf", fileName: "eOCI.pdf", size: 1_000,
                         modificationDate: Date(timeIntervalSince1970: 1_786_000_000),
                         candidates: [dest("Documents/Inbox")], providerRoot: root,
                         alreadyFiledAt: alreadyFiledAt)
    }

    static func dest(_ relative: String, confidence: FilingConfidence = .medium) -> FilingDestination {
        FilingDestination(path: "\(root)/\(relative)", confidence: confidence, reasons: ["t"],
                          newSegments: [], fromContent: false, remembered: false, fromAI: false,
                          evidenceToken: nil, neighborMatches: 0)
    }

    /// The member itself: new homes, everything else intact.
    @Test func replacingCandidatesKeepsTheAlreadyFiledMarker() {
        let rebuilt = Self.suggestion().replacingCandidates([Self.dest("Legal/OCI")])
        #expect(rebuilt.alreadyFiledAt == ["Legal/Immigration"])
        #expect(rebuilt.isAlreadyFiled)
        #expect(rebuilt.best?.path == "/root/Legal/OCI", "the new homes did not take")
        // The rest of the record, so "carries everything" is asserted rather than described.
        #expect(rebuilt.filePath == Self.suggestion().filePath)
        #expect(rebuilt.fileName == "eOCI.pdf")
        #expect(rebuilt.size == 1_000)
        #expect(rebuilt.modificationDate == Self.suggestion().modificationDate)
        #expect(rebuilt.providerRoot == Self.root)
    }

    /// And the consequence the marker exists for: a document the tree already holds stays out of
    /// the blind batch across a rebuild. This is the assertion that would have caught the defect —
    /// the field is a means, this is the end.
    @Test func aRebuiltSuggestionIsStillKeptOutOfTheBlindBatch() {
        let confident = Self.suggestion().replacingCandidates([Self.dest("Legal/OCI", confidence: .high)])
        #expect(confident.hasConfidentHome, "the fixture cannot answer the batch question")
        #expect(!confident.isBatchEligible,
                "a document already in the tree became blind-batch eligible by being re-answered")

        // The other direction, so the test above is not passing on something else: the same rebuild
        // of a document the tree does NOT already hold IS batch-eligible.
        let fresh = Self.suggestion(alreadyFiledAt: [])
            .replacingCandidates([Self.dest("Legal/OCI", confidence: .high)])
        #expect(fresh.isBatchEligible)
    }

    /// **Every rebuild site goes through the member**, asserted at the source because three of the
    /// four cannot be driven from here (they need a live `FileSyncManager`, a provider root and a
    /// published list). Without this the member is one revert from being unused on those paths:
    /// reverting `replaceFilingSuggestion` — the "Try another" path the defect was reported
    /// against — reproduces the symptom exactly with every behavioural test below still green.
    @Test func everyRebuildSiteGoesThroughTheMember() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync")
        for (file, declaration) in [("FilingEngine.swift", "applyVerdicts"),
                                    ("FileSyncManager+Filing.swift", "replaceFilingSuggestion"),
                                    ("FileSyncManager+FilingRoute.swift", "routed"),
                                    ("FileSyncManager+FilingRename.swift", "naming")] {
            let source = try #require(try? String(contentsOf: dir.appendingPathComponent(file),
                                                  encoding: .utf8),
                                      "cannot read \(file) — this scan would be vacuous")
            try #require(source.count > 500, "\(file) is implausibly short")
            #expect(source.contains("replacingCandidates("),
                    "\(file) rebuilds a suggestion without the member (\(declaration)); alreadyFiledAt drops there")
        }
    }

    /// And the shape that lost it is gone: no rebuild names the initialiser member by member.
    ///
    /// Scoped to the two files that only ever *re-answer*. `FilingEngine` builds the original
    /// suggestion and `+FilingRoute` builds a deliberately blank one for routing, so a bare
    /// initialiser there is legitimate.
    @Test func noReAnsweringSiteCallsTheInitialiserDirectly() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync")
        for file in ["FileSyncManager+Filing.swift", "FileSyncManager+FilingRename.swift"] {
            let source = try #require(try? String(contentsOf: dir.appendingPathComponent(file),
                                                  encoding: .utf8))
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains("FilingSuggestion(filePath:"),
                    "\(file) builds a FilingSuggestion member by member again")
        }
    }

    /// `applyVerdicts` promotes a model answer over the heuristic's. It rebuilds, so it is one of
    /// the four — driven here through the real entry point rather than asserted about the source.
    @Test func promotingAVerdictKeepsTheAlreadyFiledMarker() throws {
        let s = Self.suggestion(alreadyFiledAt: ["Legal/Immigration"])
        let verdict = FilingVerdict(relativePath: "Legal/OCI", confidence: .high,
                                    reason: "names the OCI card", proposesNewFolder: false)
        let out = FilingEngine.applyVerdicts([s.filePath: verdict], to: [s],
                                             existingRelative: ["Legal", "Legal/OCI", "Documents/Inbox"],
                                             providerRoot: Self.root)
        let rebuilt = try #require(out.first)
        #expect(rebuilt.best?.path == "/root/Legal/OCI", "the verdict was not promoted — nothing was rebuilt")
        #expect(rebuilt.isAlreadyFiled,
                "promoting a verdict dropped the already-filed warning")
    }
}
