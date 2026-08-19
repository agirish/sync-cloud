import Foundation
import CoreGraphics
import AppKit
import Design

/// How much of its placeholder the open Go-to field can afford to say.
///
/// Two rungs, chosen by measurement rather than by a width guess, for the reason
/// ``CommandPaletteBarStyle`` has two: at a 960pt window the field has room for about 249pt of text
/// against the full string's ~282, so without a rung the invitation arrives as a fragment — and a
/// truncated sentence teaches less than a shorter whole one.
public enum GoToFieldPlaceholder: Equatable, Sendable {
    /// *Go to a place, a folder, a person, or an action…*
    case full
    /// *Go to a folder, person, or action…*
    case short
}

/// What the open field is, once the row has been divided up: how wide, and which invitation it can
/// hold. Resolved with the rest of the toolbar rather than by the field itself — see
/// `WorkspaceBarMetrics.styles`.
public struct GoToFieldLayout: Equatable, Sendable {
    public var width: CGFloat
    public var placeholder: GoToFieldPlaceholder

    public init(width: CGFloat, placeholder: GoToFieldPlaceholder) {
        self.width = width
        self.placeholder = placeholder
    }
}

/// The open field's arithmetic — its floor, its ceiling, its chrome, and the measured width of each
/// placeholder rung.
///
/// Separate from ``CommandPaletteBarMetrics`` but built from its constants: the field is the pill
/// grown up, and the two must agree about what the magnifier, the gaps and the keycap cost, or the
/// row's reserve is right for one of them and wrong for the other.
public enum GoToFieldMetrics {

    /// The narrowest the field is allowed to open before the workspace bar is asked to shed its
    /// labels for it. Below this a folder name and the caret stop fitting together.
    public static let floorWidth: CGFloat = 320

    /// The widest it ever opens — today's card width, so the list under it is the list that shipped
    /// rather than a re-tuned one.
    public static let ceilingWidth: CGFloat = 620

    /// The field's text, a point and a half larger than the pill's word: it is being typed into
    /// rather than read, and the card it replaces set its own field at 19pt.
    public static let textPointSize: CGFloat = 13.5

    /// The key the open field parks at its trailing end — the one that closes it. Named once and
    /// read by both the field that draws it and the arithmetic that reserves room for it: the pill
    /// and the field disagreeing about their own key is the failure with no symptom until the
    /// toolbar folds behind a chevron.
    public static let closeKeycap = "esc"

    /// The two invitations. The short rung keeps the two nouns a stranger cannot guess at — a
    /// folder and a person — and drops "place", which the list itself shows first.
    public static let fullPlaceholder = "Go to a place, a folder, a person, or an action…"
    public static let shortPlaceholder = "Go to a folder, person, or action…"

    /// Everything in the field that is not text: the same paddings, glyph and gap the pill charges,
    /// plus the trailing key.
    ///
    /// Taken from ``CommandPaletteBarMetrics`` rather than restated, because the field IS the pill
    /// after it grows: two copies of these numbers would let the row's reserve be right for the
    /// closed control and wrong for the open one, and the failure mode has no symptom until the
    /// toolbar is behind macOS's overflow chevron.
    public static func chromeWidth(keycapWidth: CGFloat) -> CGFloat {
        2 * CommandPaletteBarMetrics.horizontalPadding
            + CommandPaletteBarMetrics.glyphWidth
            + CommandPaletteBarMetrics.contentGap
            + CommandPaletteBarMetrics.keyGap
            + keycapWidth
    }

    /// A placeholder's rendered width at this text scale.
    ///
    /// Measured through `NSFont` and deliberately a little generous, exactly as the pill's label is:
    /// `Text` draws wider than `NSString.size` reports, and **under**-measuring is the direction
    /// that costs the whole toolbar. Here it would instead pick the full rung for a field that can
    /// only draw a fragment of it.
    public static func placeholderWidth(_ text: String, scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: textPointSize * scale, weight: .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
            + CommandPaletteBarMetrics.labelSafetyMargin * scale
    }

    /// Which invitation fits in a field of this width.
    ///
    /// The short rung is not itself guarded against being too long: there is no third rung to fall
    /// to, and an empty field with no placeholder at all says less than a clipped one.
    public static func placeholder(forWidth width: CGFloat, keycapWidth: CGFloat,
                                   scale: CGFloat) -> GoToFieldPlaceholder {
        let room = width - chromeWidth(keycapWidth: keycapWidth)
        return placeholderWidth(fullPlaceholder, scale: scale) <= room ? .full : .short
    }
}
