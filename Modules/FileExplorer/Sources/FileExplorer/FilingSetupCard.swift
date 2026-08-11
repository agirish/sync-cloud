import Design
import SwiftUI

/// Organize ▸ To File before its first run: what will happen and what it looks like.
///
/// **This is ``LensSetupCard`` now, not a second card that resembles it.** It was written first
/// and generalized second (v4.0 polish P12), and for one release the two existed side by side
/// with byte-identical `body`, `header`, `trigger` and `sampleSection` implementations. Two
/// copies of a layout whose entire job is that every lens opens *identically* is the one shape
/// that cannot survive: the next padding change lands in one of them, and To File starts opening
/// a few points off from the other five with nothing to point at. What is left here is what is
/// genuinely To File's — its trigger, its sample rows, and the reason the third row exists.
///
/// **The price is gone because the scan is free.** This card used to carry the last recorded
/// cloud run's cost on the trigger, on the rule that a spending action wears its price. The scan
/// classifies at `FilingClassifierTier.free` now — the paid pass is the Refine button on the
/// results — so a price here would be quoting a cost for something that has none. What the last
/// cloud pass *did* cost still has a place: the `footnote`, under the card rather than above it.
///
/// The sample rows are the part that is easy to dismiss and worth keeping: without them the first
/// real run is also the first time anyone sees that layout, at the moment they are being asked to
/// judge a list of proposed moves. They are deliberately inert and greyed — nothing here is a
/// suggestion about a real file, and the third row exists so "no confident home" is a familiar
/// outcome rather than a surprise.
///
/// The words come from ``LensIntros/organize(scanTargetName:)``, the same value the pre-scan empty
/// state renders, so the card cannot drift from the explanation shown everywhere else.
struct FilingSetupCard: View {
    let intro: LensIntro
    let accent: Color
    /// The spend row, when this machine has cloud scans on record. Under the card — see
    /// ``LensSetupCard/footnote`` for why it is not above it.
    var footnote: AnyView? = nil
    let onStart: () -> Void

    var body: some View {
        // The generalized card (LensSetupCard) grew out of this view; delegating back keeps one
        // body for every lens's fresh state instead of a template and a drifting origin.
        LensSetupCard(
            intro: intro,
            accent: accent,
            triggerTitle: "Suggest homes",
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

    /// Invented filenames, deliberately ordinary. The third is the one that earns its place: a
    /// scan that returns "no confident home" for some files is the normal case, not a failure,
    /// and meeting that for the first time in a real result list makes it look like one.
    static let samples: [Sample] = [
        Sample(icon: "doc.text", name: "Bank statement Mar 2026.pdf",
               destination: "Finance/Statements", isConfident: true),
        Sample(icon: "doc.text", name: "Passport renewal form.pdf",
               destination: "Immigration", isConfident: true),
        Sample(icon: "photo", name: "IMG_4471.HEIC",
               destination: "no confident home", isConfident: false),
    ]
}
