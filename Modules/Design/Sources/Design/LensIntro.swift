import SwiftUI

/// What a lens is, and what it promises not to do — as data, so the same words can appear in more
/// than one place without being written twice.
///
/// **Why this exists.** Every lens's explanation lived inside its `EmptyStateView` call, which
/// renders only while that lens has no results. Scan once and the explanation is gone for the rest
/// of the session; relaunching brought it back, which made the loss look temporary. It was not:
/// the `caption` slot is documented in ``EmptyStateView`` as *the safety contract* — "Nothing is
/// removed without your confirmation", "Nothing moves without your say-so", "Read-only: Storage
/// Lens never moves, deletes, or evicts anything" — so the one sentence stating what a lens will
/// and won't do to someone's files was the first thing to disappear once they started using it.
///
/// Restoring Storage's results makes that permanent rather than per-session, which is what forced
/// the question. The answer is not to keep the banner on screen longer — it is to stop tying the
/// explanation to emptiness. An intro is now a value that both the empty state and the header's
/// ⓘ render, so the words cannot drift apart and are reachable in every state.
public struct LensIntro: Sendable, Equatable {
    /// SF Symbol for the lens.
    public let icon: String
    /// One short line naming what the lens is for.
    public let title: String
    /// What it does, and how.
    public let message: String
    /// **The safety contract** — what this lens will and will not do to the user's files. Every
    /// lens has one; a lens that cannot state one is a lens whose blast radius nobody has written
    /// down.
    public let safety: String

    public init(icon: String, title: String, message: String, safety: String) {
        self.icon = icon
        self.title = title
        self.message = message
        self.safety = safety
    }
}

/// The ⓘ that puts a lens's ``LensIntro`` one click away, wherever the lens is — including once it
/// has results and the empty state is long gone.
///
/// Sized and placed to ride beside a lens title in ``LensHeaderCard``'s `title` slot, which is row
/// 1's *leading* content. That matters: the trailing side of that row already carries the lens's
/// actions and the search toggle, and the header's width is spoken for. Putting the affordance on
/// the leading side costs the title a few points and competes with nothing.
public struct LensIntroButton: View {
    private let intro: LensIntro
    private let tint: Color
    @State private var isPresented = false

    public init(intro: LensIntro, tint: Color) {
        self.intro = intro
        self.tint = tint
    }

    public var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: tint, shape: .circle))
        .help("What this workspace does")
        .accessibilityLabel("About \(intro.title)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            LensIntroCard(intro: intro, tint: tint)
        }
    }
}

/// The popover body. Deliberately the same four parts, in the same order, as the empty state —
/// icon, title, message, safety — so the ⓘ reads as the same explanation rather than a second one.
struct LensIntroCard: View {
    let intro: LensIntro
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: intro.icon)
                .scaledFont(.system(size: 22))
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(intro.title)
                    .scaledFont(.headline)
                Text(intro.message)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(intro.safety)
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        // A fixed width because the content is prose: left to size itself a popover renders these
        // paragraphs as one very long line. `fixedSize(vertical:)` above then lets the height grow
        // to whatever the wrapped text needs, at whatever the user's text size is.
        .frame(width: 320, alignment: .leading)
    }
}
