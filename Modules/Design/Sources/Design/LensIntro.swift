/// What a lens is and what it promises not to do, held as data so the pre-scan empty state and
/// Organize's setup card show the same words and can't drift apart.
///
/// ``safety`` is a field of its own, not a sentence on ``message``, because ``EmptyStateView``'s
/// `caption` slot is the safety contract ("Nothing moves without your say-so").
public struct LensIntro: Sendable, Equatable {
    /// SF Symbol for the lens.
    public let icon: String
    /// One short line naming what the lens is for.
    public let title: String
    /// What it does, and how.
    public let message: String
    /// The safety contract: what this lens will and will not do to the user's files. Every lens
    /// states one, so its blast radius is written down.
    public let safety: String

    public init(icon: String, title: String, message: String, safety: String) {
        self.icon = icon
        self.title = title
        self.message = message
        self.safety = safety
    }
}
