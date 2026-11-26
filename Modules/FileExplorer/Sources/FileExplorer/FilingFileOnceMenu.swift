import Design
import SwiftUI
import Sync

/// File Once Here: file it only in the first account, without the copies, this time or from now
/// on for an account, the bank, or every statement. Beside a card's File button, where its route
/// already says "Copies to".
struct FilingFileOnceMenu: View {
    let copies: [FilingCopy]
    /// nil scope: just this time.
    let onFileOnce: (FilingPreference.Scope?) -> Void

    var body: some View {
        Menu {
            Button("Just This Time") { onFileOnce(nil) }
            Divider()
            ForEach(copies, id: \.account.root) { c in
                Button("Always for " + FilingCopiesText.accountLabel(c)) {
                    onFileOnce(.account(institution: c.account.institution, ending: c.account.ending))
                }
            }
            if let bank = copies.first?.account {
                let bankName = FilingCopiesText.label(.institution(bank.institution), copies: copies)
                Button("Always for \(bankName)") {
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

enum FilingCopiesText {
    static func accountName(_ c: FilingCopy) -> String { (c.account.root as NSString).lastPathComponent }

    /// "Roth IRA 5442", or "Roth IRA ••5442" when the folder's name doesn't carry the number.
    static func accountLabel(_ c: FilingCopy) -> String {
        let name = accountName(c)
        return name.contains(c.account.ending) ? name : name + " ••" + c.account.ending
    }

    /// "Fidelity ••5442", "Fidelity", "statements", "everything", for a preference's row.
    static func label(_ scope: FilingPreference.Scope, copies: [FilingCopy]) -> String {
        // The bank as its folder spells it, else its name in title case: never the lower-case key.
        func bank(_ institution: String) -> String {
            copies.first { $0.account.institution == institution && !$0.account.institutionName.isEmpty }?.account.institutionName
                ?? institution.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        switch scope {
        case .account(let institution, let ending):
            return bank(institution) + " ••" + ending
        case .institution(let institution):
            return bank(institution)
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
                            .accessibilityLabel("Remove the preference for \(p.label)")
                            .help("Forget this preference")
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
