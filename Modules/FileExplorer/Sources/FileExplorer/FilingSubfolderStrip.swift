import Design
import SwiftUI
import Sync

/// The strip under To File's header about subfolders. Two cases:
/// - a folder with loose files and more in its subfolders (a Downloads full of unzipped folders):
///   "40 files in 6 subfolders aren't in this list", with Also Scan and Not Now;
/// - a scan that read the subfolders: says so, with Only This Folder to go back.
/// The folder with no loose files of its own gets the empty state's button instead.
struct FilingSubfolderStrip: View {
    enum Content: Equatable {
        case offer(FilingSubfolderOffer)
        case reading(folderName: String)

        init?(offer: FilingSubfolderOffer?, readSubfolders: Bool, folderName: String) {
            if readSubfolders { self = .reading(folderName: folderName); return }
            guard let offer, offer.hasLooseFiles else { return nil }
            self = .offer(offer)
        }
    }

    let content: Content
    let accent: Color
    let onScan: () -> Void
    let onDecline: () -> Void
    let onOnlyThisFolder: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
            switch content {
            case .offer(let offer):
                Text(FilingSubfolderText.alsoTitle(offer))
                    .scaledFont(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Not Now", action: onDecline)
                    .buttonStyle(.hoverAffordance(.inline))
                    .scaledFont(.system(size: 11))
                Button(FilingSubfolderText.alsoButton(offer), action: onScan)
                    .buttonStyle(.hoverAffordance(.inline))
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .help(FilingSubfolderText.help)
            case .reading(let name):
                Text(FilingSubfolderText.reading(folderName: name))
                    .scaledFont(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Only This Folder", action: onOnlyThisFolder)
                    .buttonStyle(.hoverAffordance(.inline))
                    .scaledFont(.system(size: 11))
                    .help("Scan only the files sitting directly in “\(name)”, as before.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(accent.opacity(0.10))
        .accessibilityElement(children: .contain)
    }
}

/// The words for the subfolder offer, kept apart so they can be read in tests.
enum FilingSubfolderText {
    static func emptyTitle(folderName: String) -> String { "No loose files in “\(folderName)”" }
    static func emptyMessage(_ offer: FilingSubfolderOffer) -> String {
        "\(offer.summary). Scan them to find homes for each one."
    }
    static func scanButton(_ offer: FilingSubfolderOffer) -> String {
        "Scan \(offer.files) File\(offer.files == 1 ? "" : "s") in Subfolders"
    }
    static func alsoTitle(_ offer: FilingSubfolderOffer) -> String {
        "\(offer.summary) \(offer.files == 1 ? "isn’t" : "aren’t") in this list."
    }
    static func alsoButton(_ offer: FilingSubfolderOffer) -> String {
        "Also Scan \(offer.files) in Subfolders"
    }
    static func reading(folderName: String) -> String { "Showing files in “\(folderName)” and its subfolders." }
    static let help = "Reads the files in this folder’s subfolders too. Subfolder names never decide a home on their own."
}
