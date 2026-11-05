import SwiftUI
import AppKit
import Design

/// The illustrations that head the setup form's welcome strip.
///
/// Built from the app's own provider logos, SF Symbols and shapes, with no new assets. They show
/// what a sentence can't: what a Columns drill looks like, what "two panes" means before you have
/// seen one.
///
/// `SetupArtworkRenderTests` renders each case to a bitmap and reads it back, which holds the
/// Browse illustration to three separate columns and a lit diagonal.
enum SetupArt {
    /// Which illustration a panel carries. Plain data, so reordering the strip can never desync a
    /// drawing from its copy.
    ///
    /// Not every case heads a panel: `welcome` heads the card itself, and `transfer` and
    /// `duplicates` are kept because an illustration is cheap to keep and expensive to redraw.
    /// `everyPanelHasCopyAndItsOwnIllustration` checks that no two panels share one.
    // CaseIterable so the render suite covers every case by construction: a case added here is
    // rendered by `testEveryTourPagePaintsItsIllustration` without anyone remembering to.
    enum Art: Hashable, Sendable, CaseIterable {
        case welcome, browse, compare, transfer, duplicates, filing, edit
    }
}

// MARK: - The reveal

/// Whether the setup art runs its reveal, the `onAppear` every illustration animates in from.
///
/// Always on in the app. `SetupArtworkRenderTests` turns it off to draw each page as it stands
/// before `onAppear`, and requires the revealed page to differ from it. Most pages paint part of
/// themselves before the reveal, so without that comparison a lost reveal would pass every ink
/// check.
private struct SetupArtRevealsKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var setupArtReveals: Bool {
        get { self[SetupArtRevealsKey.self] }
        set { self[SetupArtRevealsKey.self] = newValue }
    }
}

/// `onAppear`, held back when `setupArtReveals` is off.
private struct RevealOnAppear: ViewModifier {
    @Environment(\.setupArtReveals) private var reveals
    let reveal: () -> Void

    func body(content: Content) -> some View {
        content.onAppear { if reveals { reveal() } }
    }
}

private extension View {
    /// Where every illustration starts its reveal, in place of `onAppear`, so a render can ask for
    /// the frame before it (`setupArtReveals`).
    func onReveal(_ reveal: @escaping () -> Void) -> some View {
        modifier(RevealOnAppear(reveal: reveal))
    }
}

// MARK: - The illustrations

/// The provider asset-catalog image name for a display name, or nil for the neutral/box hues that
/// have no bundled logo. Mirrors the classification the sidebar/pane headers use.
private func providerAssetName(_ displayName: String) -> String? {
    switch ProviderHue.classify(displayName) {
    case .iCloud:      return "icloud"
    case .dropbox:     return "dropbox"
    case .oneDrive:    return "onedrive"
    case .googleDrive: return "googledrive"
    // `.folder` is unreachable here, listed for exhaustiveness: it comes back only when a caller
    // passes `isLocalFolder:`, and this classifies a bare display name. The art runs before any
    // source is added, so its two panes are always cloud accounts.
    case .box, .folder, .neutral: return nil
    }
}

/// A provider's real brand logo (the same asset the sidebar draws), or a hue-tinted cloud when the
/// name doesn't map to one of the bundled logos.
private struct ProviderGlyph: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        if let asset = providerAssetName(name) {
            Image(asset).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: "cloud.fill")
                .scaledFont(.system(size: size * 0.82))
                .foregroundStyle(ProviderHue.classify(name).tint)
                .frame(width: size, height: size)
        }
    }
}

/// Small illustrations that head a welcome panel, tinted with each provider's brand hue and
/// animated in on appear (motion gated on Reduce Motion). Decorative: the title and blurb carry the
/// meaning, so the setup card marks the artwork `.accessibilityHidden(true)`.
struct SetupIllustration: View {
    let art: SetupArt.Art
    let leftName: String
    let rightName: String
    /// The sheet's accent. Handed in, because nothing above sets `.tint`, so drawing in it would
    /// show the system accent on a sheet of another hue.
    let accent: Color

    var body: some View {
        switch art {
        case .welcome:  WelcomeArt(accent: accent)
        case .browse:   BrowseArt(accent: accent)
        case .compare:  CompareArt(leftName: leftName, rightName: rightName)
        case .transfer: TransferArt(leftName: leftName, rightName: rightName, accent: accent)
        case .duplicates: DuplicatesArt(accent: accent)
        case .filing:   FilingArt(accent: accent)
        case .edit:     EditArt(accent: accent)
        }
    }
}

