import Design
import SwiftUI

/// "Remember ••7863 for next time" under a card's actions (decision 8): what Choose a Folder…
/// teaches, shown before the click. On for a group card, off for a single file; a card whose page
/// prints no number says there is nothing to remember.
struct FilingRememberAccount {
    /// The ending the filing would teach; nil when page 1 prints none.
    let ending: String?
    let isOn: Bool
    let onToggle: (Bool) -> Void
}

struct FilingRememberAccountRow: View {
    let remember: FilingRememberAccount

    var body: some View {
        if let ending = remember.ending {
            Toggle(isOn: Binding(get: { remember.isOn }, set: remember.onToggle)) {
                Text("Remember ••\(ending) where I choose")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Choose a Folder… files statements printing ••\(ending) there from now on. Listed in Automations, where you can remove it.")
        } else {
            Text("Nothing to remember: no account number on page 1")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}
