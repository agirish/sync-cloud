import Design
import SwiftUI

/// The card that opens the sheet: what the app is, what it is about to ask, and where the answers
/// stay.
///
/// **Nobody who works on this ever sees it.** It renders once per install, on a machine that has
/// never run SyncCloud — which is why its copy is data in ``SetupFlow`` with tests derived from it
/// rather than literals written here.
struct WelcomeScreen: View {
    let paneNames: (String, String)
    /// What the card promises the sheet will ask. **Injectable for one reason**: the only test that
    /// can prove this list is *drawn* rather than merely declared is one that renders the card twice
    /// and finds it shorter without the rows. Three tests asserted the table while nothing drew it
    /// at all, for two commits.
    var rows: [SetupFlow.OutlineRow] = SetupFlow.outline

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to SyncCloud")
                    .scaledFont(.largeTitle.weight(.semibold))
                Text(SetupFlow.welcomeBlurb)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 10) {
                ForEach(SetupFlow.panels, id: \.title) { panel in
                    VStack(spacing: 6) {
                        // **The box first, then the scale.** It was framed at the box *already
                        // multiplied by the scale* and then scaled again, so each drawing was
                        // proposed a 66×48 box and shrunk to 29×21 inside it — which is why the
                        // four of them came out at four different sizes: each one overflowed its
                        // frame by however much its own natural drawing exceeded 66pt, and the
                        // overflow is what you saw. Framed at the box the drawings were designed
                        // against, they scale as a set.
                        SetupIllustration(art: panel.art,
                                          leftName: paneNames.0, rightName: paneNames.1)
                            .frame(width: SetupSheet.panelArtBox.width,
                                   height: SetupSheet.panelArtBox.height)
                            .scaleEffect(SetupSheet.panelArtScale)
                            .frame(width: SetupSheet.panelArtBox.width * SetupSheet.panelArtScale,
                                   height: SetupSheet.panelArtBox.height * SetupSheet.panelArtScale)
                            .accessibilityHidden(true)
                        Text(panel.title).scaledFont(.callout.weight(.semibold))
                        Text(panel.blurb)
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(SetupFlow.welcomeQuestionsHeading)
                    .scaledFont(.callout.weight(.semibold))
                ForEach(rows, id: \.screen) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.screen.number.map(String.init) ?? "·")
                            .scaledFont(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                            .frame(width: 14, alignment: .trailing)
                        Text(row.detail).scaledFont(.callout)
                    }
                }
                Text(SetupFlow.welcomeAfterQuestions)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Label(SetupFlow.privacyClaim, systemImage: "lock")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SetupFlow.runAgainNote)
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