/// The app icon over a softly breathing halo, above a row of the supported cloud logos.
private struct WelcomeArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var breathe = false
    /// The welcome halo breathes in the user-selected glass hue, matching the app accent.
    let accent: Color

    private let providers = ["icloud", "googledrive", "dropbox", "onedrive"]

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 66, height: 66)
                // Halo drawn as a background so it never inflates the layout height.
                .background(
                    Circle()
                        .fill(RadialGradient(
                            colors: [accent.opacity(breathe ? 0.38 : 0.22), accent.opacity(0)],
                            center: .center, startRadius: 4, endRadius: 62))
                        .frame(width: 118, height: 118)
                        .scaleEffect(breathe ? 1.06 : 0.98)
                )
                .scaleEffect(appeared ? 1 : 0.82)
                .opacity(appeared ? 1 : 0)

            HStack(spacing: 12) {
                ForEach(Array(providers.enumerated()), id: \.offset) { index, asset in
                    Image(asset)
                        .resizable().scaledToFit()
                        .frame(width: 26, height: 26)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(reduceMotion ? nil
                                   : .spring(response: 0.45, dampingFraction: 0.7).delay(0.12 + 0.06 * Double(index)),
                                   value: appeared)
                }
            }
        }
        .onReveal {
            if reduceMotion { appeared = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Three columns opening left to right, each with the row that opened the next one lit: a Browse
/// pane after drilling in.
///
/// Columns, not a folder glyph: Columns is the default, and a new user needs to expect that
/// clicking a folder opens a column beside it instead of expanding it in place.
private struct BrowseArt: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Which row is lit in each column. Must stay strictly ascending: the lit rows read as one
    /// diagonal, a path walked down and to the right, and any other order reads as three unrelated
    /// lists with a lit row each.
    private static let litRows = [1, 2, 3]

    /// Rows per column. Five rather than four so the columns read as lists with a little room
    /// under them, rather than as mostly-empty frames.
    private static let rowsPerColumn = 5

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.litRows.enumerated()), id: \.offset) { index, litRow in
                column(litRow: litRow, isDeepest: index == Self.litRows.count - 1)
                    .opacity(appeared ? 1 : 0)
                    .offset(x: appeared ? 0 : -12)
                    // Staggered left to right: the columns arrive in the order clicking would
                    // have opened them.
                    .animation(reduceMotion ? nil
                               : .spring(response: 0.42, dampingFraction: 0.74).delay(0.09 * Double(index)),
                               value: appeared)
            }
        }
        .onReveal {
            guard !reduceMotion else { appeared = true; return }
            withAnimation { appeared = true }
        }
    }

    private func column(litRow: Int, isDeepest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<Self.rowsPerColumn, id: \.self) { row in
                Capsule()
                    // The deepest column's lit row is the selection; the shallower ones are the
                    // trail behind it, so they carry the tint at half strength.
                    .fill(row == litRow
                          ? AnyShapeStyle(accent.opacity(isDeepest ? 1 : 0.45))
                          : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: row == Self.rowsPerColumn - 1 ? 22 : 30, height: 5)
            }
        }
        .padding(8)
        .frame(width: 46, height: 92, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
            .fill(Color.secondary.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1))
    }
}

/// The two providers being compared, each a brand-tinted pane with one differing row lit up.
private struct CompareArt: View {
    let leftName: String
    let rightName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 12) {
            pane(name: leftName, diffRow: 2)
            pane(name: rightName, diffRow: 0)
        }
        .onReveal {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) { appeared = true }
        }
    }

    private func pane(name: String, diffRow: Int) -> some View {
        let hue = ProviderHue.classify(name).tint
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ProviderGlyph(name: name, size: 15)
                Capsule().fill(hue.opacity(0.5)).frame(width: 26, height: 4)
            }
            .padding(.bottom, 1)
            ForEach(0..<3, id: \.self) { row in
                let hot = row == diffRow
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(hot ? AnyShapeStyle(hue) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                        .frame(width: 9, height: 9)
                    Capsule()
                        .fill(hot ? AnyShapeStyle(hue.opacity(0.5)) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                        .frame(width: hot ? 56 : 44, height: 5)
                }
                // The differing row lights up last, drawing the eye to "what changed".
                .opacity(hot ? (appeared ? 1 : 0.15) : 1)
                .scaleEffect(hot && !appeared ? 0.92 : 1, anchor: .leading)
            }
        }
        .padding(11)
        .frame(width: 108, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.well, style: .continuous).fill(ProviderHue.classify(name).soft))
        .overlay(RoundedRectangle(cornerRadius: Radius.well, style: .continuous).strokeBorder(hue.opacity(0.2)))
    }
}

