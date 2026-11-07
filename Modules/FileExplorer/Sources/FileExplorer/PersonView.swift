import SwiftUI
import Design
import Sync

/// Everything that is one person's, grouped by why: the answer to "all of Daughter's files".
///
/// A find dims the tree to show where something sits; this gathers, because "what is theirs" is
/// spread across the source. Groups go in order of worth, not size: “In *name*’s folders” is the
/// tree's own filing, which he could reach by browsing; “Theirs, filed elsewhere” holds candidate
/// misfilings no browsing finds; then the rows waiting for review.
///
/// Nothing here moves a file: rows reveal, and a review row records a verdict. Takes the gather's
/// phase, not just its answer, because the sweep walks every surveyed document; the header (name
/// and the ✕) is common to every phase, so accepting an offer shows something dismissable at once.
public struct PersonView: View {
    let displayName: String
    let phase: PersonGatherPhase
    let accent: Color
    /// What the "<Name>’s" answer fills with under its white label: `accent` deepened, which is
    /// `LiquidGlassHue.accentFillColor` for its hue, the fill every other lit control takes.
    private var accentFill: Color { AccentFill.deepened(accent) }
    /// Reveals a folder in the pane. Folders, because that group's unit is the folder.
    let onOpenFolder: (String) -> Void
    /// Reveals one file in Finder.
    let onReveal: (String) -> Void
    let onClear: () -> Void
    /// Records a verdict on a review row: the path, and whether it is theirs.
    ///
    /// Never a move: confirming says whose a document is, and putting it somewhere is Organize's
    /// verb, so this closure has no destination.
    let onVerdict: (String, Bool) -> Void

    public init(displayName: String, phase: PersonGatherPhase, accent: Color,
                onOpenFolder: @escaping (String) -> Void,
                onReveal: @escaping (String) -> Void,
                onClear: @escaping () -> Void,
                onVerdict: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.displayName = displayName
        self.phase = phase
        self.accent = accent
        self.onOpenFolder = onOpenFolder
        self.onReveal = onReveal
        self.onClear = onClear
        self.onVerdict = onVerdict
    }

    /// How many folders are listed before the rest collapse into a count.
    ///
    /// One person can own well over a hundred folders, so the list stops somewhere. The remainder
    /// is stated, never dropped, or the list would misreport the answer.
    private static let folderLimit = 8

    /// The line under the list for the folders past ``folderLimit``. No "…": nothing opens from it.
    static func moreFolders(_ count: Int) -> String {
        count == 1 ? "1 more folder" : "\(count.formatted()) more folders"
    }

