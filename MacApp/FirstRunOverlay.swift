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

    /// One page of the welcome tour. Pure data so the sequence is testable.
    struct Page: Equatable {
        /// SF Symbol for feature pages. The intro page (index 0) draws the app icon instead, so
        /// its `systemImage` is unused.
        let systemImage: String
        let title: String
        let blurb: String
    }

    /// The tour: an intro page, then one page per headline feature. The view special-cases index 0
    /// (app icon + the pane pill / choose-providers hint on the final page) and renders the rest
    /// straight from this list. Blurbs describe shipping behavior — keep them honest.
    static let pages: [Page] = [
        Page(systemImage: "hand.wave",
             title: "Welcome to SyncCloud",
             blurb: "Compare two cloud folders side by side, then copy, move, or tidy the differences."),
        Page(systemImage: "rectangle.split.2x1",
             title: "Compare side by side",
             blurb: "Point each pane at a folder in iCloud, OneDrive, Google Drive, or Dropbox. SyncCloud shows exactly what differs — files on only one side, and ones that changed."),
        Page(systemImage: "arrow.left.arrow.right",
             title: "Copy & move differences",
             blurb: "Send files either direction with a click. SyncCloud confirms before it writes, resolves name collisions, and every action can be undone with ⌘Z."),
        Page(systemImage: "sparkles",
             title: "Tidy up duplicates",
             blurb: "The Tidy tab finds duplicate files and picks which copies to remove — and never trashes the last copy of anything."),
        Page(systemImage: "tray.full",
             title: "File loose files automatically",
             blurb: "Filing sorts stray files into the folders where they belong, using on-device content signals — or AI, when you turn it on in Settings."),
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
    let surfaceStyle: SurfaceStyle
    let glassHue: LiquidGlassHue
    let glassIntensity: Double
    let surfaceTint: Double
    let onScan: (_ dontShowAgain: Bool) -> Void
    let onChooseProviders: (_ dontShowAgain: Bool) -> Void
    let onDismiss: (_ dontShowAgain: Bool) -> Void

    @State private var pageIndex = 0
    /// On by default: the tour is a once-per-install thing out of the box. Unchecking it tells the
    /// caller not to persist the seen flag, so the tour returns on the next launch.
    @State private var dontShowAgain = true

    private var pages: [FirstRunWelcome.Page] { FirstRunWelcome.pages }
    private var isLastPage: Bool { pageIndex >= pages.count - 1 }

    private var primaryAction: FirstRunWelcome.PrimaryAction {
        FirstRunWelcome.primaryAction(providerCount: providerCount)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture { onDismiss(dontShowAgain) }

            card
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    /// The card, decorated the same way as the settings card so the two in-window overlays
    /// read as one system: surface-style fill + shared card radius, then an opaque panel
    /// (`.solid`) or a frosted glass card tracking the glass-intensity slider.
    @ViewBuilder
    private var card: some View {
        let shaped = cardContent
            .contentSurface(surfaceStyle, hue: glassHue, tint: surfaceTint)
            .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous))
        let border = RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 0.5)

        switch surfaceStyle {
        case .solid:
            shaped
                .overlay(border)
                .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
        case .unified, .cards:
            shaped
                .glassCardStyle(intensity: glassIntensity)
                .overlay(border)
        }
    }

    private var cardContent: some View {
        VStack(spacing: 16) {
            pageHeader
                // Cross-fade the page contents as the user steps through the tour.
                .id(pageIndex)
                .transition(.opacity)

            pageDots

            controls
        }
        .padding(28)
        .frame(width: 460)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    /// Icon + title + blurb for the current page, plus the pane pill on the final page. A minimum
    /// height keeps the card from resizing as pages of different blurb lengths swap in.
    @ViewBuilder
    private var pageHeader: some View {
        let page = pages[pageIndex]
        VStack(spacing: 16) {
            if pageIndex == 0 {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: page.systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
            }

            VStack(spacing: 8) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(page.blurb)
                    .font(.callout)
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
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .top)
    }

    @ViewBuilder
    private var lastPageContext: some View {
        if primaryAction == .scan {
            HStack(spacing: 8) {
                Text(leftProviderName)
                    .fontWeight(.medium)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("compared with")
                Text(rightProviderName)
                    .fontWeight(.medium)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: Capsule())
        } else {
            Text("SyncCloud finds your cloud folders automatically — pick the two to compare in Settings.")
                .font(.callout)
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
                .font(.callout)
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
                            .keyboardShortcut(.defaultAction)
                    case .chooseProviders:
                        Button("Choose providers…") { onChooseProviders(dontShowAgain) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Skip") { onDismiss(dontShowAgain) }
                    Button("Next") {
                        withAnimation(.easeInOut(duration: 0.15)) { pageIndex += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
    }

    private var closeButton: some View {
        Button { onDismiss(dontShowAgain) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .padding(10)
        .help("Skip")
        .accessibilityLabel("Skip")
    }
}
