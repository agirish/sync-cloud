import SwiftUI
import Sync

/// Ask Claude ▸ General ▸ New chats (TE347a): brings back the intro its ✕ hid.
public struct AskClaudeIntroSection: View {
    @AppStorage(AskClaudeIntro.shownKey) private var shown = true

    public init() {}

    public var body: some View {
        SettingsSection("New chats") {
            Toggle("Show the intro in new chats", isOn: $shown.loggingSettingsChange("intelligence.intro"))
                .help("Off, a new chat opens with its suggested questions only. The ✕ on the intro turns it off.")
        }
    }
}
