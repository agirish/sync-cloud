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

    private let icon: String
    private let tint: Color
    private let title: String
    private let message: String?
    private let caption: String?
    private let primary: Action?
    private let secondary: Action?

    /// - Parameters:
    ///   - icon: SF Symbol name, rendered large and hierarchical in `tint`.
    ///   - tint: The icon's color — the state's mood (accent = ready, green = success,
    ///     secondary = neutral).
    ///   - title: One short line naming the state.
    ///   - message: The job explanation — what this state means and what a scan would do.
    ///   - caption: The safety contract, set slightly smaller and dimmer than the message.
    ///   - primary: The one prominent next step (large, filled). nil for passive states.
    ///   - secondary: A quieter companion action (regular, bordered).
    public init(
        icon: String,
        tint: Color = .secondary,
        title: String,
        message: String? = nil,
        caption: String? = nil,
        primary: Action? = nil,
        secondary: Action? = nil
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.caption = caption
        self.primary = primary
        self.secondary = secondary
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 12))
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
                        .controlSize(.large)
                    }
                    if let secondary {
                        Button(action: secondary.handler) {
                            label(for: secondary)
                        }
                        .controlSize(.regular)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
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
