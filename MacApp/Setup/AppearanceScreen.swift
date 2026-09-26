import Design
import Settings
import SwiftUI

/// The optional screen, and it comes last for that reason: nothing on it changes what SyncCloud
/// does.
///
/// **Text size is the exception, and it is why the stepper is in the chrome of every screen** —
/// somebody who needs bigger text needs it on screen 1, not on screen 9.
struct AppearanceScreen: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: SettingsManager
    let hue: LiquidGlassHue
    @Binding var fontSize: FontSize

    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw = LiquidGlassHue.blue.rawValue
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw = ListDensity.comfortable.rawValue

    private var density: Binding<ListDensity> {
        Binding(get: { ListDensity(rawValue: listDensityRaw) ?? .comfortable },
                set: { listDensityRaw = $0.rawValue })
    }

    private var appearanceMode: Binding<AppearanceMode> {
        Binding(get: { AppearanceMode(rawValue: appearanceModeRaw) ?? .system },
                set: { appearanceModeRaw = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            SetupHeading(title: "Make it yours",
                         blurb: "Optional — you can change all of it later in Settings.")

            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                Text("Text size & spacing").scaledFont(.callout.weight(.semibold))
                // The app's own control, in its specimen form: miniature rows whose bars thicken
                // with the text size and thin out with the spacing. Never given a fixed width —
                // `TextSizeSetupIntegrationTests` is what holds that.
                SizePresetRow(fontSize: $fontSize, density: density, style: .specimen)
            }

            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                Text("Light or dark").scaledFont(.callout.weight(.semibold))
                Picker("", selection: appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(hue)
                // **`alignment: .leading`, and its absence was visible.** A bare
                // `.frame(maxWidth:)` centres its content in the width it takes, so the segmented
                // control — narrower than 260 at every text size — sat 32pt right of the label
                // above it and of every other control on the card.
                .frame(maxWidth: 260, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                Text("Accent").scaledFont(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(SetupSheet.offeredHues, id: \.self) { offered in
                        swatch(offered)
                    }
                }
            }

            SetupMoreOptions(subtitle: "Notifications · launch at login · reopen panes") {
                GeneralRows()
            }

            Spacer(minLength: 0)
        }
    }

    private func swatch(_ offered: LiquidGlassHue) -> some View {
        let isSelected = selectedHueRaw == offered.rawValue
        return Button {
            selectedHueRaw = offered.rawValue
        } label: {
            // **The ring is drawn outside the swatch, with a gap.** `strokeBorder` draws it
            // *inside*, so on a 20pt circle the mark for "this is the one you picked" ate a fifth
            // of the only thing the control shows — the colour — and at 2pt against a saturated
            // fill it read as a darker edge rather than as a selection.
            Circle()
                .fill(offered.accentColor)
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay {
                    Circle()
                        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                                      lineWidth: 2)
                }
        }
        .buttonStyle(.hoverAffordance(.circular))
        .padding(-3)
        .help(offered.displayName)
        .accessibilityLabel("\(offered.displayName) accent\(isSelected ? ", selected" : "")")
    }
}

/// The Why panel beside Appearance.
struct AppearanceWhy: View {
    let hue: LiquidGlassHue

    var body: some View {
        SetupWhyPanel(title: "Why this is last",
                      footnoteLead: "If you skip:",
                      footnote: "system appearance, blue accent, default size.",
                      hue: hue) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing here changes what SyncCloud does, so it comes last.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Text size is the exception: the A A A control is on every screen.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This panel is tinted with your accent, so picking a colour shows here at "
                     + "once.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
