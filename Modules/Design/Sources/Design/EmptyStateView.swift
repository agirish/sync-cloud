import SwiftUI

/// The app's one blank-panel template (backlog H3): icon + title + message, an optional
/// caption line for the safety contract ("Nothing is removed without your confirmation…"),
/// and up to two actions. Every tab's "nothing here" state — Differences, Tidy, Filing, the
/// Activity Log — renders through this so an empty panel always looks intentional and always
/// offers the next step. Modeled on the Tidy Duplicates pre-scan (the L4 gold standard).
///
/// All copy is parameterized — this view hard-codes layout, never words.
public struct EmptyStateView: View {
    /// One button an empty state offers. `primary` renders prominent and large (the single
    /// obvious next step of a pre-scan state); `secondary` renders as a regular bordered
    /// button (the quieter "Scan again" of a terminal state).
    public struct Action {
        public let title: String
        public let systemImage: String?
        public let handler: () -> Void

        public init(_ title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.handler = handler
        }
    }

    /// How much room the state gets. `standard` is the full-tab blank panel; `compact`
    /// shrinks the icon and tightens spacing for narrow hosts (the Details sidebar, a file
    /// pane placeholder, the Help sidebar) where the standard layout would crowd its frame.
    public enum Layout: Sendable {
        case standard
        case compact
    }

    private let icon: String
    private let tint: Color
    private let title: String
    private let message: String?
    private let path: String?
    private let caption: String?
    private let primary: Action?
    private let secondary: Action?
    private let layout: Layout

    /// - Parameters:
    ///   - icon: SF Symbol name, rendered large and hierarchical in `tint`.
    ///   - tint: The icon's color — the state's mood (accent = ready, green = success,
    ///     secondary = neutral).
    ///   - title: One short line naming the state.
    ///   - message: The job explanation — what this state means and what a scan would do.
    ///   - path: A file-system path detail (the missing root, the offending folder) —
    ///     rendered monospaced on one line, middle-truncated with the full path on hover.
    ///   - caption: The safety contract, set slightly smaller and dimmer than the message.
    ///   - primary: The one prominent next step (large, filled). nil for passive states.
    ///   - secondary: A quieter companion action (regular, bordered).
    ///   - layout: `standard` for full-tab panels; `compact` for narrow hosts.
    public init(
        icon: String,
        tint: Color = .secondary,
        title: String,
        message: String? = nil,
        path: String? = nil,
        caption: String? = nil,
        primary: Action? = nil,
        secondary: Action? = nil,
        layout: Layout = .standard
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.path = path
        self.caption = caption
        self.primary = primary
        self.secondary = secondary
        self.layout = layout
    }

    private var isCompact: Bool { layout == .compact }

    public var body: some View {
        VStack(spacing: isCompact ? 8 : 12) {
            Image(systemName: icon)
                .scaledFont(.system(size: isCompact ? 28 : 40))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .scaledFont(.system(size: isCompact ? 13 : 15, weight: .semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if let path {
                // Paths get their own slot instead of riding in `caption`: a caption wraps
                // and centers (fine for prose, unreadable for a long path), while a path
                // needs single-line middle truncation with the full value on hover.
                Text(path)
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .frame(maxWidth: 440)
            }
            if let caption {
                Text(caption)
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if primary != nil || secondary != nil {
                HStack(spacing: 10) {
                    if let primary {
                        Button(action: primary.handler) {
                            label(for: primary)
                        }
                        .buttonStyle(.borderedProminent)
                        .chromeHover()
                        .controlSize(isCompact ? .small : .large)
                    }
                    if let secondary {
                        Button(action: secondary.handler) {
                            label(for: secondary)
                        }
                        // Same choke point as the primary, deliberately not a quieter variant of
                        // it. These two sit side by side in one HStack, and a pair where only one
                        // answers the pointer doesn't read as "loud and quiet" — it reads as one
                        // live control and one dead label, which is exactly wrong for a button
                        // whose whole job is to offer the alternative next step.
                        .chromeHover()
                        .controlSize(isCompact ? .small : .regular)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(isCompact ? 16 : 24)
    }

    @ViewBuilder
    private func label(for action: Action) -> some View {
        if let systemImage = action.systemImage {
            Label(action.title, systemImage: systemImage)
        } else {
            Text(action.title)
        }
    }
}
