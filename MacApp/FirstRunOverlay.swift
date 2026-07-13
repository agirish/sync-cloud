import SwiftUI
import AppKit
import Design

/// Pure decision logic behind the first-run welcome overlay (H1), kept UI-free so
/// SyncCloudTests can pin the show gate and primary-action branch without a view.
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

    /// The overlay shows exactly once: every dismissal path marks it seen.
    static func shouldShow(hasSeenWelcome: Bool) -> Bool {
        !hasSeenWelcome
    }

    /// Which action the primary button performs, given how many providers discovery found.
    /// A useful scan needs both panes on a real provider, so below two the front door is
    /// the Providers tab instead.
    static func primaryAction(providerCount: Int) -> PrimaryAction {
        providerCount >= 2 ? .scan : .chooseProviders
    }
}

/// The one-time welcome card: what the app is for, which providers the panes start on, and a
/// scan (or choose-providers) front door. Mirrors the settings overlay's dimmed-backdrop
/// centered-card pattern — click outside, Esc, or ✕ all dismiss and mark the welcome seen.
struct FirstRunOverlay: View {
    let leftProviderName: String
    let rightProviderName: String
    let providerCount: Int
    let surfaceStyle: SurfaceStyle
    let glassHue: LiquidGlassHue
    let glassIntensity: Double
    let surfaceTint: Double
    let onScan: () -> Void
    let onChooseProviders: () -> Void
    let onDismiss: () -> Void

    private var primaryAction: FirstRunWelcome.PrimaryAction {
        FirstRunWelcome.primaryAction(providerCount: providerCount)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

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
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Welcome to SyncCloud")
                    .font(.title2.weight(.semibold))
                Text("Compare two cloud folders side by side, then copy, move, or tidy the differences.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            HStack(spacing: 10) {
                switch primaryAction {
                case .scan:
                    Button("Choose providers…", action: onChooseProviders)
                    Button("Scan now", action: onScan)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .chooseProviders:
                    Button("Not now", action: onDismiss)
                    Button("Choose providers…", action: onChooseProviders)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 420)
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(10)
            .help("Not now")
            .accessibilityLabel("Not now")
        }
    }
}
