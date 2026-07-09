import Settings
import FileExplorer
import Events
import SwiftUI
import Sync
import Design

/// Header above each file tree pane: provider logo and name on the left, this pane's
/// back/forward buttons on the right, and a clickable breadcrumb (provider root +
/// relative-path segments) below. Clicking a crumb navigates this pane; ⌥-clicking
/// navigates both panes to the same relative path.
public struct PaneHeader: View {
    public let title: String
    public let provider: CloudProvider?
    public let rootPath: String
    public let relativePath: String
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let onBack: () -> Void
    public let onForward: () -> Void
    public let onNavigate: (String) -> Void
    public let onNavigateBoth: (String) -> Void
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65

    public init(
        title: String,
        provider: CloudProvider?,
        rootPath: String,
        relativePath: String,
        canGoBack: Bool,
        canGoForward: Bool,
        onBack: @escaping () -> Void,
        onForward: @escaping () -> Void,
        onNavigate: @escaping (String) -> Void,
        onNavigateBoth: @escaping (String) -> Void
    ) {
        self.title = title
        self.provider = provider
        self.rootPath = rootPath
        self.relativePath = relativePath
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.onBack = onBack
        self.onForward = onForward
        self.onNavigate = onNavigate
        self.onNavigateBoth = onNavigateBoth
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let provider = provider {
                    Image(provider.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                    Text(provider.displayName)
                        .font(.headline.weight(.semibold))
                } else {
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!canGoBack)
                    .help("Go back to this pane's previous folder")

                    Button(action: onForward) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!canGoForward)
                    .help("Go forward to this pane's next folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            PaneBreadcrumb(
                rootPath: rootPath,
                relativePath: relativePath,
                onNavigate: onNavigate,
                onNavigateBoth: onNavigateBoth
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassBarStyle(intensity: glassIntensity)
    }
}
