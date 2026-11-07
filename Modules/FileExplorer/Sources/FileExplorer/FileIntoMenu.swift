import SwiftUI
import Design

/// Where To File suggests homes, and the choices for changing it.
///
/// Built by the host, which knows the sources, the folder survey and what was stored; this file
/// only draws it. `path` is what the next scan files into — ``FilingDestinationRoot`` decides it.
public struct FileIntoChoice {
    public struct Option: Identifiable {
        public var id: String { path }
        public let path: String
        public let label: String
        public init(path: String, label: String) {
            self.path = path
            self.label = label
        }
    }

    /// The folder the next scan files into.
    public let path: String
    /// Its name in the menu's title — "Documents (iCloud)".
    public let label: String
    /// The folder survey's root, when there is one: listed first, under its own heading.
    public let survey: Option?
    /// Each source's own anchor, other than the survey's.
    public let sources: [Option]
    public let onPick: (String) -> Void
    public let onChooseOther: () -> Void

    public init(path: String, label: String, survey: Option?, sources: [Option],
                onPick: @escaping (String) -> Void, onChooseOther: @escaping () -> Void) {
        self.path = path
        self.label = label
        self.survey = survey
        self.sources = sources
        self.onPick = onPick
        self.onChooseOther = onChooseOther
    }
}

/// "File into Documents (iCloud) ▾" — on To File's readout row.
struct FileIntoMenu: View {
    let choice: FileIntoChoice

    var body: some View {
        HStack(spacing: 4) {
            Text("File into")
                .scaledFont(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize()
            Menu {
                if let survey = choice.survey {
                    Section("Your Folder Survey") { item(survey) }
                }
                if !choice.sources.isEmpty {
                    Section("Sources") {
                        ForEach(choice.sources) { item($0) }
                    }
                }
                Divider()
                Button("Choose Folder…", action: choice.onChooseOther)
            } label: {
                Text(choice.label)
                    .scaledFont(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Where To File suggests homes for these loose files. Changing it scans again.")
            .accessibilityLabel("File into \(choice.label)")
        }
    }

    @ViewBuilder
    private func item(_ option: FileIntoChoice.Option) -> some View {
        Button { choice.onPick(option.path) } label: {
            if option.path == choice.path {
                Label(option.label, systemImage: "checkmark")
            } else {
                Text(option.label)
            }
        }
    }
}
