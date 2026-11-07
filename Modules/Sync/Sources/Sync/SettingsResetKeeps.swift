import Foundation

/// The defaults Reset All Settings leaves in place: what protects him, what records money spent,
/// what he made by hand, and the marks that say which shape the stored data is in.
///
/// - The Never show Claude list: emptied, Claude would see every folder he hid.
/// - The spending limits (Ask Claude's monthly limit, Refine's monthly and lifetime caps): reset
///   defaults would loosen a limit he set lower.
/// - The spend records the limits count against, including `.unreadable` copies: wiped, this
///   month's limit would start again from nothing.
/// - What he made by hand: Rules, saved signatures, Organize corrections, kept duplicate groups and
///   risky names, the people he said a file is not about, sidebar Favorites, Jump pins and their
///   order. The legacy filing rules keep their "migrated" flag, or the next launch would bring back
///   rules he deleted. What he only passed through (Jump recents, recent files, the signature
///   sheet's last pen) resets.
/// - Migration marks: the app writes current-shape data at once after a reset, so a dropped mark
///   would migrate it again, and the roots moves are not idempotent (`RootsMigration.stampKey`).
///
/// Everything else resets, `askClaudeSharedFolders` included: its default, none, is the stricter
/// one.
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
        FileSyncManager.rejectionsDefaultsKey,
        FileSyncManager.rejectionsDefaultsKey + ".unreadable",
        FileSyncManager.wordRejectionsDefaultsKey,
        FileSyncManager.wordRejectionsDefaultsKey + ".unreadable",
        FileSyncManager.ignoreDefaultsKey,
        KeptNamesStore.defaultsKey,
        PersonVetoLog.defaultsKey,
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
        "paneBarArrangementMigration",          // PaneBar.migrationKey
        // InfoPreviewMigration.doneKey (the app's): run again after a reset, it would read the
        // preview's reset keys as on and open Info. Pinned by the app's tests.
        "infoPreviewMigrationDone",
    ]

    public static func keeps(_ key: String) -> Bool {
        keys.contains(key) || key.hasPrefix(AskClaudeSpend.monthKeyPrefix)
    }
}
