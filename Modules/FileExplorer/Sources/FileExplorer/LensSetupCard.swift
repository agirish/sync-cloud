import Design
import SwiftUI

/// Any lens before its first run: what will happen, one trigger, and what a result looks like.
/// The ``FilingSetupCard`` pattern, generalised.
///
/// Top-anchored, with the job and safety contract in the header (words from ``LensIntros``) and
/// sample rows in the shape the lens's real results take, so the first real list is legible. The
/// samples are greyed and announced as a diagram, never as findings about the user's disk.
///
/// For not-scanned states only. A lens that ran and found nothing keeps its own terminal state
/// (the seal, the full tray, "agrees with itself"): "never looked" and "looked and found nothing"
/// must not look the same.
struct LensSetupCard<Samples: View>: View {
    let intro: LensIntro
    let accent: Color
    let triggerTitle: String
    let triggerSymbol: String
    let triggerHelp: String
    /// "What a finding looks like" in the lens's own noun.
    let samplesTitle: String
    /// What VoiceOver says for the whole sample block. Read row by row, invented names would sound
    /// like real findings.
    let samplesAccessibility: String
    /// What the trigger does; nil withholds the button entirely.
    ///
    /// For Restructure, whose input is a survey built outside the app: where there is none, there
    /// is nothing to press, and a prominent button wired to a no-op is worse than none.
    let onStart: (() -> Void)?
    /// A second, quieter action beside the trigger: the refresh, when the trigger only reveals.
    ///
    /// A lens whose answer exists at launch (Restructure, off the folder survey) has a trigger that
    /// shows the cached result, so re-deriving needs a button of its own. nil wherever the trigger
    /// runs the scan itself.
    var secondary: SecondaryAction? = nil

    struct SecondaryAction {
        let title: String
        let symbol: String
        let help: String
        let action: () -> Void
        /// The action is already running: the button goes disabled with a spinner rather than
        /// accepting presses the engine would refuse. Set by Restructure's slow survey re-derive.
        var isBusy: Bool = false
    }
    /// A lens-specific note for this screen, which **must not sit above the header**: every lens
    /// opens with its header at the same height, so anything one lens adds goes under the card. Restructure
    /// uses it for its no-survey note.
    ///
    /// `AnyView` rather than a second generic parameter, so call sites with no footnote stay as
    /// they are.
    var footnote: AnyView? = nil
    @ViewBuilder let samples: () -> Samples

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                trigger
                sampleSection
                footnote
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 24)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: intro.icon)
                .scaledFont(.system(size: 27))
                .foregroundStyle(accent)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(intro.title)
                    .scaledFont(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(intro.message)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(intro.safety)
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The trigger row: one prominent button and at most one quiet companion, both `.large`, so a
    /// card with a secondary is as tall as one without and everything below stays put
    /// (`LensSetupCardAlignmentTests` measures it).
    @ViewBuilder
    private var trigger: some View {
        if onStart != nil || secondary != nil {
            HStack(spacing: 10) {
                if let onStart {
                    Button(action: onStart) {
                        Label(triggerTitle, systemImage: triggerSymbol)
                    }
                    .buttonStyle(.borderedProminent)
                    .accentedProminent()
                    .controlSize(.large)
                    .chromeHover()
                    .help(triggerHelp)
                }
                if let secondary {
                    Button(action: secondary.action) {
                        // The spinner takes the symbol's place, so the button keeps its width and
                        // the row doesn't reflow mid-press.
                        if secondary.isBusy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(secondary.title)
                            }
                        } else {
                            Label(secondary.title, systemImage: secondary.symbol)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .chromeHover()
                    .disabled(secondary.isBusy)
                    .help(secondary.help)
                }
            }
        }
    }

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(samplesTitle)
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            VStack(spacing: 4) {
                samples()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(samplesAccessibility)
        }
    }
}

/// One greyed sample row in the shared diagram dress; callers compose their lens's row shape
/// inside. The wash and the fade make the rows read as a diagram, not as findings.
struct LensSetupSampleRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
            .fill(Color.secondary.opacity(0.06)))
        .opacity(0.72)
    }
}
