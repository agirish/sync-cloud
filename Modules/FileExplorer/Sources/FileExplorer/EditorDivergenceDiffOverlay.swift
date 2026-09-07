import Design
import Foundation
import SwiftUI

/// What the reader decided about a file that changed under the buffer.
///
/// **The alert's three answers, exactly** — see `EditorAlerts.DivergenceAnswer`, which is where the
/// same three live in the app target. There is deliberately no fourth: the overlay is reached *from*
/// that question and hands the same answer back, so this surface can never become a second way of
/// resolving a divergence that the alert does not know about.
public enum EditorDivergenceVerdict: Equatable, Sendable {
    /// Overwrite what is on disk with the buffer.
    case saveAnyway
    /// Throw the buffer away and re-read the file.
    case reloadFromDisk
    /// Change nothing, and leave autosave stopped. **What dismissing does** — Escape, a click on
    /// the scrim, ⏎.
    case cancel
}

/// The two column headers over the diff.
///
/// **A value, so the words can be asserted without mounting the overlay** — and so the one rule
/// worth stating is stated once: *say only what can be known cheaply*. It is tempting to write "on
/// disk · changed on another machine", and this app cannot know that. What it can know is when the
/// bytes were last written, from the same `mtime` the divergence check already read.
enum EditorDivergenceColumns {

    /// `In the editor · 1,204 words`.
    ///
    /// The count is phrased by ``EditorDocumentFacts/count(_:_:)``, the same rule the status line
    /// under the document uses — including its singular, which this line passes through on the way
    /// to everything else.
    static func editor(words: Int) -> String {
        "\(editorLabel) · \(EditorDocumentFacts.count(words, "word"))"
    }

    /// `On disk · written 2m ago`, or just `On disk` when the file has no modification date.
    ///
    /// **No claim about WHERE it was written.** A sync client, another app on this Mac, a script,
    /// and another machine are indistinguishable from here, and "changed on another machine" is the
    /// guess a reader would act on. The age comes from ``ScanFreshness/relative(_:)`` rather than a
    /// second ladder of buckets — it is the app's one relative-age vocabulary, already tested, and
    /// its floor ("0s ago") is right here too: the interesting case for this overlay is a file that
    /// changed seconds ago.
    static func disk(modified: Date?, now: Date) -> String {
        guard let modified else { return diskLabel }
        // **A future modification date is not guarded against here, because it does not need to
        // be.** A clock skew between machines is ordinary in exactly the shared folders this
        // overlay is about, so a file can carry an mtime ahead of now — and `relative`'s first
        // bucket is `..<30`, which a negative interval falls into: it answers "0s ago". A
        // `max(0, …)` here was written first and then measured, and it changed nothing for any
        // input; a redundant clamp is a rule no test can hold, so it went and this comment stayed.
        return "\(diskLabel) · written \(ScanFreshness.relative(now.timeIntervalSince(modified)))"
    }

    /// What the two sides are called in the diff's refusals, when a side cannot be read at all.
    static let editorLabel = "In the editor"
    static let diskLabel = "On disk"
}

/// **Show what changed**, for a document whose file moved under it.
///
/// The reader has been asked which version wins by a modal alert that shows them neither version.
/// This is the answer to that: the buffer on the left, the file on disk on the right, the same
/// line diff the Compare workspace draws, and the same three verbs at the foot so the decision is
/// made while looking at the difference.
///
/// **Nothing here writes.** The foot's Save Anyway is the alert's Save Anyway — the identical
/// answer travelling back through `onAnswer` to the one place in `ContentView+Editor` that acts on
/// it — not a second write path. Dismissing (Escape, ⏎, a click on the scrim) is `cancel`, which is
/// exactly what the alert's Cancel does: change nothing, and leave autosave stopped.
///
/// **In-window, on the pair viewer's pattern**, not a second window and not an `NSAlert` with a
/// custom view: the alert has already been dismissed by the time this is on screen, and a modal
/// window over a modal window is not a thing to build to show somebody two columns of text.
public struct EditorDivergenceDiffOverlay: View {

    @ObservedObject private var document: EditorDocument
    private let now: () -> Date
    private let onAnswer: (EditorDivergenceVerdict) -> Void

    /// `now` is injectable for the reason every clock in this repo is: "written 2m ago" is a claim
    /// about a duration, and a test that had to wait two minutes to assert it would not be written.
    public init(document: EditorDocument,
                now: @escaping () -> Date = Date.init,
                onAnswer: @escaping (EditorDivergenceVerdict) -> Void) {
        self.document = document
        self.now = now
        self.onAnswer = onAnswer
    }

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var accent: Color { glassHue.accentColor }

