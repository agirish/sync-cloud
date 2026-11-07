import Design
import Foundation
import SwiftUI

/// What the reader decided about a file that changed under the buffer.
///
/// The alert's three answers, exactly (see `EditorAlerts.DivergenceAnswer` in the app target). No
/// fourth: the overlay is reached from that question and hands the same answer back, so it can
/// never become a second way of resolving a divergence the alert doesn't know about.
public enum EditorDivergenceVerdict: Equatable, Sendable {
    /// Overwrite what is on disk with the buffer.
    case saveAnyway
    /// Throw the buffer away and re-read the file.
    case reloadFromDisk
    /// Change nothing, and leave autosave stopped. What dismissing does: Escape, a click on the
    /// scrim, ⏎.
    case cancel
}

/// The two column headers over the diff.
///
/// A value, so the words can be asserted without mounting the overlay, and so one rule is stated
/// once: say only what can be known cheaply. This app can't know a file "changed on another
/// machine"; it can know when the bytes were last written, from the `mtime` the divergence check
/// already read.
enum EditorDivergenceColumns {

    /// `In Edit · 1,204 words`.
    ///
    /// The count is phrased by ``EditorDocumentFacts/count(_:_:)``, the same rule as the status
    /// line under the document, singular included.
    static func editor(words: Int) -> String {
        "\(editorLabel) · \(EditorDocumentFacts.count(words, "word"))"
    }

    /// `On disk · written 2 minutes ago`, or just `On disk` when the file has no modification date.
    ///
    /// No claim about where it was written: a sync client, another app, a script and another
    /// machine look the same from here, and "changed on another machine" is a guess a reader would
    /// act on. The age comes from ``ScanFreshness/spokenRelative(_:)``, the app's one relative-age
    /// vocabulary, in its words form because VoiceOver reads this caption as prose; its "just now"
    /// floor suits a file that changed seconds ago.
    static func disk(modified: Date?, now: Date) -> String {
        guard let modified else { return diskLabel }
        // A future mtime needs no guard: clock skew between machines is ordinary in shared folders,
        // and a negative interval falls into `spokenRelative`'s first bucket (`..<30`), "just now".
        // A `max(0, …)` clamp would change nothing for any input.
        return "\(diskLabel) · written \(ScanFreshness.spokenRelative(now.timeIntervalSince(modified)))"
    }

    /// What the two sides are called in the diff's refusals, when a side cannot be read at all.
    static let editorLabel = "In Edit"
    static let diskLabel = "On disk"
}

/// Show what changed, for a document whose file moved under it.
///
/// The alert asks which version wins without showing either. This shows both: the buffer on the
/// left, the file on disk on the right, the Compare workspace's line diff, and the same three verbs
/// at the foot, so the decision is made while looking at the difference.
///
/// Nothing here writes. The foot's Keep Mine… is the alert's answer, travelling back through
/// `onAnswer` to the one place in `ContentView+Editor` that acts on it. Dismissing (Escape, ⏎, a
/// click on the scrim) is `cancel`, exactly the alert's Cancel: change nothing, leave autosave
/// stopped. In-window, on the pair viewer's pattern, because the alert is already dismissed by the
/// time this shows, and a modal window over a modal is no way to show two columns of text.
public struct EditorDivergenceDiffOverlay: View {

    @ObservedObject private var document: EditorDocument
    private let now: () -> Date
    private let takingDiskIsUndoable: Bool
    private let onAnswer: (EditorDivergenceVerdict) -> Void

    /// `now` is injectable so a test can assert "written 2 minutes ago" without waiting two
    /// minutes.
    ///
    /// `takingDiskIsUndoable` is whether ⌘Z takes back Use Disk Version: true while the disk banner
    /// stands, where the host takes the disk version as an undoable step rather than reloading over
    /// the buffer. Only the tooltip reads it; the answer is the host's either way.
    public init(document: EditorDocument,
                now: @escaping () -> Date = Date.init,
                takingDiskIsUndoable: Bool = false,
                onAnswer: @escaping (EditorDivergenceVerdict) -> Void) {
        self.document = document
        self.now = now
        self.takingDiskIsUndoable = takingDiskIsUndoable
        self.onAnswer = onAnswer
    }

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var accent: Color { glassHue.accentColor }

    /// Everything one pass produced: the diff or the reason there is none, and the two column
    /// captions, computed in the same background pass because the word count walks a buffer that
    /// may be megabytes and the modification date is a `stat`.
    private struct Loaded: Sendable {
        var outcome: TextPairDiffPipeline.Outcome
        var editorCaption: String
        var diskCaption: String
    }

