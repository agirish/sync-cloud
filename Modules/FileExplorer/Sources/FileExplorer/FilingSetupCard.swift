import Design
import SwiftUI

/// Organize ▸ To File before its first run: what will happen and what it looks like.
///
/// A ``LensSetupCard`` with To File's own parts (its trigger and sample rows), so every lens's
/// fresh state shares one layout. The trigger shows no price: the scan is free
/// (`FilingClassifierTier.free`), and the paid Refine pass's cost goes in the `footnote`.
///
/// The sample rows show the layout before a real run asks the user to judge proposed moves. They
/// are inert and greyed, and the third makes "no confident home" familiar rather than a surprise.
/// The words come from ``LensIntros/organize(scanTargetName:)``, as the pre-scan empty state's do.
struct FilingSetupCard: View {
    let intro: LensIntro
    let accent: Color
    /// The spend row, when this machine has cloud scans on record. Under the card — see
    /// ``LensSetupCard/footnote`` for why it is not above it.
    var footnote: AnyView? = nil
    let onStart: () -> Void

    var body: some View {
        // One body for every lens's fresh state, so To File can't open a few points off the rest.
        LensSetupCard(
            intro: intro,
            accent: accent,
            triggerTitle: "Suggest Homes",
            triggerSymbol: FilingGlyph.lens,
            triggerHelp: "Suggest where the loose files in this folder belong. Runs on this Mac "
                + "and costs nothing; once there are results you can re-ask Claude about them.",
            samplesTitle: "What a suggestion looks like",
            // Announced as one unit: read row by row, three invented filenames sound like real
            // findings about the user's disk, which is the opposite of what they are.
            samplesAccessibility: "Example of the suggestion format: a file name, the folder it "
                + "would move to, and how confident the suggestion is. These are samples, not "
                + "files on your disk.",
            onStart: onStart,
            footnote: footnote
        ) {
            ForEach(FilingSetupCard.samples) { sample in
                sampleRow(sample)
            }
        }
    }

    private func sampleRow(_ sample: Sample) -> some View {
        LensSetupSampleRow {
            Image(systemName: sample.icon)
                .scaledFont(.caption)
                .frame(width: 15)
            Text(sample.name)
                .scaledFont(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .scaledFont(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(sample.destination)
                .scaledFont(.caption)
                .lineLimit(1)
                .foregroundStyle(sample.isConfident ? .secondary : .tertiary)
            Spacer(minLength: 6)
            Text(sample.isConfident ? "ready" : "unsure")
                .scaledFont(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
    }

    struct Sample: Identifiable {
        let id = UUID()
        let icon: String
        let name: String
        let destination: String
        let isConfident: Bool
    }

    /// Invented, ordinary filenames. The third shows that "no confident home" is a normal result,
    /// not a failure.
    static let samples: [Sample] = [
        Sample(icon: "doc.text", name: "Bank statement Mar 2026.pdf",
               destination: "Finance/Statements", isConfident: true),
        Sample(icon: "doc.text", name: "Passport renewal form.pdf",
               destination: "Immigration", isConfident: true),
        Sample(icon: "photo", name: "IMG_4471.HEIC",
               destination: "no confident home", isConfident: false),
    ]
}
