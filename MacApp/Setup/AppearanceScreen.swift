import Design
import Settings
import SwiftUI

/// The optional screen, last because nothing on it changes what SyncCloud does.
///
/// Text size is the exception, which is why its stepper is in the chrome of every screen: someone
/// who needs bigger text needs it on screen 1, not screen 9.
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
                Text("Size & spacing").scaledFont(.callout.weight(.semibold))
                // The app's own control in its specimen form: miniature rows whose bars thicken
                // with the text size and thin out with the spacing. Never given a fixed width
                // (`TextSizeSetupIntegrationTests` holds that).
                SizePresetRow(fontSize: $fontSize, density: density, style: .specimen)
            }

            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                Text("Theme").scaledFont(.callout.weight(.semibold))
                Picker("", selection: appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(hue)
                .help("Choose light or dark, or follow macOS")
                // `alignment: .leading`: a bare `.frame(maxWidth:)` centres its content, and the
                // segmented control, narrower than 260 at every text size, would sit right of the
                // label above it and of every other control on the card.
                .frame(maxWidth: 260, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                Text("Accent color").scaledFont(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(SetupSheet.offeredHues, id: \.self) { offered in
                        swatch(offered)
                    }
                }
                // Frosted and Clear: the chosen swatch's ring as a glass halo that travels to the
                // swatch you pick.
                .selectionLensHost(Self.swatchLensChannel, selected: LiquidGlassHue(rawValue: selectedHueRaw),
                                   style: Self.swatchLensStyle)
            }

            SetupMoreOptions(subtitle: "Notifications · launch at login · reopen panes") {
                GeneralRows()
            }

            Spacer(minLength: 0)
        }
    }

    /// The swatch row's selection lens; see `SelectionLens`.
    static let swatchLensChannel = SelectionLensChannel("setup.accent")
    /// A halo, like Settings' accent row: glass behind the swatch, showing only in the 3pt band
    /// outside it, with today's 2pt ring on the band's rim. `markerOpacity` 0 keeps the glass
    /// untinted at every Tint: it rings a colour, so it must not wear one.
    ///
    /// The ring is Settings' neutral ink, not `.tint`: nothing in the app sets a tint, so `.tint`
    /// would draw the system accent, a blue ring round the Green swatch just picked. Settings rings
    /// the same row with `HueOptionView.ringColor` for the same reason: a ring in one hue around a
    /// swatch of another contradicts what it marks.
    static let ringColor = Color.primary.opacity(0.4)
    static let swatchLensStyle = SelectionLensStyle(
        shape: .circle, color: ringColor, markerOpacity: 0,
        ring: .init(color: ringColor, width: 2))

    private func swatch(_ offered: LiquidGlassHue) -> some View {
        let isSelected = selectedHueRaw == offered.rawValue
        return Button {
            selectedHueRaw = offered.rawValue
        } label: {
            // The ring is drawn outside the swatch, with a gap. `strokeBorder` draws inside, so on
            // a 20pt circle the selection mark would eat a fifth of the colour, the only thing the
            // control shows, and at 2pt against a saturated fill read as a darker edge rather than
            // a selection.
            Circle()
                .fill(offered.accentColor)
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay {
                    // Today's marker; in Frosted and Clear the row's lens draws the ring.
                    if isSelected {
                        SelectionLensTodayMarker {
                            Circle().strokeBorder(Self.ringColor, lineWidth: 2)
                        }
                    }
                }
                .selectionLensStop(Self.swatchLensChannel, id: offered)
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
                      footnote: "these stay as they are.",
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
                Text("This panel is tinted with your accent, so picking a color shows here at "
                     + "once.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
