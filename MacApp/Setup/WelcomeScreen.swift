import Design
import SwiftUI

/// The card that opens the sheet: what the app is, what it is about to ask, and where the answers
/// stay.
///
/// It renders once per install, on a Mac that has never run SyncCloud, so nobody working on the
/// app sees it. That is why its copy is data in ``SetupFlow``, with tests derived from it, rather
/// than literals here.
struct WelcomeScreen: View {
    let paneNames: (String, String)
    let hue: LiquidGlassHue
    /// What the card promises the sheet will ask. Injectable so a test can render the card with and
    /// without the rows and prove the list is drawn, not merely declared.
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
                        // The box first, then the scale. Framed at the box the drawings were
                        // designed against, they scale as a set; framed at the already-scaled box,
                        // each would overflow by a different amount and come out a different size.
                        SetupIllustration(art: panel.art,
                                          leftName: paneNames.0, rightName: paneNames.1,
                                          accent: hue.accentColor)
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
                            .foregroundStyle(hue.accentColor)
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
