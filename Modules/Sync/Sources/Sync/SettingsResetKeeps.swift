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
/// - **What he made by hand** — Rules, saved signatures, Organize's "not here" corrections, the
///   duplicate groups he kept separate, the risky names he kept, the people he said a file was not
///   about, and his sidebar Favorites, Jump pins and their order. Choices about his files, not
///   settings. The legacy filing rules go with their "migrated" flag: under a reset flag, the next
///   launch would migrate them again, bringing back any legacy rule he had since deleted or changed.
///   What he only passed through resets: Jump recents and stays, recent files, the Add Signature
///   sheet's last face, pen and smoothing.
/// - **Migration marks.** What the running app writes after a reset — its tabs, at once — is in the
///   current shape, so a reset that dropped the mark had the next launch migrate it again — and the
///   roots moves are not idempotent: `RootsMigration.stampKey`'s note says a second pass prepends
///   again, `Documents/Documents/…`.
///
/// Everything else in the domain is reset, `askClaudeSharedFolders` included: its default, none,
/// is the stricter one.
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
        FileSyncManager.rejectionsDefaultsKey,
        FileSyncManager.rejectionsDefaultsKey + ".unreadable",
        FileSyncManager.wordRejectionsDefaultsKey,
        FileSyncManager.wordRejectionsDefaultsKey + ".unreadable",
        FileSyncManager.ignoreDefaultsKey,
        KeptNamesStore.defaultsKey,
        PersonVetoLog.defaultsKey,
        OrganizeScopeDefaults.stampKey,
        // Keys of packages this one cannot see, by their strings; Dashboard's tests, which see them
        // all, pin that each still agrees with its owner.
        "editorPDFSavedSignatures",             // EditorPDFSignatureStore.key
        "browseSidebarFavoritePlaces",          // SidebarFavoritePlaces.storageKey
        "browseSidebarFavoritePlaces.unreadable", // SidebarFavoritePlaces.salvageKey
        "folderJumpPinnedByRoot",               // FolderJumpStore.pinnedKey
        "folderJumpPinnedByRoot.unreadable",    // FolderJumpStore.salvageKey(for: pinnedKey)
        "folderJumpFavoriteOrder",              // FolderJumpStore.favoriteOrderKey
        "rootsModelStamp",                      // RootsMigration.stampKey
        "rootsModelHandledProviderIds",         // RootsMigration.handledProviderIdsKey
        "iCloudRootMoveStamp",                  // RootsMigration.iCloudRootMoveStampKey
        "paneBarArrangementMigration",          // PaneBar.migrationKey
        "browseSidebarFavoritePlacesMigration", // SidebarFavoritePlaces.migrationKey
        "paneColumnWidthFloorLifted",           // PaneViewMode.columnWidthFloorLiftKey
        // InfoPreviewMigration.doneKey (the app's): run again after a reset, it read the preview's
        // reset keys as on and opened Info (review 2 of 11-04). Pinned by the app's tests.
        "infoPreviewMigrationDone",
    ]

    public static func keeps(_ key: String) -> Bool {
        keys.contains(key) || key.hasPrefix(AskClaudeSpend.monthKeyPrefix)
    }
}
