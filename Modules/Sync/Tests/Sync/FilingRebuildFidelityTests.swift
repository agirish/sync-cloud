import Foundation
import Testing
@testable import Sync

/// A re-answer must carry `alreadyFiledAt` forward. Four places give a suggestion new homes: a
/// verdict promotion (`applyVerdicts`), a route (`routed`), a re-ask (`replaceFilingSuggestion`,
/// behind "Try another" and "Read scan"), and the rename pass. Only the end-of-scan marking pass
/// produces `alreadyFiledAt`, so a rebuild that drops it loses the already-filed warning and the
/// `isBatchEligible` guard, and a second copy gets filed with nothing saying it is one. All four
/// must go through `replacingCandidates(_:)`.
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
        // The rest of the record, so "carries everything" is asserted.
        #expect(rebuilt.filePath == Self.suggestion().filePath)
        #expect(rebuilt.fileName == "eOCI.pdf")
        #expect(rebuilt.size == 1_000)
        #expect(rebuilt.modificationDate == Self.suggestion().modificationDate)
        #expect(rebuilt.providerRoot == Self.root)
    }

    /// What the marker is for: a document the tree already holds stays out of the blind batch
    /// across a rebuild.
    @Test func aRebuiltSuggestionIsStillKeptOutOfTheBlindBatch() {
        let confident = Self.suggestion().replacingCandidates([Self.dest("Legal/OCI", confidence: .high)])
        #expect(confident.hasConfidentHome, "the fixture cannot answer the batch question")
        #expect(!confident.isBatchEligible,
                "a document already in the tree became blind-batch eligible by being re-answered")

        // Control: the same rebuild of a document the tree doesn't hold is batch-eligible.
        let fresh = Self.suggestion(alreadyFiledAt: [])
            .replacingCandidates([Self.dest("Legal/OCI", confidence: .high)])
        #expect(fresh.isBatchEligible)
    }

    /// Every rebuild site goes through the member, asserted at the source because three of the four
    /// can't be driven from here (they need a live `FileSyncManager`, a provider root and a
    /// published list). Reverting `replaceFilingSuggestion` to a member-by-member rebuild must fail
    /// this.
    @Test func everyRebuildSiteGoesThroughTheMember() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync")
        // `FilingEngine.swift` is absent: it declares `replacingCandidates`, so `contains` would
        // always pass there. `promotingAVerdictKeepsTheAlreadyFiledMarker` covers that site.
        for (file, declaration) in [("FileSyncManager+Filing.swift", "replaceFilingSuggestion"),
                                    ("FileSyncManager+FilingRoute.swift", "routed"),
                                    ("FileSyncManager+FilingRename.swift", "naming")] {
            let source = try #require(try? String(contentsOf: dir.appendingPathComponent(file),
                                                  encoding: .utf8),
                                      "cannot read \(file) — this scan would be vacuous")
            try #require(source.count > 500, "\(file) is implausibly short")
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(code.contains("replacingCandidates("),
                    "\(file) rebuilds a suggestion without the member (\(declaration)); alreadyFiledAt drops there")
        }
    }

    /// No re-answering site calls the initialiser member by member. Scoped to the two files that
    /// only re-answer: `FilingEngine` builds the original suggestion and `+FilingRoute` builds a
    /// blank one for routing, so a bare initialiser there is legitimate.
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

    /// `applyVerdicts` promotes a model answer over the heuristic's, one of the four rebuilds,
    /// driven here through the real entry point.
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
