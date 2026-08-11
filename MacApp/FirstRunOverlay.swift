import SwiftUI
import AppKit
import Design

/// Pure decision logic + tour content behind the first-run welcome overlay (H1), kept UI-free so
/// SyncCloudTests can pin the show gate, primary-action branch, and page sequence without a view.
enum FirstRunWelcome {
    /// UserDefaults key for the seen flag. QA reset:
    /// `defaults delete com.abhishekgirish.SyncCloud hasSeenFirstRunWelcome`.
    static let hasSeenDefaultsKey = "hasSeenFirstRunWelcome"

    enum PrimaryAction: Equatable {
        /// Two providers are ready — the front door is a scan.
        case scan
        /// Fewer than two providers discovered — send the user to Settings ▸ Providers first.
        case chooseProviders
    }

    /// The overlay auto-shows once per install: the seen flag is set when the user dismisses with
    /// "Don't show this again" left checked (the default). Help ▸ Welcome to SyncCloud re-opens it.
    static func shouldShow(hasSeenWelcome: Bool) -> Bool {
        !hasSeenWelcome
    }

    /// Which action the primary button performs, given how many providers discovery found.
    /// A useful scan needs both panes on a real provider, so below two the front door is
    /// the Providers tab instead.
    static func primaryAction(providerCount: Int) -> PrimaryAction {
        providerCount >= 2 ? .scan : .chooseProviders
    }

    /// Which illustration heads a page. Kept on the pure data so reordering pages can never
    /// desync the artwork from the copy.
    ///
    /// `FirstRunWelcomeTests.testEveryIllustrationIsUsedByExactlyOnePage` pins this against
    /// ``pages``, because an art case is unusually easy to strand: nothing outside this file
    /// references one, so a case added without a page — or a page deleted without its case —
    /// compiles and renders exactly as before.
    enum Art: Hashable { case welcome, browse, compare, transfer, tidy, filing }

    /// One page of the welcome tour. Pure data so the sequence is testable.
    struct Page: Equatable {
        let art: Art
        let title: String
        let blurb: String
    }

    /// The tour: an intro page, then one page per headline feature. The view renders each page's
    /// `art` as a small vector illustration above the copy, and adds the pane pill / choose-
    /// providers hint on the final page. Blurbs describe shipping behavior — keep them honest.
    ///
    /// **This is the one screen in the app nobody who works on it ever sees.** It renders once per
    /// install, on a machine that has never run SyncCloud, and `shouldShow` is false forever after
    /// — so it drifts silently while every other surface gets looked at daily. It spent the whole
    /// Organize build calling Duplicates a *workspace*, which it stopped being when the five
    /// segments folded to three; `testTheTourCallsNoRetiredWorkspaceAWorkspace` is derived from
    /// ``retiredWorkspaceRawValues`` so the next fold cannot leave the same kind of lie behind.
    ///
    /// The last page is the one carrying the Scan CTA and the provider pill (see
    /// `lastPageContext`), so whatever sits there has to make sense directly above "Scan now".
    static let pages: [Page] = [
        Page(art: .welcome,
             title: "Welcome to SyncCloud",
             blurb: "Browse your files, compare two cloud folders side by side, and let SyncCloud tidy what it finds — duplicates, loose files, names that don't travel."),
        // Browse leads the bar and is where a fresh window opens, so it leads the tour: the first
        // page after the intro should be the place the tour is about to leave you standing in.
        Page(art: .browse,
             title: "Browse your files",
             blurb: "One tree at full width, in columns or as an outline — this is where SyncCloud opens. Press Space to preview a file, and ⌘K to jump to any folder by name."),
        Page(art: .compare,
             title: "Compare side by side",
             blurb: "Point each pane at a folder in iCloud, OneDrive, Google Drive, Dropbox — or any folder on your Mac. SyncCloud shows exactly what differs: files on only one side, and ones that changed."),
        Page(art: .transfer,
             title: "Copy & move differences",
             blurb: "Send files either direction with a click. SyncCloud confirms before it writes, resolves name collisions, and every action can be undone with ⌘Z."),
        Page(art: .tidy,
             title: "Clear out duplicates",
             blurb: "Organize's Duplicates lens finds files with identical contents and picks which copies to remove — and never trashes the last copy of anything."),
        Page(art: .filing,
             title: "Let Organize do the filing",
             blurb: "Organize puts loose files in the folders where they belong, proposes better names, and can turn a choice you keep making into a rule. It reads content signals on your Mac — or uses AI, when you turn it on in Settings."),
    ]
}

