import Design
import SwiftUI
import Sync

/// "Also copied to Roth IRA 4657" on a card whose statement names several accounts (decision 11),
/// with File Once Here: this time, or from now on for an account, the bank, or every statement.
struct FilingCopiesRow: View {
    let copies: [FilingCopy]
    /// nil scope: just this time.
    let onFileOnce: (FilingPreference.Scope?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc").scaledFont(.system(size: 11)).foregroundStyle(.secondary)
            Text(FilingCopiesText.line(copies))
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Menu {
                Button("Just This Time") { onFileOnce(nil) }
                Divider()
                ForEach(copies, id: \.account.root) { c in
                    Button("Always for \(FilingCopiesText.accountName(c)) ••\(c.account.ending)") {
                        onFileOnce(.account(institution: c.account.institution, ending: c.account.ending))
                    }
                }
                if let bank = copies.first?.account {
                    Button("Always for \(bank.institutionName.isEmpty ? bank.institution : bank.institutionName)") {
                        onFileOnce(.institution(bank.institution))
                    }
                }
                Button("Always for Statements") { onFileOnce(.statements) }
            } label: {
                Text("File Once Here").scaledFont(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("File it only in the first account, without the copies; choose whether to do so from now on")
            .lockedDuringRun()
        }
    }
}

enum FilingCopiesText {
    /// "Also copied to Roth IRA 4657", "Also copied to Roth IRA 4657 and HSA 0012".
    static func line(_ copies: [FilingCopy]) -> String {
        let names = copies.map { accountName($0) }
        return "Also copied to " + ListFormatter.localizedString(byJoining: names)
    }

    static func accountName(_ c: FilingCopy) -> String { (c.account.root as NSString).lastPathComponent }

    /// "Fidelity ••4657", "Fidelity", "statements", "everything", for a preference's row.
    static func label(_ scope: FilingPreference.Scope, copies: [FilingCopy]) -> String {
        switch scope {
        case .account(let institution, let ending):
            let c = copies.first { $0.account.institution == institution && $0.account.ending == ending }
            return (c.map { $0.account.institutionName.isEmpty ? institution : $0.account.institutionName } ?? institution) + " ••" + ending
        case .institution(let institution):
            return copies.first { $0.account.institution == institution }.map {
                $0.account.institutionName.isEmpty ? institution : $0.account.institutionName
            } ?? institution
        case .statements: return "statements"
        case .all: return "everything"
        }
    }
}

/// Automations ▸ Preferences: copy or file once, per scope, with Remove.
struct FilingPreferencesSection: View {
    @ObservedObject var syncManager: FileSyncManager
    let densityMetrics: ListDensityMetrics

    var body: some View {
        let preferences = syncManager.filingPreferences
        if !preferences.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Statements That Name Several Accounts")
                    .scaledFont(.system(size: 13, weight: .semibold))
                ForEach(preferences) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(p.copies ? "Copy into each account" : "File once") · \(p.label)")
                            .scaledFont(.system(size: 12))
                        Spacer(minLength: 8)
                        Button("Remove") { syncManager.removeFilingPreference(id: p.id) }
                            .controlSize(.small)
                            .help("Forget this preference; such statements are copied into each account again")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, densityMetrics.cardHeaderVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lensCard()
        }
    }
}
