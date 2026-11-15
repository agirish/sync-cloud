import Design
import SwiftUI
import Sync

/// "Scan TODO’s subfolders too?": To File's body while a scan waits for the answer, in place of the
/// list, so nothing is scanned until the person chooses. Laid out like ``LensSetupCard``, with the
/// buttons under the text and stacked when the column is narrow (the Ask Claude column is ~340 pt).
///
/// The checkbox only qualifies Scan All: ticked, "Only the 1 in TODO" is disabled, since always
/// scanning subfolders and scanning only this folder can't both be the answer. Not Now (a folder
/// with no loose files of its own) stays available and sets nothing.
struct FilingSubfolderQuestionCard: View {
    let question: FilingSubfolderQuestion
    let accent: Color
    let onScanAll: (_ always: Bool) -> Void
    let onFolderOnly: () -> Void
    let onNotNow: () -> Void

    @State private var always = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                buttons
                Toggle(FilingSubfolderText.alwaysToggle, isOn: $always)
                    .toggleStyle(.checkbox)
                    .scaledFont(.callout)
                    .help(FilingSubfolderText.alwaysHelp)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 24)
            // One question: VoiceOver names the card by it, then reads its text and controls.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(FilingSubfolderText.title(question))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "folder.badge.questionmark")
                .scaledFont(.system(size: 27))
                .foregroundStyle(accent)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(FilingSubfolderText.title(question))
                    .scaledFont(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(FilingSubfolderText.message(question))
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        FilingSubfolderQuestionButtons(question: question, always: always,
                                       onScanAll: { onScanAll(always) },
                                       onFolderOnly: onFolderOnly, onNotNow: onNotNow)
    }
}

/// The card's two buttons: side by side where they fit, stacked where they don't. Its own view so
/// tests can measure which arrangement a width gets.
struct FilingSubfolderQuestionButtons: View {
    let question: FilingSubfolderQuestion
    let always: Bool
    let onScanAll: () -> Void
    let onFolderOnly: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { scanAllButton; secondButton }
            VStack(alignment: .leading, spacing: 8) { scanAllButton; secondButton }
        }
    }

    private var scanAllButton: some View {
        Button(action: onScanAll) {
            Text(FilingSubfolderText.scanAll(question))
        }
        .buttonStyle(.borderedProminent)
        .accentedProminent()
        .controlSize(.large)
        .chromeHover()
        .help(FilingSubfolderText.scanAllHelp)
    }

    @ViewBuilder
    private var secondButton: some View {
        if question.looseFiles > 0 {
            Button(FilingSubfolderText.folderOnly(question), action: onFolderOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .chromeHover()
                .disabled(always)
                .help(always ? FilingSubfolderText.folderOnlyDisabledHelp
                             : FilingSubfolderText.folderOnlyHelp(question))
        } else {
            Button("Not Now", action: onNotNow)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .chromeHover()
                .help("Scan nothing for now.")
        }
    }
}

/// The question's words, kept apart so tests can read them.
enum FilingSubfolderText {
    /// "Scan TODO’s subfolders too?", or without "too" when the folder holds nothing itself.
    static func title(_ q: FilingSubfolderQuestion) -> String {
        "Scan \(possessive(q.folderName)) subfolders\(q.looseFiles > 0 ? " too" : "")?"
    }

    /// "1 file sits in TODO itself. 256 more are in 42 subfolders: Finance › Charles Schwab, Chase,
    /// Bank of America and 6 more."
    static func message(_ q: FilingSubfolderQuestion) -> String {
        let name = q.folderName
        let here: String
        switch q.looseFiles {
        case 0: here = "Nothing sits in \(name) itself."
        case 1: here = "1 file sits in \(name) itself."
        default: here = "\(q.looseFiles.formatted()) files sit in \(name) itself."
        }
        let noun = q.looseFiles > 0 ? "more" : (q.files == 1 ? "file" : "files")
        let verb = q.files == 1 && !q.atLeast ? "is" : "are"
        // Past the walk's cap the counts are floors: "at least", and no folder count to vouch for.
        let below = q.atLeast
            ? "At least \(q.files.formatted()) \(noun) are in its subfolders"
            : "\(q.files.formatted()) \(noun) \(verb) in \(q.folders.formatted()) subfolder\(q.folders == 1 ? "" : "s")"
        let whereabouts = groups(q).map { ": \($0)" } ?? ""
        return "\(here) \(below)\(whereabouts)."
    }

    /// "Finance › Charles Schwab, Chase, Bank of America and 6 more", nil with nothing to name.
    static func groups(_ q: FilingSubfolderQuestion) -> String? {
        var names = q.largestGroups
        if q.otherGroups > 0 { names.append("\(q.otherGroups.formatted()) more") }
        let list: String
        switch names.count {
        case 0: list = ""
        case 1: list = names[0]
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let parts = q.commonPath + (list.isEmpty ? [] : [list])
        return parts.isEmpty ? nil : parts.joined(separator: " › ")
    }

    static func scanAll(_ q: FilingSubfolderQuestion) -> String {
        q.atLeast ? "Scan All Files" : "Scan All \(q.total.formatted()) File\(q.total == 1 ? "" : "s")"
    }

    static func folderOnly(_ q: FilingSubfolderQuestion) -> String {
        "Only the \(q.looseFiles.formatted()) in \(q.folderName)"
    }

    static func folderOnlyHelp(_ q: FilingSubfolderQuestion) -> String {
        "Scan only the files sitting directly in “\(q.folderName)”."
    }

    static let folderOnlyDisabledHelp = "Untick “Always scan subfolders” to scan only this folder."
    static let scanAllHelp = "Reads the files in this folder’s subfolders too. Subfolder names never decide a home on their own."
    static let alwaysToggle = "Always scan subfolders"
    static let alwaysHelp = "Scan All without asking from now on, for folders where files wait, like TODO or Downloads. "
        + "Turn it off from the Rescan menu or Settings ▸ Organize ▸ To File."

    /// "TODO’s", "Downloads’".
    static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? "\(name)’" : "\(name)’s"
    }
}
