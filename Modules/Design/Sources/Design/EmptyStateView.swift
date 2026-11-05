import SwiftUI

/// The app's one blank-panel template: icon, title and message, an optional caption for the
/// safety contract ("Nothing is removed without your confirmation…"), and up to two actions.
/// Every workspace's "nothing here" state renders through this, so an empty panel always looks
/// intentional and offers the next step. All copy is passed in; this view owns only layout.
public struct EmptyStateView: View {
    /// One button an empty state offers. `primary` is prominent and large (the obvious next step
    /// of a pre-scan state); `secondary` is regular bordered (a terminal state's "Scan again").
    public struct Action {
        public let title: String
        public let systemImage: String?
        /// The tooltip, for an action whose title doesn't say what it does or touches. nil shows
        /// none, never an empty tooltip box.
        public let help: String?
        public let handler: () -> Void

        public init(_ title: String, systemImage: String? = nil, help: String? = nil,
                    handler: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.help = help
            self.handler = handler
        }
    }

    /// How much room the state gets. `standard` is the full-tab panel; `compact` shrinks the icon
    /// and spacing for narrow hosts (the Details sidebar, a file pane placeholder, the Help
    /// sidebar).
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
    ///   - tint: The icon's color, the state's mood (accent = ready, green = success,
    ///     secondary = neutral).
    ///   - title: One short line naming the state.
    ///   - message: What this state means and what a scan would do.
    ///   - path: A file-system path (the missing root, the offending folder), monospaced on one
    ///     line, middle-truncated with the full path on hover.
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
            // Hidden from VoiceOver: the title already names the state, and a symbol name read
            // ahead of it adds nothing.
            Image(systemName: icon)
                .scaledFont(.system(size: isCompact ? 28 : 40))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            // The title heads the panel, so the rotor's Headings list can find it.
            Text(title)
                .scaledFont(.system(size: isCompact ? 13 : 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if let path {
                // Its own slot, not `caption`: a caption wraps and centers, which suits prose but
                // not a long path, which needs one middle-truncated line with the full value on
                // hover.
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
                        .accentedProminent()
                        .chromeHover()
                        .controlSize(isCompact ? .small : .large)
                        .modifier(ActionHelp(text: primary.help))
                    }
                    if let secondary {
                        Button(action: secondary.handler) {
                            label(for: secondary)
                        }
                        // The same hover as the primary, not a quieter one: side by side, a pair
                        // where only one answers the pointer reads as one live control and one
                        // dead label.
                        .chromeHover()
                        .controlSize(isCompact ? .small : .regular)
                        .modifier(ActionHelp(text: secondary.help))
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

/// `.help` only when there is text. An empty `.help("")` still arms a tooltip that opens onto
/// nothing. The branch never flips for a given action, and the button holds no state to lose.
private struct ActionHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
