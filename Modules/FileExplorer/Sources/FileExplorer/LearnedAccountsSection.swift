import Design
import SwiftUI
import Sync

/// Automations ▸ Learned Accounts (decision 8): each account To File learned from where he filed
/// its statements, with Remove. A folder gone missing is listed and not used.
struct LearnedAccountsSection: View {
    @ObservedObject var syncManager: FileSyncManager
    let densityMetrics: ListDensityMetrics

    var body: some View {
        let accounts = syncManager.filingLearnedAccounts
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Learned Accounts")
                    .scaledFont(.system(size: 13, weight: .semibold))
                Text("Statements printing these numbers file into these folders. Learned when you chose a folder for them; the last four digits are stored as they are printed.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(accounts) { account in
                    LearnedAccountRow(account: account,
                                      sharesEnding: accounts.filter { $0.institution == account.institution
                                                                      && $0.ending == account.ending }.count,
                                      folderExists: syncManager.learnedAccountFolderExists(account),
                                      note: syncManager.learnedAccountNote(account),
                                      onRemove: { syncManager.removeLearnedAccount(id: account.id) })
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, densityMetrics.cardHeaderVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lensCard()
            .onAppear { syncManager.forgetUndoneLearnedAccounts() }
        }
    }
}

private struct LearnedAccountRow: View {
    let account: LearnedAccount
    let sharesEnding: Int
    let folderExists: Bool
    /// Why it isn't in use, when it isn't.
    let note: String?
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(account.institutionName) ••\(account.ending) → \(account.folder.split(separator: "/").joined(separator: " › "))")
                    .scaledFont(.system(size: 12))
                    .lineLimit(2).truncationMode(.middle)
                Text(note.map { folderExists ? $0 : "folder missing · not used" }
                     ?? LearnedAccountText.detail(account, sharesEnding: sharesEnding, folderExists: folderExists))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(folderExists && note == nil ? Color.secondary : SemanticColor.caution)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Remove", action: onRemove)
                .controlSize(.small)
                .help("Forget this account; its statements are matched by their folder names again")
        }
    }
}

enum LearnedAccountText {
    /// "taught Nov 13 · 10 filed", "folder missing · not used", "2 accounts end in 4139 at Chase".
    static func detail(_ a: LearnedAccount, sharesEnding: Int, folderExists: Bool) -> String {
        if !folderExists { return "folder missing · not used" }
        var parts = ["taught " + a.taughtAt.formatted(.dateTime.month(.abbreviated).day()),
                     "\(a.filedCount) filed"]
        if sharesEnding > 1 { parts.append("\(sharesEnding) accounts end in \(a.ending) at \(a.institutionName); you choose each time") }
        return parts.joined(separator: " · ")
    }
}
