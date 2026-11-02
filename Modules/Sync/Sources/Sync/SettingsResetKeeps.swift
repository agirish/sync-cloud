import Foundation

/// The defaults Reset All Settings leaves in place: what protects him, what records money spent,
/// what he made by hand, and the marks that say which shape the stored data is in.
///
/// - **The Never show Claude list.** A reset that emptied it showed Claude every folder he had hidden.
/// - **The spending limits** — Ask Claude's monthly limit and Refine's monthly and lifetime caps. A
///   reset returned them to $25, no cap and $5, which loosens a limit he had set lower.
/// - **The spend records** — Ask Claude's per-month totals, and Refine's history, lifetime totals,
///   last scan and the `.unreadable` copies of a history or total that failed to read. They are what
///   the limits count against: wiped, this month's limit started again from nothing.
/// - **Rules and saved signatures** — rules and signatures he made, not settings he chose. The
///   legacy filing rules go with their "migrated" flag: under a reset flag, the next launch would
///   migrate them again, bringing back any legacy rule he had since deleted or changed. The Add
///   Signature sheet's last face, pen and smoothing reset.
/// - **Migration marks.** What the running app writes after a reset — its tabs, at once — is in the
///   current shape, so a reset that dropped the mark had the next launch migrate it again — and the
///   roots moves are not idempotent: `RootsMigration.stampKey`'s note says a second pass prepends
///   again, `Documents/Documents/…`.
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
        OrganizeScopeDefaults.stampKey,
        // Keys of packages this one cannot see, by their strings; Dashboard's tests, which see them
        // all, pin that each still agrees with its owner.
        "editorPDFSavedSignatures",             // EditorPDFSignatureStore.key
        "rootsModelStamp",                      // RootsMigration.stampKey
        "rootsModelHandledProviderIds",         // RootsMigration.handledProviderIdsKey
        "iCloudRootMoveStamp",                  // RootsMigration.iCloudRootMoveStampKey
        "paneBarArrangementMigration",          // PaneBar.migrationKey
        "browseSidebarFavoritePlacesMigration", // SidebarFavoritePlaces.migrationKey
        "paneColumnWidthFloorLifted",           // PaneViewMode.columnWidthFloorLiftKey
    ]

    public static func keeps(_ key: String) -> Bool {
        keys.contains(key) || key.hasPrefix(AskClaudeSpend.monthKeyPrefix)
    }
}
