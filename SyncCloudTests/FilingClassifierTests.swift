import Foundation
import Testing
import Sync
@testable import SyncCloud

/// Coverage for the on-device Filing backend's deterministic parts: the per-file prompt shaping,
/// the model-answer→verdict mapping (what `FolderPick.asVerdict()` delegates to), and the
/// availability gating. The Foundation Models session itself is environment-dependent (macOS 26 +
/// Apple Intelligence), so no test asserts model output.
@Suite struct FilingClassifierTests {

    private static func candidate(name: String, ext: String, year: String? = nil,
                                  snippet: String? = nil, excluded: [String] = []) -> FilingCandidateFile {
        FilingCandidateFile(filePath: "/tmp/loose/\(name)", fileName: name, ext: ext, year: year,
                            contentSnippet: snippet, excludedRelativePaths: excluded)
    }

    // MARK: Prompt shaping

    @Test func promptCarriesTheFolderListAndBareFileFacts() {
        let prompt = OnDeviceFilingClassifier.promptText(
            for: Self.candidate(name: "resume.docx", ext: "docx"),
            folderList: "Documents/Career\nDocuments/Taxes")
        #expect(prompt == """
        Existing folders (relative paths):
        Documents/Career
        Documents/Taxes

        File name: resume.docx
        Type: docx

        Which folder should this file go in?
        """)
    }

    @Test func emptyExtensionReadsAsUnknownType() {
        let prompt = OnDeviceFilingClassifier.promptText(
            for: Self.candidate(name: "README", ext: ""), folderList: "Documents")
        #expect(prompt.contains("Type: unknown"))
    }

    @Test func yearSnippetAndRejectedFoldersAppearWhenPresent() {
        let prompt = OnDeviceFilingClassifier.promptText(
            for: Self.candidate(name: "scan.pdf", ext: "pdf", year: "2024",
                                snippet: "GEICO declarations page",
                                excluded: ["Documents/Insurance", "Documents/Cars"]),
            folderList: "Documents")
        #expect(prompt.contains("Modified: 2024"))
        #expect(prompt.contains("Content excerpt:\nGEICO declarations page"))
        #expect(prompt.contains("do NOT choose them, pick a different one: Documents/Insurance, Documents/Cars"))
    }

    @Test func contentExcerptIsCappedAt1200Chars() {
        let snippet = String(repeating: "x", count: 5_000)
        let prompt = OnDeviceFilingClassifier.promptText(
            for: Self.candidate(name: "big.pdf", ext: "pdf", snippet: snippet), folderList: "Documents")
        #expect(prompt.contains(String(repeating: "x", count: 1_200)))
        #expect(!prompt.contains(String(repeating: "x", count: 1_201)))
    }

    @Test func emptySnippetAddsNoExcerptSection() {
        let prompt = OnDeviceFilingClassifier.promptText(
            for: Self.candidate(name: "a.pdf", ext: "pdf", snippet: ""), folderList: "Documents")
        #expect(!prompt.contains("Content excerpt"))
    }

    /// Pins the instruction constant's load-bearing phrases — the decline word the verdict mapping
    /// keys on, and the relative-path contract the folder matcher depends on.
    @Test func instructionsPinTheDeclineWordAndRelativePathContract() {
        let text = OnDeviceFilingClassifier.onDeviceInstructions
        #expect(text.contains("answer with the folder \"none\""))
        #expect(text.contains("never an absolute path"))
        #expect(text.contains("copy its path exactly"))
    }

    // MARK: Model answer → verdict mapping (FolderPick.asVerdict delegates here)

    @Test func declinesMapToNil() {
        #expect(OnDeviceFilingClassifier.verdict(folder: "none", confidence: 90, reason: "r") == nil)
        #expect(OnDeviceFilingClassifier.verdict(folder: "None", confidence: 90, reason: "r") == nil)
        #expect(OnDeviceFilingClassifier.verdict(folder: "  NONE  ", confidence: 90, reason: "r") == nil)
        #expect(OnDeviceFilingClassifier.verdict(folder: "", confidence: 90, reason: "r") == nil)
        #expect(OnDeviceFilingClassifier.verdict(folder: "  \"\"  ", confidence: 90, reason: "r") == nil)
    }

    @Test func stripsQuotesAndWhitespaceFromTheFolder() {
        let verdict = OnDeviceFilingClassifier.verdict(
            folder: " \"Documents/Taxes/2024\" ", confidence: 85, reason: "Tax form.")
        #expect(verdict?.relativePath == "Documents/Taxes/2024")
    }

    @Test func confidenceScoreBucketsAndClamps() {
        func confidence(_ score: Int) -> FilingConfidence? {
            OnDeviceFilingClassifier.verdict(folder: "Docs", confidence: score, reason: "r")?.confidence
        }
        #expect(confidence(100) == .high)
        #expect(confidence(80) == .high)
        #expect(confidence(79) == .medium)
        #expect(confidence(50) == .medium)
        #expect(confidence(49) == .low)
        #expect(confidence(0) == .low)
        #expect(confidence(250) == .high)   // clamped into 0...100
        #expect(confidence(-7) == .low)
    }

    @Test func blankReasonGetsTheDefaultAttribution() {
        #expect(OnDeviceFilingClassifier.verdict(folder: "Docs", confidence: 60, reason: "  ")?.reason
                == "Chosen by on-device AI")
        #expect(OnDeviceFilingClassifier.verdict(folder: "Docs", confidence: 60, reason: " Looks right. ")?.reason
                == "Looks right.")
    }

    // MARK: Availability gating (no model output asserted)

    @Test func availabilityIsStableAcrossCalls() {
        #expect(OnDeviceFilingClassifier.isAvailable == OnDeviceFilingClassifier.isAvailable)
    }

    /// With no taxonomy there is nothing to classify: `classify` returns empty both when the model
    /// is unavailable (outer gate) and when it is (the empty-taxonomy guard) — never touching a file.
    @Test func classifyWithoutATaxonomyReturnsEmpty() async {
        let result = await OnDeviceFilingClassifier.classify(
            taxonomyFolders: [], files: [Self.candidate(name: "a.pdf", ext: "pdf")])
        #expect(result.isEmpty)
    }

    /// An empty batch is a no-op on every path (unavailable → outer empty; available → the loop has
    /// nothing to iterate), so this is deterministic without asserting model behavior.
    @Test func classifyWithAnEmptyBatchReturnsEmpty() async {
        let result = await OnDeviceFilingClassifier.classify(taxonomyFolders: ["Documents"], files: [])
        #expect(result.isEmpty)
    }

    /// `prewarm` is documented safe to call repeatedly and must be a silent no-op when the model
    /// isn't available; when it is available it only enqueues a background warm-up. Either way it
    /// must return immediately without throwing or crashing.
    @Test func prewarmIsSafeToCallRepeatedly() {
        OnDeviceFilingClassifier.prewarm()
        OnDeviceFilingClassifier.prewarm()
    }
}
