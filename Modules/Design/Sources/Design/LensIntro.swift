/// What a lens is, and what it promises not to do — as data, so the same words can appear in more
/// than one place without being written twice.
///
/// **Why this exists.** Every lens's explanation lived inside its `EmptyStateView` call, and more
/// than one surface needs the same words: the pre-scan empty state and Organize's setup card both
/// state what the lens is for and what it will not do to someone's files. Holding them as a value
/// keeps those copies from drifting apart.
///
/// The `caption` slot is documented in ``EmptyStateView`` as *the safety contract* — "Nothing is
/// removed without your confirmation", "Nothing moves without your say-so", "Read-only: Storage
/// Lens never moves, deletes, or evicts anything" — which is why ``safety`` is a field of its own
/// rather than a sentence tacked onto ``message``.
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