/// The first-run welcome tour: a few informative pages about what SyncCloud does, then a scan (or
/// choose-providers) front door. Mirrors the settings overlay's dimmed-backdrop centered-card
/// pattern — click outside, Esc, ✕, or Skip all dismiss. Each dismissal reports the "Don't show
/// this again" checkbox so the caller can decide whether to persist the seen flag.
struct FirstRunOverlay: View {
    let leftProviderName: String
    let rightProviderName: String
    let providerCount: Int
    let glassHue: LiquidGlassHue
    let glassLevel: GlassLevel
    let surfaceTint: Double
    let onScan: (_ dontShowAgain: Bool) -> Void
    let onChooseProviders: (_ dontShowAgain: Bool) -> Void
    let onDismiss: (_ dontShowAgain: Bool) -> Void

    @State private var pageIndex = 0
    /// On by default: the tour is a once-per-install thing out of the box. Unchecking it tells the
    /// caller not to persist the seen flag, so the tour returns on the next launch.
    @State private var dontShowAgain = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pages: [FirstRunWelcome.Page] { FirstRunWelcome.pages }
    private var isLastPage: Bool { pageIndex >= pages.count - 1 }

    private var primaryAction: FirstRunWelcome.PrimaryAction {
        FirstRunWelcome.primaryAction(providerCount: providerCount)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                .ignoresSafeArea()
                .onTapGesture { onDismiss(dontShowAgain) }

            card
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    /// The card, decorated the same way as the settings card so the in-window overlays read as one
    /// system: the accent tint, then the glass material at the level's face value via
    /// `groundedGlassCard`, which keeps Clear distinguishable from Frosted while still giving the
    /// content a ground to sit on.
    @ViewBuilder
    private var card: some View {
        cardContent
            .contentSurface(hue: glassHue, tint: surfaceTint)
            // No hairline overlay here: `groundedGlassCard` now draws it for BOTH schemes. Adding
            // one on top put a second border over the dark specular edge.
            .groundedGlassCard(level: glassLevel)
            .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
    }

    private var cardContent: some View {
        VStack(spacing: 16) {
            pageHeader
                // Cross-fade (+ a gentle scale-in) the page contents as the user steps through.
                .id(pageIndex)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))

            pageDots

            controls
        }
        .padding(24)
        .frame(width: 460)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    /// Icon + title + blurb for the current page, plus the pane pill on the final page. A minimum
    /// height keeps the card from resizing as pages of different blurb lengths swap in.
    @ViewBuilder
    private var pageHeader: some View {
        let page = pages[pageIndex]
        VStack(spacing: 18) {
            TourArtwork(art: page.art, leftName: leftProviderName, rightName: rightProviderName)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                // Decorative — the title and blurb carry the meaning.
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(page.title)
                    .scaledFont(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(page.blurb)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The pane pill (or the choose-providers hint) lives on the last page, right above the
            // Scan CTA, so the user sees which two folders they're about to compare.
            if isLastPage {
                lastPageContext
            }
        }
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .top)
    }

    @ViewBuilder
    private var lastPageContext: some View {
        if primaryAction == .scan {
            HStack(spacing: 8) {
                Text(leftProviderName)
                    .fontWeight(.medium)
                Image(systemName: "arrow.left.arrow.right")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("compared with")
                Text(rightProviderName)
                    .fontWeight(.medium)
            }
            .scaledFont(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: Capsule())
        } else {
            Text("SyncCloud finds your cloud folders automatically — pick the two to compare in Settings.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { i in
                Circle()
                    .fill(i == pageIndex ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(pageIndex + 1) of \(pages.count)")
    }

    /// The "Don't show this again" checkbox above the navigation row: Back / Skip on the way in,
    /// and the Scan (or Choose providers) front door on the final page.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Don't show this again", isOn: $dontShowAgain)
                .toggleStyle(.checkbox)
                .scaledFont(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if pageIndex > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.15)) { pageIndex -= 1 }
                    }
                }

                Spacer()

