import Settings
import FileExplorer
import Events
import SwiftUI
import Sync
import Design

/// Toolbar above the two file panes: back/forward navigation, current folder context, hidden-files toggle.
/// Navigation and toggles trigger reloads through the manager itself (`refreshSubject` /
/// `applyFilters()`), so this view takes no refresh callback.
public struct NavigationToolbar: View {
    @ObservedObject public var syncManager: FileSyncManager
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65

    public init(syncManager: FileSyncManager) {
        self.syncManager = syncManager
    }

    public var body: some View {
        HStack {
            HStack(spacing: 8) {
                Button(action: { syncManager.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!syncManager.canGoBack)
                .help("Navigate to the previous directory")

                Button(action: { syncManager.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!syncManager.canGoForward)
                .help("Navigate to the next directory")
            }
            .buttonStyle(.bordered)
            
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 8)
            
            if let focus = BreadcrumbTrail.displayedFocus(
                leftRelativePath: syncManager.leftRelativePath,
                rightRelativePath: syncManager.rightRelativePath
            ) {
                breadcrumbBar(relativePath: focus.relativePath, isLeft: focus.isLeft)
                Spacer()
            } else {
                Text("Viewing All Files (Root)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            // No refresh here: raw trees and differences already include hidden entries, and the
            // showHiddenFiles didSet re-filters them in memory via applyFilters().
            Toggle(isOn: $syncManager.showHiddenFiles) {
                Label("Hidden", systemImage: "eye")
            }
            .toggleStyle(.button)
            .help("Toggle visibility of hidden files")
            .onChange(of: syncManager.showHiddenFiles) { _, newValue in
                Logger.shared.info("User toggled hidden files to: \(newValue)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBarStyle(intensity: glassIntensity)
    }

    /// Clickable breadcrumbs for the focused path: a house (root) crumb, then one crumb per
    /// path component. Deep trails collapse their middle into an ellipsis menu. Clicking a
    /// crumb re-focuses the displayed pane at that ancestor; the current folder is inert.
    @ViewBuilder
    private func breadcrumbBar(relativePath: String, isLeft: Bool) -> some View {
        let crumbs = BreadcrumbTrail.crumbs(forRelativePath: relativePath)
        let items = BreadcrumbTrail.displayItems(for: crumbs)
        HStack(spacing: 3) {
            Image(systemName: "scope")
                .foregroundColor(.accentColor)

            Button(action: { syncManager.resetNavigation() }) {
                Image(systemName: "house")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Return to the root directory view")

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Image(systemName: "chevron.compact.right")
                    .foregroundStyle(.tertiary)
                switch item {
                case .crumb(let crumb):
                    if crumb == crumbs.last {
                        Text(crumb.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Button(crumb.name) {
                            syncManager.focusOn(relativePath: crumb.relativePath, isLeft: isLeft)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Focus the comparison on \(crumb.relativePath)")
                    }
                case .collapsed(let hidden):
                    Menu {
                        ForEach(hidden) { crumb in
                            Button(crumb.name) {
                                syncManager.focusOn(relativePath: crumb.relativePath, isLeft: isLeft)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Collapsed folders")
                }
            }
        }
        .font(.subheadline)
    }
}
