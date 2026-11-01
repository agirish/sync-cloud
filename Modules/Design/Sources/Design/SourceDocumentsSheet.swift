import SwiftUI

/// What Read Documents would do for a source's own survey (Google Drive's, say), counted before the
/// sheet opens — loose values, since `Design` sits under `Sync` (see ``ComparePrompt``).
public struct SourceDocumentsFacts: Equatable, Sendable {
    /// "Google Drive".
    public let sourceName: String
    /// Documents the reading opens — page 1 of each.
    public let documents: Int
    /// Of those, the ones whose content is in the cloud only and downloads first.
    public let toDownload: Int
    /// Word, Excel and PowerPoint files, which are never read.
    public let unreadableTypes: Int
    /// Documents an earlier, stopped reading already read, which carrying on skips.
    public let alreadyRead: Int?

    public init(sourceName: String, documents: Int, toDownload: Int, unreadableTypes: Int, alreadyRead: Int? = nil) {
        self.sourceName = sourceName
        self.documents = documents
        self.toDownload = toDownload
        self.unreadableTypes = unreadableTypes
        self.alreadyRead = alreadyRead
    }
}

/// The sheet's words (mockup 52b6b1ed, 2026-10-31), as static functions a test can read.
public enum SourceDocumentsText {

    static func possessive(_ name: String) -> String { name.hasSuffix("s") ? name + "’" : name + "’s" }

    public static func title(_ facts: SourceDocumentsFacts) -> String {
        "Read \(possessive(facts.sourceName)) documents?"
    }

    public static func lead(_ facts: SourceDocumentsFacts) -> String {
        let count = facts.documents == 1 ? "1 document" : "\(facts.documents.formatted()) documents"
        return "To File reads page 1 of \(count) to learn what each folder holds."
    }

    /// The points under the lead: what downloads, what is skipped, and what it costs.
    public static func points(_ facts: SourceDocumentsFacts) -> [String] {
        var points: [String] = []
        switch facts.toDownload {
        case 0: points.append("Every one is on this Mac already, so nothing downloads.")
        case 1: points.append("1 is in the cloud only. It downloads first and stays on this Mac.")
        default:
            points.append("\(facts.toDownload.formatted()) are in the cloud only. They download first and "
                          + "stay on this Mac.")
        }
        if facts.unreadableTypes > 0 {
            points.append("\(facts.unreadableTypes.formatted()) Word, Excel and PowerPoint "
                          + "file\(facts.unreadableTypes == 1 ? "" : "s") can’t be read.")
        }
        if let done = facts.alreadyRead, done > 0 {
            points.append("\(done.formatted()) were read before it stopped. Carrying on reads only the rest.")
        }
        let left = max(0, facts.documents - (facts.alreadyRead ?? 0))
        points.append(DocumentSurveyCost.duration(documents: left)
            + (facts.toDownload > 0 ? " plus downloads" : "")
            + ", in the background. It pauses while other scans run and picks up where it stopped after a quit.")
        return points
    }

    public static let readButton = "Read Documents"
}

/// The confirmation Read Documents asks before it starts — from To File's survey menu and from
/// Settings ▸ Organize ▸ Folder surveys alike.
public struct SourceDocumentsSheet: View {
    let facts: SourceDocumentsFacts
    let onCancel: () -> Void
    let onRead: () -> Void

    public init(facts: SourceDocumentsFacts, onCancel: @escaping () -> Void, onRead: @escaping () -> Void) {
        self.facts = facts
        self.onCancel = onCancel
        self.onRead = onRead
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SourceDocumentsText.title(facts))
                .scaledFont(.headline)
            Text(SourceDocumentsText.lead(facts))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SourceDocumentsText.points(facts), id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(point).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(SourceDocumentsText.readButton, action: onRead)
                    .keyboardShortcut(.defaultAction)
                    .accentedProminent()
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