                if isLastPage {
                    switch primaryAction {
                    case .scan:
                        Button("Scan now") { onScan(dontShowAgain) }
                            .buttonStyle(.borderedProminent)
                            .chromeHover()
                            .keyboardShortcut(.defaultAction)
                            .shortcutKeycap("⏎")
                    case .chooseProviders:
                        Button("Choose providers…") { onChooseProviders(dontShowAgain) }
                            .buttonStyle(.borderedProminent)
                            .chromeHover()
                            .keyboardShortcut(.defaultAction)
                            .shortcutKeycap("⏎")
                    }
                } else {
                    Button("Skip") { onDismiss(dontShowAgain) }
                    Button("Next") {
                        withAnimation(.easeInOut(duration: 0.15)) { pageIndex += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .chromeHover()
                    .keyboardShortcut(.defaultAction)
                    .shortcutKeycap("⏎")
                }
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
    }

    private var closeButton: some View {
        CloseButton { onDismiss(dontShowAgain) }
            .keyboardShortcut(.cancelAction)
            .shortcutKeycap("esc")
            .padding(4)
            .help(ShortcutHint.tooltip("Skip", "esc"))
            .accessibilityLabel("Skip")
    }
}

// MARK: - Tour artwork

/// The provider asset-catalog image name for a display name, or nil for the neutral/box hues that
/// have no bundled logo. Mirrors the classification the sidebar/pane headers use.
private func providerAssetName(_ displayName: String) -> String? {
    switch ProviderHue.classify(displayName) {
    case .iCloud:      return "icloud"
    case .dropbox:     return "dropbox"
    case .oneDrive:    return "onedrive"
    case .googleDrive: return "googledrive"
    // `.folder` is unreachable from here and listed only for exhaustiveness: it is returned solely
    // when a caller passes `isLocalFolder:`, and the tour classifies a bare display name. That the
    // arm is dead is the right outcome rather than a gap to plumb around — the tour runs before any
    // source has been added, so its two panes are always cloud accounts.
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

/// Small illustrations that head each tour page — built from the app's own provider logos, SF
/// Symbols, and shapes (no new assets), tinted with each provider's brand hue and animated in on
/// appear (motion gated on Reduce Motion). Decorative: the title and blurb carry the meaning, so
/// `pageHeader` marks the artwork `.accessibilityHidden(true)`.
struct TourArtwork: View {
    let art: FirstRunWelcome.Art
    let leftName: String
    let rightName: String

    var body: some View {
        switch art {
        case .welcome:  WelcomeArt()
        case .browse:   BrowseArt()
        case .compare:  CompareArt(leftName: leftName, rightName: rightName)
        case .transfer: TransferArt(leftName: leftName, rightName: rightName)
        case .tidy:     TidyArt()
        case .filing:   FilingArt()
        }
    }
}

/// The app icon over a softly breathing halo, above a row of the supported cloud logos.
private struct WelcomeArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var breathe = false
    // The welcome halo breathes in the user-selected glass hue, matching the app accent (C7).
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

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
                            colors: [hueAccent.opacity(breathe ? 0.38 : 0.22), hueAccent.opacity(0)],
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
        .onAppear {
            if reduceMotion { appeared = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Three columns opening left to right, each with the row that opened the next one lit — which is
/// exactly what a Browse pane looks like once you have drilled into something.
///
/// Deliberately the *column* stack rather than a folder glyph: Columns is the default presentation,
/// and the one thing a new user needs to expect is that clicking a folder opens a column beside it
/// instead of expanding it in place. A folder icon would have said "files", which they knew.
private struct BrowseArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Which row is lit in each column, and it must stay strictly ascending: the lit rows are read
    /// as one diagonal — a path walked down and to the right — and any other arrangement reads as
    /// three unrelated lists that happen to have a blue row each. The first draft ended on row 0
    /// and did exactly that, which a pixel count could not have told me.
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
        .onAppear {
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
                          ? AnyShapeStyle(.tint.opacity(isDeepest ? 1 : 0.45))
                          : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: row == Self.rowsPerColumn - 1 ? 22 : 30, height: 5)
            }
        }
        .padding(8)
        .frame(width: 46, height: 92, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.secondary.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
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
        .onAppear {
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
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(ProviderHue.classify(name).soft))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(hue.opacity(0.2)))
    }
}

/// A document drifting between two brand-tinted provider folders, arrows both ways.
private struct TransferArt: View {
    let leftName: String
    let rightName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        HStack(spacing: 14) {
            folder(name: leftName)
            VStack(spacing: 7) {
                Image(systemName: "doc.text.fill")
                    .scaledFont(.system(size: 30))
                    .foregroundStyle(.tint)
                    .offset(x: drift ? 7 : -7)
                HStack(spacing: 3) {
                    Image(systemName: "arrow.left").scaledFont(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 26, height: 1.5)
                    Image(systemName: "arrow.right").scaledFont(.system(size: 9, weight: .bold)).foregroundStyle(.tint)
                }
            }
            folder(name: rightName)
        }
        .onAppear {
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
private struct TidyArt: View {
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
                        // The knockout disc behind the check adapts light/dark (a hard-coded
                        // `.white` glowed against the dark-mode art). It does NOT exactly match
                        // the frosted glass card it sits on — that backdrop runs darker than
                        // `windowBackgroundColor` in dark mode — but the disc is almost fully
                        // covered by the glyph, so the near-miss is invisible.
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2))
                        .offset(x: 7, y: 5)
                        .scaleEffect(appeared ? 1 : 0.2)
                        .opacity(appeared ? 1 : 0)
                }
        }
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62).delay(0.1)) { appeared = true }
        }
    }

    private func doc(tinted: Bool) -> some View {
        Image(systemName: "doc.fill")
            .scaledFont(.system(size: 54))
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.55)))
    }
}

/// Loose documents dropping down into sorted folders — automatic filing.
private struct FilingArt: View {
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
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
        }
    }

    private func folder(tinted: Bool) -> some View {
        Image(systemName: "folder.fill")
            .scaledFont(.system(size: 30))
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.5)))
    }
}
