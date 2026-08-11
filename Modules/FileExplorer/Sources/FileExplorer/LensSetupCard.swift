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
    let onStart: () -> Void
    @ViewBuilder let samples: () -> Samples

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                trigger
                sampleSection
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

    private var trigger: some View {
        Button(action: onStart) {
            Label(triggerTitle, systemImage: triggerSymbol)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .chromeHover()
        .help(triggerHelp)
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
