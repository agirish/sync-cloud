import Design
import SwiftUI

/// Any lens before its first run: what will happen, one trigger, and what a result looks like
/// (v4.0 polish P12 — the `FilingSetupCard` pattern, generalized).
///
/// To File's fresh state was the documented gold standard — top-anchored, the job and the
/// safety contract in the header, and **sample rows in the shape real results take**, which is
/// what makes the first real list legible. Every other lens opened as a centred icon and two
/// sentences. This is that card with the lens-specific parts injected: the words come from
/// ``LensIntros`` (one place, no drift), the trigger is the lens's own, and the samples are
/// whatever row shape the lens really draws — greyed and announced as a diagram, never as
/// findings about the user's disk.
///
/// **This replaces not-scanned states only.** A lens that ran and found nothing keeps its
/// earned terminal state (the seal, the full tray, "agrees with itself") — "never looked" and
/// "looked and found nothing" must not share a face.
struct LensSetupCard<Samples: View>: View {
    let intro: LensIntro
    let accent: Color
    let triggerTitle: String
    let triggerSymbol: String
    let triggerHelp: String
    /// "What a finding looks like" in the lens's own noun.
    let samplesTitle: String
    /// What VoiceOver says for the whole sample block — read row by row, invented names sound
    /// like real findings, which is the opposite of what they are.
    let samplesAccessibility: String
    /// What the trigger does — **nil withholds the button entirely.**
    ///
    /// Restructure is the lens that needs this: its input is a survey built outside the app, so
    /// on a machine that has one there is nothing here to press, and a prominent button wired to
    /// a no-op is worse than none. Every other lens's before-screen is one click from its answer
    /// and passes a real action.
    let onStart: (() -> Void)?
    /// A second, quieter action beside the trigger — **the refresh, when the trigger only
    /// reveals.**
    ///
    /// A lens whose answer already exists at launch (Restructure, off the folder survey) opens
    /// with a trigger that shows it rather than one that computes it. That leaves "and get a more
    /// current one" with nowhere to go, and the whole reason for opening on the card is to say
    /// out loud that these results are cached. So the pair is: reveal, and re-derive. nil on
    /// every lens whose trigger runs the scan itself, because there the two are the same button.
    var secondary: SecondaryAction? = nil

    struct SecondaryAction {
        let title: String
        let symbol: String
        let help: String
        let action: () -> Void
    }
    /// A lens-specific note that belongs on this screen but **must not sit above the header.**
    ///
    /// To File is the one lens with something to say before a scan that isn't part of the pitch:
    /// what the last cloud pass cost, and the button that opens the spend history. That row used
    /// to render above this card, inside the lens content and outside the card — which pushed To
    /// File's header down by its own height and left the one lens that has it opening lower than
    /// the other five. The card is the thing every lens is supposed to open the same way, so
    /// anything a single lens adds goes *under* it. `AnyView` deliberately, rather than a second
    /// generic parameter: it is one small row, and generifying it would rewrite every call site
    /// that has no footnote at all.
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

    /// The trigger row. One prominent button, and at most one quiet companion — both at
    /// `.large`, so a card that has a secondary is exactly as tall here as one that does not and
    /// the whole ladder below it stays put (`LensSetupCardAlignmentTests` measures that row).
    @ViewBuilder
    private var trigger: some View {
        if onStart != nil || secondary != nil {
            HStack(spacing: 10) {
                if let onStart {
                    Button(action: onStart) {
                        Label(triggerTitle, systemImage: triggerSymbol)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .chromeHover()
                    .help(triggerHelp)
                }
                if let secondary {
                    Button(action: secondary.action) {
                        Label(secondary.title, systemImage: secondary.symbol)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .chromeHover()
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

/// One greyed sample row in the shared diagram dress — callers compose their lens's row shape
/// inside. The wash and the whole-row fade are what make three of these read as a diagram
/// rather than as findings.
struct LensSetupSampleRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.secondary.opacity(0.06)))
        .opacity(0.72)
    }
}
