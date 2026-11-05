import Foundation
import Testing
import Sync
@testable import SyncCloud

/// The on-device Filing backend's deterministic parts: prompt shaping, the model-answer→verdict
/// mapping (what `FolderPick.asVerdict()` delegates to), and availability gating. The Foundation
/// Models session depends on the machine (macOS 26 + Apple Intelligence), so no test asserts model
/// output.
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

    /// Pins the instructions' load-bearing phrases: the decline word the verdict mapping keys on, and
    /// the relative-path contract the folder matcher depends on.
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

    /// With no taxonomy there is nothing to classify: `classify` returns empty whether the model is
    /// unavailable (outer gate) or available (the empty-taxonomy guard), never touching a file.
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

    /// `prewarm` is safe to call repeatedly: a silent no-op when the model isn't available, and only
    /// a queued background warm-up when it is. Either way it returns at once without crashing.
    @Test func prewarmIsSafeToCallRepeatedly() {
        OnDeviceFilingClassifier.prewarm()
        OnDeviceFilingClassifier.prewarm()
    }

    // MARK: Hybrid backend routing (cloud vs. on-device)

    /// Runs the router with a recording sink in place of `Logger.shared`, so a test can assert the
    /// route and whether the user was told about a downgrade.
    private func routed(cloudEnabled: Bool, hasCloudKey: Bool) -> (route: FilingBackendRoute, reported: [String]) {
        var reported: [String] = []
        let route = FilingBackendRouter.route(cloudEnabled: cloudEnabled, hasCloudKey: hasCloudKey) {
            reported.append($0)
        }
        return (route, reported)
    }

    /// The key question must not be asked unless the cloud toggle is on. In production it is
    /// `AnthropicKeychain.hasKey`, a live Keychain query; evaluated eagerly, every Filing scan would
    /// touch the Keychain with cloud Filing off, which on a locked or denied item logs a warning and
    /// can raise an access prompt for a feature the user disabled. Counted, since the route alone is
    /// the same either way.
    @Test func theKeychainIsNotQueriedWhileCloudFilingIsOff() {
        var keyQueries = 0
        func hasKey() -> Bool {
            keyQueries += 1
            return true
        }

        #expect(FilingBackendRouter.route(cloudEnabled: false, hasCloudKey: hasKey(),
                                          logDowngrade: { _ in }) == .onDevice)
        #expect(keyQueries == 0, "cloud Filing is off — nothing may ask the Keychain about a key")

        // With the toggle on it is asked exactly once: the gate must be lazy, not dead.
        #expect(FilingBackendRouter.route(cloudEnabled: true, hasCloudKey: hasKey(),
                                          logDowngrade: { _ in }) == .cloud)
        #expect(keyQueries == 1)
    }

    @Test func cloudFilingOffRunsOnDeviceWithNothingToReport() {
        // Cloud off is not a downgrade: it's what the user asked for, key or no key.
        let noKey = routed(cloudEnabled: false, hasCloudKey: false)
        #expect(noKey.route == .onDevice)
        #expect(noKey.reported.isEmpty)

        let staleKey = routed(cloudEnabled: false, hasCloudKey: true)
        #expect(staleKey.route == .onDevice)
        #expect(staleKey.reported.isEmpty)
    }

    @Test func cloudFilingOnWithAKeyRunsInTheCloudSilently() {
        let result = routed(cloudEnabled: true, hasCloudKey: true)
        #expect(result.route == .cloud)
        #expect(result.reported.isEmpty)
    }

    /// The toggle is on but no key can be read (never entered, deleted, or a locked Keychain), so the
    /// on-device model files the documents while the user believes Claude did. That must be logged
    /// once, or the Activity Log can't tell it from a real cloud run.
    @Test func cloudFilingOnWithoutAKeyDowngradesAndSaysSoExactlyOnce() throws {
        let result = routed(cloudEnabled: true, hasCloudKey: false)
        #expect(result.route == .onDeviceCloudKeyUnavailable)
        #expect(result.reported.count == 1)

        let message = try #require(result.reported.first)
        #expect(message == FilingBackendRouter.missingKeyDowngradeMessage)
        // The message has to carry all three: what was expected, what actually ran, and the fix.
        #expect(message.contains("Cloud (Claude) Filing is enabled"))
        #expect(message.contains("on-device"))
        #expect(message.contains("Settings ▸ Intelligence"))
    }

    // MARK: Prompt budget

    /// A prompt that doesn't fit is a budget to shrink, not a file to skip. The on-device model's
    /// context window is small and shared with its output: a few hundred folders plus a
    /// 1,200-character excerpt can overflow it, and a skipped file silently keeps its
    /// filename-derived home.
    @Test func eachRungOfTheLadderShrinksBothInputs() {
        let folders = (0..<400).map { "Folder\($0)" }.joined(separator: "\n")
        let file = Self.candidate(name: "DetailedBillApr2025.pdf", ext: "pdf",
                                  snippet: String(repeating: "x", count: 4_000))
        var lastFolderCount = Int.max
        for budget in OnDeviceFilingClassifier.PromptBudget.ladder {
            let prompt = OnDeviceFilingClassifier.promptText(for: file, folderList: folders, budget: budget)
            let listed = prompt.components(separatedBy: "Folder").count - 1
            #expect(listed == budget.folders, "listed \(listed) folders for a budget of \(budget.folders)")
            #expect(listed < lastFolderCount, "a rung must be smaller than the one before it")
            lastFolderCount = listed
            if budget.snippetChars > 0 {
                let excerpt = prompt.components(separatedBy: "Content excerpt:\n").last ?? ""
                let xs = excerpt.filter { $0 == "x" }.count
                #expect(xs == budget.snippetChars, "excerpt was \(xs) chars for a budget of \(budget.snippetChars)")
            } else {
                #expect(!prompt.contains("Content excerpt"))
            }
        }
        // The last rung drops the excerpt entirely: the folder list is what a verdict must answer in.
        #expect(!OnDeviceFilingClassifier.promptText(
            for: file, folderList: folders,
            budget: OnDeviceFilingClassifier.PromptBudget.ladder.last!).contains("Content excerpt"))
    }

    /// The real message, verbatim from `~/sync-cloud.log`. Matched on text rather than a typed case
    /// because the two are reported differently across OS updates, and a false positive costs only
    /// one retry with a smaller prompt, against silently keeping a wrong home.
    @Test func aContextOverflowIsToldApartFromAModelDeclining() {
        struct Fake: LocalizedError { let errorDescription: String? }
        #expect(OnDeviceFilingClassifier.isContextOverflow(
            Fake(errorDescription: "Exceeded model context window size")))
        #expect(!OnDeviceFilingClassifier.isContextOverflow(
            Fake(errorDescription: "The model was unable to produce a valid response")))
    }
}