    /// How many review rows are shown before the rest collapse into a count.
    ///
    /// A page-1 mention is common, so one person's queue can run to hundreds of rows. The
    /// remainder is stated rather than dropped; verdicts stick, so working down the queue is kept.
    private static let reviewLimit = 12

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch phase {
            case .gathering:
                gatheringState
            case .failed(let reason):
                failedState(reason)
            case .ready(let files):
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if files.total == 0 && files.review.isEmpty {
                            emptyState
                        } else {
                            if !files.ownFolders.isEmpty { ownFoldersGroup(files) }
                            if !files.elsewhere.isEmpty { elsewhereGroup(files) }
                            if !files.review.isEmpty { reviewGroup(files) }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .scaledFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Text(displayName)
                .scaledFont(.system(size: 13, weight: .semibold))
            // The count is the whole set, not the rows on screen, since the folder list below is
            // truncated. Only once there is an answer: "0 files" mid-sweep would be wrong.
            if case .ready(let files) = phase {
                Text("\(files.total) file\(files.total == 1 ? "" : "s")")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.14)))
                // Separate from the count: the count is an answer, this an open question, and one
                // total would assert what the queue exists to ask.
                if !files.review.isEmpty {
                    Text("\(files.review.count) to review")
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(SemanticColor.warning.opacity(0.14)))
                }
            }
            Spacer(minLength: 8)
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help("Back to the plain pane (Esc)")
            .accessibilityLabel("Clear person scope")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Their own folders

    private func ownFoldersGroup(_ files: PersonFileSet) -> some View {
        let inFolders = files.ownFolders.reduce(0) { $0 + $1.files.count }
        return VStack(alignment: .leading, spacing: 7) {
            groupHeader(symbol: "house",
                        title: "In \(displayName)’s folders",
                        subtitle: "The tree’s own filing.",
                        amount: "\(inFolders) file\(inFolders == 1 ? "" : "s") · \(files.folderCount) folder\(files.folderCount == 1 ? "" : "s")")
            ForEach(files.ownFolders.prefix(Self.folderLimit), id: \.folder) { group in
                HStack(spacing: 10) {
                    Text(group.folder)
                        .scaledFont(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    Text("\(group.files.count)")
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Open") { onOpenFolder(group.folder) }
                        .buttonStyle(.plain)
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .chromeHover()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.30)))
            }
            if files.folderCount > Self.folderLimit {
                Text(Self.moreFolders(files.folderCount - Self.folderLimit))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 9)
            }
        }
    }

    // MARK: Filed elsewhere

    private func elsewhereGroup(_ files: PersonFileSet) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            groupHeader(symbol: "sparkles",
                        title: "Theirs, filed elsewhere",
                        subtitle: "Candidate misfilings — named for them, filed outside their folders.",
                        amount: "\(files.elsewhere.count) file\(files.elsewhere.count == 1 ? "" : "s")")
            ForEach(files.elsewhere) { file in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.path)
                            .scaledFont(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        // Why this row is here, in the row. A group heading that said "named for
                        // them" would leave each row asking which of their names did it.
                        Text(file.matchedForm.map { "named in the file — “\($0)”" } ?? "named in the file")
                            .scaledFont(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Reveal") { onReveal(file.path) }
                        .buttonStyle(.plain)
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .chromeHover()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.30)))
            }
        }
    }

    // MARK: Waiting for review

    /// The rows too weak to attribute on their own.
    ///
    /// Not claims: each row states only the evidence (the shared word and how many answer to it,
    /// or what page 1 read), because the user is being asked. The two buttons are yes and no, and
    /// no matters most: the channels are deterministic, so an unremembered refusal returns on every
    /// gather.
    private func reviewGroup(_ files: PersonFileSet) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            groupHeader(symbol: "questionmark.circle",
                        title: "Waiting for review",
                        subtitle: "Too weak to attribute on its own. Your answer is remembered.",
                        amount: "\(files.review.count) file\(files.review.count == 1 ? "" : "s")",
                        tint: SemanticColor.warning)
            ForEach(files.review.prefix(Self.reviewLimit)) { file in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.path)
                            .scaledFont(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(Self.caption(for: file, displayName: displayName))
                            .scaledFont(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Reveal") { onReveal(file.path) }
                        .buttonStyle(.plain)
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .chromeHover()
                    // The two answers are drawn as a pair of controls, filled and outlined, so the
                    // refusal reads as half the question, not a tertiary link beside Reveal.
                    //
                    // Filled by hand, not with `.borderedProminent`: that style renders unfilled in
                    // an offscreen host, so the fixture that proves this paints would read false.
                    Button { onVerdict(file.path, true) } label: {
                        Text("\(displayName)’s")
                            .scaledFont(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(accentFill))
                    }
                    .buttonStyle(.plain)
                    .chromeHover()
                    .help("Remember this file as \(displayName)’s — nothing is moved")
                    .accessibilityLabel("\(file.name) is \(displayName)’s")
                    Button { onVerdict(file.path, false) } label: {
                        Text("Not \(displayName)’s")
                            .scaledFont(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(Capsule().strokeBorder(.tertiary, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .chromeHover()
                    .help("Remember that this file isn’t \(displayName)’s — nothing is moved")
                    .accessibilityLabel("\(file.name) is not \(displayName)’s")
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.30)))
            }
            if files.review.count > Self.reviewLimit {
                Text("\(files.review.count - Self.reviewLimit) more waiting…")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 9)
            }
        }
    }

    /// What the row says the evidence is.
    ///
    /// Spelled out per reason, not one sentence with holes: "only the shared word *father*" and
    /// "page 1 reads *Granny Elder*" are different claims, and the user judges the evidence.
    static func caption(for file: PersonFile, displayName: String) -> String {
        switch file.reason {
        case .sharedWordInName(let word, let sharedWith):
            let others = sharedWith == 1 ? "1 other person answers to it"
                                         : "\(sharedWith) others answer to it"
            return "only the shared word “\(word)” in the name — \(others)"
        case .namedOnPageOnly(let form):
            return "page 1 reads “\(form)”, and names nobody else — but the file’s name says nothing"
        case nil:
            return "weak evidence"
        }
    }

    // MARK: Chrome

    private func groupHeader(symbol: String, title: String, subtitle: String,
                             amount: String, tint: Color? = nil) -> some View {
        let hue = tint ?? accent
        return HStack(spacing: 9) {
            Image(systemName: symbol)
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(hue)
                .frame(width: 21, height: 21)
                .background(RoundedRectangle(cornerRadius: Radius.chip).fill(hue.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).scaledFont(.system(size: 12.5, weight: .semibold))
                Text(subtitle).scaledFont(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(amount)
                .scaledFont(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(hue)
                .fixedSize()
        }
    }

    /// The sweep is running. Said in words as well as a spinner, so accepting the offer never
    /// looks like it did nothing.
    private var gatheringState: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Gathering \(displayName)’s files…")
                    .scaledFont(.system(size: 12.5, weight: .semibold))
                Text("Every surveyed document is being checked — folders that are theirs, "
                     + "and files named for them elsewhere.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The sweep could not run, and the slot says why, for as long as it is on screen.
    private func failedState(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(.system(size: 12, weight: .semibold))
                // The severity table, not a literal hue. `warning`, not `error`: the gather could
                // not run, but nothing was lost.
                .foregroundStyle(SemanticColor.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn’t gather \(displayName)’s files.")
                    .scaledFont(.system(size: 12.5, weight: .semibold))
                Text(reason)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Nobody's: an answer, not a failure. The surveyed tree holds nothing under their folders and
    /// nothing naming them strongly enough to be sure.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing filed under \(displayName).")
                .scaledFont(.system(size: 12.5, weight: .semibold))
            Text("No folder in the survey is theirs, and no file names them clearly enough to say "
                 + "so on its own.")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
