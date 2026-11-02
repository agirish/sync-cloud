import Foundation

/// The defaults Reset All Settings leaves in place: what protects him, what records money spent, and
/// what he made by hand.
///
/// - **The Never show Claude list.** A reset that emptied it showed Claude every folder he had hidden.
/// - **The spending limits** — Ask Claude's monthly limit and Refine's monthly and lifetime caps. A
///   reset returned them to $25, no cap and $5, which loosens a limit he had set lower.
/// - **The spend records** — Ask Claude's per-month totals, and Refine's history, lifetime totals,
///   last scan and the `.unreadable` copies of a history or total that failed to read. They are what
///   the limits count against: wiped, this month's limit started again from nothing.
/// - **Automations and saved signatures** — rules and signatures he made, not settings he chose. The
///   legacy filing rules go with their "migrated" flag: kept rules under a reset flag would migrate
///   into Automations a second time. The Add Signature sheet's last face, pen and smoothing reset.
///
/// Everything else in the domain is reset, `askClaudeReadsFiles` included: its default, off, is the
/// stricter one.
public enum SettingsResetKeeps {

    public static let keys: Set<String> = [
        AskClaudePrivacy.hiddenFoldersKey,
        AskClaudeSpend.limitDefaultsKey,
        FileSyncManager.monthlyBudgetCapKey,
        FileSyncManager.totalBudgetCapKey,
        FilingSpendStore.historyKey,
        FilingSpendStore.historyKey + ".unreadable",
        FilingSpendStore.totalsKey,
        FilingSpendStore.totalsKey + ".unreadable",
        FilingSpendStore.lastKey,
        FileSyncManager.automationRulesDefaultsKey,
        FileSyncManager.automationRulesDefaultsKey + ".unreadable",
        FileSyncManager.rulesDefaultsKey,
        FileSyncManager.rulesDefaultsKey + ".unreadable",
        FileSyncManager.filingRulesMigratedKey,
        // `EditorPDFSignatureStore.key`, in FileExplorer, which this package cannot see; its tests
        // pin that the two agree.
        "editorPDFSavedSignatures",
    ]

    public static func keeps(_ key: String) -> Bool {
        keys.contains(key) || key.hasPrefix(AskClaudeSpend.monthKeyPrefix)
    }
}
