import SwiftUI
import Sync

/// Ask Claude ▸ General ▸ Suggestions (TE309): the switch for the chip above the text box, and
/// the kinds turned off from the chip's “Don’t Suggest …”, each with Suggest Again. One
/// self-contained section, so it can move with the page.
public struct AskClaudeSuggestionsSection: View {
    @AppStorage(AskClaudeSuggestions.enabledKey) private var enabled = true
    @AppStorage(AskClaudeSuggestions.memoryKey) private var memoryData = Data()

    static let caption = "A chip above Ask Claude’s text box when there’s something it could help with, such as new files in Downloads. Worked out on this Mac; nothing is sent to Claude until you click one."

    public init() {}

    private var memory: AskClaudeSuggestions.Memory {
        (try? JSONDecoder().decode(AskClaudeSuggestions.Memory.self, from: memoryData)) ?? .init()
    }

    public var body: some View {
        SettingsSection("Suggestions", caption: Self.caption) {
            Toggle("Show suggestions above the text box", isOn: $enabled)
                .help("Off, Ask Claude shows no suggestion chips.")
            let off = AskClaudeSuggestions.Kind.allCases.filter { memory.off.contains($0) }
            ForEach(off, id: \.self) { kind in
                HStack {
                    Text("Not suggested: \(kind.title)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Suggest Again") {
                        var memory = memory
                        memory.off.remove(kind)
                        if let data = try? JSONEncoder().encode(memory) { memoryData = data }
                    }
                    .disabled(!enabled)
                }
            }
        }
    }
}