    /// Everything one pass produced: the diff or the reason there is none, and the two column
    /// captions — which are computed in the same background pass, because the word count is an
    /// O(characters) walk of a buffer that may be megabytes and the modification date is a `stat`.
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
                Rectangle()
                    .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                    .ignoresSafeArea()
                    // Clicking away is Cancel, like every other overlay — and here that is not
                    // merely a dismissal but a real answer, the safe one.
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
        // `.focusable()` is what makes the keys below work; `.focusEffectDisabled()` stops macOS
        // painting a focus ring around the whole card, which reads as a stray highlight. Same
        // bargain `CompareCopiesSheet` strikes.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        // **⏎ and esc are `.onKeyPress`, never key equivalents.** This is an in-window overlay: the
        // editor's text view is still mounted under the scrim, so a `.keyboardShortcut(.cancelAction)`
        // here would register a WINDOW-level equivalent and eat bare esc and bare ⏎ typed anywhere
        // in the window, on key repeat. `BareKeyEquivalentScanTests` bans exactly that.
        //
        // **Both keys answer `cancel`, and neither answers anything else.** The two other verbs each
        // discard something, and a keystroke is not how somebody says which version of their work to
        // throw away.
        .onKeyPress(keys: [.escape, .return, .keypadEnter], phases: .down) { press in
            guard press.isPlainKeystroke else { return .ignored }
            onAnswer(.cancel)
            return .handled
        }
        // ↑/↓ step between changes, the same rule and the same wrap the compare pane's stepper uses.
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            guard press.isPlainKeystroke, let regions = loaded?.outcome.diff?.regions,
                  !regions.isEmpty else { return .ignored }
            focusedRegion = TextPairDiff.steppedRegion(from: focusedRegion,
                                                       direction: press.key == .downArrow ? 1 : -1,
                                                       count: regions.count)
            return .handled
        }
        .task(id: document.path) { await refresh() }
        // **Work does not outlive the surface.** The walk is bounded but not instant, and a diff
        // still running for an overlay that has gone is a pinned core for an answer nobody will see.
        .onDisappear { work?.cancel(); work = nil }
    }

    // MARK: The card

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .scaledFont(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(document.name)” changed on disk since you opened it")
                    .scaledFont(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // **The consequence, in the alert's own words.** This overlay replaces the alert on
                // screen, so dropping the sentence that says what each verb costs would mean the
                // decision is made with less in front of the reader than before, not more.
                Text("Saving replaces what's on disk with what's in the editor, and the other changes are lost.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// `In the editor · 1,204 words` over the left column, `On disk · written 2m ago` over the
    /// right — split down the middle so each sits over the side it describes.
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

    /// The rows, or the reason there are none — a refusal names WHICH side and why, rather than an
    /// empty pane the reader has to guess at. The same shape `CompareCopiesSheet.textDiffPane` uses.
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

    /// **The same three verbs the alert offered, in the same order.**
    ///
    /// Nothing here is `.borderedProminent`, and that is the point of the surface: two of the three
    /// discard something in opposite directions and the third resolves nothing, so there is no verb
    /// to recommend. A prominent button would be a recommendation, made by an app that cannot know
    /// which version of somebody's work matters.
    private var foot: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Cancel") { onAnswer(.cancel) }
                .buttonStyle(.bordered)
                .help("Change nothing. Autosave stays stopped until you settle this.")
            Button(role: .destructive) { onAnswer(.reloadFromDisk) } label: {
                Text("Reload from Disk")
            }
            .buttonStyle(.bordered)
            .help("Take the version on the right and lose what you typed.")
            Button(role: .destructive) { onAnswer(.saveAnyway) } label: {
                Text("Save Anyway")
            }
            .buttonStyle(.bordered)
            .help("Keep the version on the left and lose what arrived on disk.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Reading the two sides

    /// Reads the file, diffs it against the buffer, and composes the two captions — all off the
    /// main actor, and all cancellable.
    ///
    /// **The left side is the buffer and is never read from disk**, which is the whole difference
    /// from the compare pane: the question is what the *unsaved* text differs from. It is handed to
    /// the pipeline as an already-read `.text` outcome carrying the encoding the document was opened
    /// in, so an encoding that changed under the buffer is reported by the same note that reports it
    /// for two files.
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
        // A cancelled pass knows nothing about the pair and must land nowhere — see
        // ``TextPairDiffPipeline/Outcome``.
        guard !result.outcome.cancelled, !Task.isCancelled else { return }
        loaded = result
        focusedRegion = nil
    }
}