    @State private var loaded: Loaded?
    @State private var focusedRegion: Int?
    @State private var work: Task<Loaded, Never>?
    @FocusState private var focused: Bool

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                OverlayScrim(level: glassLevel)
                    .ignoresSafeArea()
                    // Clicking away is Cancel, like every other overlay; here that is a real
                    // answer, the safe one.
                    .onTapGesture { onAnswer(.cancel) }
                card(available: proxy.size)
                    // Absorb clicks on the card so they don't fall through to the scrim.
                    .contentShape(Rectangle())
                    .contentSurface(hue: glassHue, tint: surfaceTint)
                    .groundedGlassCard(level: glassLevel)
                    .overlayPanelShadow()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity)
    }

    private func card(available: CGSize) -> some View {
        let size = CompareOverlayMetrics.size(available: available)
        return VStack(spacing: 0) {
            header
            Divider()
            columnHeaders
            Divider()
            pane
            Divider()
            foot
        }
        .frame(width: size.width, height: size.height)
        // `.focusable()` makes the keys below work; `.focusEffectDisabled()` stops macOS ringing
        // the whole card, which reads as a stray highlight. Same as `CompareCopiesSheet`.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        // ⏎ and esc are `.onKeyPress`, never key equivalents. The editor's text view is still
        // mounted under the scrim, so a `.keyboardShortcut(.cancelAction)` would register a
        // window-level equivalent and eat bare esc and ⏎ typed anywhere in the window.
        // `BareKeyEquivalentScanTests` bans exactly that.
        //
        // Both keys answer `cancel` and nothing else: the other two verbs each discard something,
        // and a keystroke is no way to say which version of your work to throw away.
        .onKeyPress(keys: [.escape, .return, .keypadEnter], phases: .down) { press in
            guard press.isPlainKeystroke else { return .ignored }
            onAnswer(.cancel)
            return .handled
        }
        // ↑/↓ step between changes, with the compare pane stepper's rule and wrap.
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            guard press.isPlainKeystroke, let regions = loaded?.outcome.diff?.regions,
                  !regions.isEmpty else { return .ignored }
            focusedRegion = TextPairDiff.steppedRegion(from: focusedRegion,
                                                       direction: press.key == .downArrow ? 1 : -1,
                                                       count: regions.count)
            return .handled
        }
        .task(id: document.path) { await refresh() }
        // Work doesn't outlive the surface: a diff still running after the overlay has gone pins a
        // core for an answer nobody will see.
        .onDisappear { work?.cancel(); work = nil }
    }

    // MARK: The card

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .scaledFont(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(document.name)” changed on disk while you were typing")
                    .scaledFont(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The consequence, in the alert's own words: this replaces the alert on screen, so
                // the reader must still see what each verb costs.
                Text("Keeping your version replaces the one on disk, and the other changes are lost.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// `In Edit · 1,204 words` over the left column, `On disk · written 2 minutes ago` over the
    /// right, split down the middle so each sits over its side.
    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text(loaded?.editorCaption ?? EditorDivergenceColumns.editorLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(loaded?.diskCaption ?? EditorDivergenceColumns.diskLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaledFont(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// The rows, or the reason there are none: a refusal names which side and why, rather than an
    /// empty pane to guess at. Same shape as `CompareCopiesSheet.textDiffPane`.
    @ViewBuilder
    private var pane: some View {
        Group {
            if let diff = loaded?.outcome.diff {
                TextPairDiffView(diff: diff, notes: loaded?.outcome.notes ?? [], accent: accent,
                                 focusedRegion: $focusedRegion)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                    }
            } else {
                VStack(spacing: 8) {
                    if let notes = loaded?.outcome.notes, !notes.isEmpty {
                        ForEach(notes, id: \.self) { note in
                            Text(note)
                                .scaledFont(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What Use Disk Version's tooltip promises: that ⌘Z brings the typing back only where it does.
    static func useDiskVersionHelp(undoable: Bool) -> String {
        undoable ? "Take the version on the right — ⌘Z brings your version back."
            : "Take the version on the right and lose what you typed."
    }

    /// The same three verbs the alert offered, in the same order, in the banner's words
    /// (``EditorDiskVerbs``).
    ///
    /// Nothing here is `.borderedProminent`: two verbs discard something in opposite directions and
    /// the third resolves nothing, so there is none to recommend, and the app can't know which
    /// version of somebody's work matters.
    private var foot: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Cancel") { onAnswer(.cancel) }
                .buttonStyle(.bordered)
                // ⌥ shows esc, which answers Cancel here; ⏎ does too, but esc is the key every
                // other Cancel in the app wears.
                .shortcutKeycap("esc")
                .help("Change nothing. Autosave stays stopped until you settle this.")
            Button(role: .destructive) { onAnswer(.reloadFromDisk) } label: {
                Text(EditorDiskVerbs.useDiskVersion)
            }
            .buttonStyle(.bordered)
            .help(Self.useDiskVersionHelp(undoable: takingDiskIsUndoable))
            // Asks before it writes: the host's `applyDivergenceAnswer`, as from the banner.
            Button(role: .destructive) { onAnswer(.saveAnyway) } label: {
                Text(EditorDiskVerbs.keepMine)
            }
            .buttonStyle(.bordered)
            .help("Keep the version on the left and lose what arrived on disk.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Reading the two sides

    /// Reads the file, diffs it against the buffer, and composes the two captions, all off the main
    /// actor and cancellable.
    ///
    /// The left side is the buffer, never read from disk, unlike the compare pane: the question is
    /// what the unsaved text differs from. It goes to the pipeline as an already-read `.text`
    /// outcome with the document's encoding, so an encoding that changed under the buffer gets the
    /// same note as it would for two files.
    private func refresh() async {
        guard let path = document.path else { return }
        work?.cancel()
        let text = document.text
        let encoding = document.encoding ?? .utf8
        let asOf = now()
        let task = Task.detached(priority: .userInitiated) { () -> Loaded in
            let disk = BoundedTextRead.read(path: path)
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let outcome = TextPairDiffPipeline.diff(
                left: .text(text, lossy: false, encoding: encoding),
                right: disk,
                leftLabel: EditorDivergenceColumns.editorLabel,
                rightLabel: EditorDivergenceColumns.diskLabel,
                isCancelled: { Task.isCancelled })
            return Loaded(outcome: outcome,
                          editorCaption: EditorDivergenceColumns.editor(
                            words: EditorDocumentFacts.of(text, encoding: encoding.rawValue).words),
                          diskCaption: EditorDivergenceColumns.disk(modified: modified, now: asOf))
        }
        work = task
        let result = await task.value
        // A cancelled pass knows nothing about the pair and must land nowhere; see
        // ``TextPairDiffPipeline/Outcome``.
        guard !result.outcome.cancelled, !Task.isCancelled else { return }
        loaded = result
        focusedRegion = nil
    }
}