/// A document drifting between two brand-tinted provider folders, arrows both ways.
private struct TransferArt: View {
    let leftName: String
    let rightName: String
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        HStack(spacing: 14) {
            folder(name: leftName)
            VStack(spacing: 7) {
                Image(systemName: "doc.text.fill")
                    .scaledFont(.system(size: 30))
                    .foregroundStyle(accent)
                    .offset(x: drift ? 7 : -7)
                HStack(spacing: 3) {
                    Image(systemName: "arrow.left").scaledFont(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 26, height: 1.5)
                    Image(systemName: "arrow.right").scaledFont(.system(size: 9, weight: .bold)).foregroundStyle(accent)
                }
            }
            folder(name: rightName)
        }
        .onReveal {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private func folder(name: String) -> some View {
        Image(systemName: "folder.fill")
            .scaledFont(.system(size: 40))
            .foregroundStyle(ProviderHue.classify(name).tint)
            .overlay(alignment: .bottomTrailing) {
                ProviderGlyph(name: name, size: 17)
                    .padding(2)
                    .background(Circle().fill(.background))
                    .offset(x: 5, y: 3)
            }
    }
}

/// A fanned stack of identical documents with the keeper checked — duplicate detection. The
/// duplicates fan out and the check pops in on appear.
private struct DuplicatesArt: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            doc(tinted: false)
                .rotationEffect(.degrees(appeared ? -11 : 0))
                .offset(x: appeared ? -22 : 0, y: appeared ? 7 : 0)
                .opacity(0.4)
            doc(tinted: false)
                .rotationEffect(.degrees(appeared ? 9 : 0))
                .offset(x: appeared ? 20 : 0, y: appeared ? 4 : 0)
                .opacity(0.4)
            doc(tinted: true)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(.system(size: 22))
                        .foregroundStyle(SemanticColor.success)
                        // The knockout disc adapts to light and dark; a fixed white would glow in
                        // dark mode. It is lighter than the frosted card in dark mode, but the
                        // glyph covers almost all of it, so the mismatch is invisible.
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2))
                        .offset(x: 7, y: 5)
                        .scaleEffect(appeared ? 1 : 0.2)
                        .opacity(appeared ? 1 : 0)
                }
        }
        .onReveal {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62).delay(0.1)) { appeared = true }
        }
    }

    private func doc(tinted: Bool) -> some View {
        Image(systemName: "doc.fill")
            .scaledFont(.system(size: 54))
            .foregroundStyle(tinted ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary.opacity(0.55)))
    }
}

/// Loose documents dropping down into sorted folders — automatic filing.
private struct FilingArt: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { index in
                    Image(systemName: "doc.fill")
                        .scaledFont(.system(size: 19))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .offset(y: appeared ? 0 : -10)
                        .opacity(appeared ? 1 : 0)
                        .animation(reduceMotion ? nil
                                   : .spring(response: 0.4, dampingFraction: 0.7).delay(0.08 * Double(index)),
                                   value: appeared)
                }
            }
            HStack(spacing: 34) {
                ForEach(0..<3, id: \.self) { _ in
                    Image(systemName: "arrow.down")
                        .scaledFont(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .opacity(appeared ? 1 : 0)
                }
            }
            HStack(spacing: 12) {
                folder(tinted: true); folder(tinted: false); folder(tinted: true)
            }
        }
        .onReveal {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
        }
    }

    private func folder(tinted: Bool) -> some View {
        Image(systemName: "folder.fill")
            .scaledFont(.system(size: 30))
            .foregroundStyle(tinted ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary.opacity(0.5)))
    }
}

/// A page of text with a caret in it and a heading rule above: the editor, in shapes. Drawn, not
/// screenshotted, like every illustration here, so it survives text-size changes and both
/// appearances, and paints at any size the render suite asks for.
private struct EditArt: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var caretOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // The heading, in the tint: Markdown's one visible structure.
            Capsule().fill(AnyShapeStyle(accent)).frame(width: 62, height: 7)
            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 4) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: [96.0, 80.0, 88.0, 54.0][index], height: 5)
                    if index == 3 {
                        // The caret sits at the end of the last line, where typing would be.
                        Rectangle()
                            .fill(AnyShapeStyle(accent))
                            .frame(width: 2, height: 12)
                            .opacity(caretOn ? 1 : 0.15)
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(x: appeared ? 0 : -8)
                .animation(reduceMotion ? nil
                           : .easeOut(duration: 0.32).delay(0.07 * Double(index)),
                           value: appeared)
            }
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReveal {
            guard !reduceMotion else { appeared = true; caretOn = true; return }
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                caretOn = true
            }
        }
    }
}
