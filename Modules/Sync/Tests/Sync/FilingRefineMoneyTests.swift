import Foundation
import Testing
@testable import Sync

/// What Refine, Try Another and Refine Names cost and where it goes: the chat's model, Ask
/// Claude's prices, one monthly limit shared with the chat, and a separate Organize share.
@MainActor
@Suite struct FilingRefineMoneyTests {

    // MARK: Prices

    @Test func everyModelAskClaudeOffersIsPricedFromItsOwnTable() {
        for option in AskClaudeModels.options {
            let price = CloudFilingProtocol.pricing(for: option.id)
            #expect(price?.input == option.price.input && price?.output == option.price.output, "\(option.name)")
        }
        // The older ids keep their own arms.
        #expect(CloudFilingProtocol.pricing(for: "claude-haiku-4-5")?.input == 1)
        #expect(CloudFilingProtocol.pricing(for: "claude-opus-5")?.output == 25)
    }

    @Test func aQuoteIsPricedAtTheModelItNames() {
        let files = (0..<6).map { FilingCandidateFile(filePath: "/x/\($0)", fileName: "f\($0).pdf", ext: "pdf", year: "2026", contentSnippet: "text") }
        let folders = Array(repeating: "Documents/Family", count: 40)
        let costs = AskClaudeModels.options.map {
            ($0.id, CloudFilingProtocol.estimatedCostUSD(model: $0.id, taxonomyFolders: folders, files: files) ?? 0)
        }
        let byID = Dictionary(uniqueKeysWithValues: costs)
        #expect(byID[AskClaudeModels.haiku.id]! < byID[AskClaudeModels.sonnet.id]!)
        #expect(byID[AskClaudeModels.sonnet.id]! < byID[AskClaudeModels.opus.id]!)
        #expect(byID.values.allSatisfy { $0 > 0 })
    }

    @Test func theModelNamesAreTheMenusNames() {
        #expect(FilingSpendFormat.model("claude-opus-5-5") == "Opus 5.5")
        #expect(FilingSpendFormat.model("claude-sonnet-5-5") == "Sonnet 5.5")
        #expect(FilingSpendFormat.model("claude-haiku-5-5") == "Haiku 5.5")
        #expect(FilingSpendFormat.model("claude-opus-5") == "Opus", "an older id keeps its family name")
    }

    // MARK: The chat's model and the one limit

    private func manager(spend: Double = 0, limit: Double? = nil, model: String? = nil) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingContentDefaults = ScratchDefaults("FilingRefineMoneyTests-\(UUID().uuidString)")
        m.filingCloudRefineConfigured = { true }
        if let model { m.filingContentDefaults.set(model, forKey: AskClaudeModels.defaultsKey) }
        if let limit { m.filingContentDefaults.set(limit, forKey: AskClaudeSpend.limitDefaultsKey) }
        if spend > 0 { AskClaudeSpend.record(spend, in: m.filingContentDefaults) }
        m.filingBackendIdentity = { _ in "cloud:claude-model" }
        return m
    }

    private let files = [FilingCandidateFile(filePath: "/x/a.pdf", fileName: "a.pdf", ext: "pdf", year: "2026", contentSnippet: nil)]

    private func preflight(_ m: FileSyncManager) -> FilingSpendPreflight? {
        if case .billable(let p) = m.filingSpendGate(files: files, taxonomyFolders: ["Documents"]) { return p }
        return nil
    }

    @Test func refineRunsOnTheChatsModel() {
        #expect(manager().filingRefineModelID == AskClaudeModels.defaultModel.id, "the chat's default, Sonnet 5.5")
        let opus = manager(model: AskClaudeModels.opus.id)
        #expect(opus.filingRefineModelID == AskClaudeModels.opus.id && opus.filingRefineModelName == "Opus 5.5")
        #expect(preflight(opus)?.model == AskClaudeModels.opus.id)
        #expect(opus.resolvedFilingVerdictIdentity(for: .refine) == FilingVerdictKey.claudeIdentity)
        // A value the menu cannot show falls back rather than sending a model nobody chose.
        #expect(manager(model: "claude-opus-4-8").filingRefineModelID == AskClaudeModels.defaultModel.id)
    }

    @Test func theQuoteIsAgainstAskClaudesLimitAndThisMonthsSpendIncludingTheChats() throws {
        let m = manager(spend: 3.5, limit: 10)
        let p = try #require(preflight(m))
        #expect(p.monthlyCapUSD == 10 && p.monthlySpentUSD == 3.5, "the chat's spend counts")
        #expect(p.totalCapUSD == 0 && p.totalSpentUSD == 0, "the old lifetime cap is not read")
        #expect(!p.wouldExceedCap)
        #expect(try #require(preflight(manager(spend: 9.999, limit: 10))).wouldExceedCap)
        // The old Organize caps, by the strings they were stored under, are not read at all.
        let old = manager()
        old.filingContentDefaults.set(0.000001, forKey: "tidyFilingMonthlyBudgetUSD")
        old.filingContentDefaults.set(0.000001, forKey: "tidyFilingTotalBudgetUSD")
        #expect(try #require(preflight(old)).wouldExceedCap == false)
    }

    // MARK: Organize's share

    @Test func theOrganizeShareIsInsideTheTotalAndNotUnderTheMonthPattern() {
        let defaults = ScratchDefaults("FilingRefineMoneyTests-\(UUID().uuidString)")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AskClaudeSpend.record(1.0, in: defaults, now: now)                    // the chat
        AskClaudeSpend.recordOrganize(0.25, in: defaults, now: now)           // Refine
        #expect(AskClaudeSpend.spent(in: defaults, now: now) == 1.25, "the one limit reads the total")
        #expect(AskClaudeSpend.organizeSpent(in: defaults, now: now) == 0.25, "and Organize's part of it")
        let organizeKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("askClaudeOrganizeSpend.") }
        #expect(organizeKeys.count == 1)
        #expect(!organizeKeys.contains { $0.hasPrefix(AskClaudeSpend.monthKeyPrefix) },
                "no reader of a month's total can read the share as one")
        // A later month starts at zero, in both.
        let later = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: now)!
        #expect(AskClaudeSpend.spent(in: defaults, now: later) == 0 && AskClaudeSpend.organizeSpent(in: defaults, now: later) == 0)
        // A cost of nothing records nothing.
        AskClaudeSpend.recordOrganize(0, in: defaults, now: now)
        #expect(AskClaudeSpend.organizeSpent(in: defaults, now: now) == 0.25)
    }
}
