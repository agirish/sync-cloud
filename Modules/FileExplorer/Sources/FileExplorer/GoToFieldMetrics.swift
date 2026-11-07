import Foundation
import CoreGraphics
import AppKit
import Design

/// How much of its placeholder the open Go-to field can afford to say.
///
/// Two rungs, chosen by measurement, for the reason ``CommandPaletteBarStyle`` has two: at a 960pt
/// window the field has about 249pt for text against the full string's ~282, and a truncated
/// sentence teaches less than a shorter whole one.
public enum GoToFieldPlaceholder: Equatable, Sendable {
    /// *Go to a place, a folder, a person, or an action…*
    case full
    /// *Go to a folder, person, or action…*
    case short
}

/// The open field's width and placeholder, resolved with the rest of the toolbar rather than by the
/// field itself (see `WorkspaceBarMetrics.styles`).
public struct GoToFieldLayout: Equatable, Sendable {
    public var width: CGFloat
    public var placeholder: GoToFieldPlaceholder

    public init(width: CGFloat, placeholder: GoToFieldPlaceholder) {
        self.width = width
        self.placeholder = placeholder
    }
}

/// The open field's arithmetic: floor, ceiling, chrome, and each placeholder rung's measured width.
///
/// Built from ``CommandPaletteBarMetrics``' constants, because the field is the pill grown up: the
/// two must agree on what the magnifier, gaps and keycap cost, or the row's reserve is right for
/// one and wrong for the other.
public enum GoToFieldMetrics {

    /// The narrowest the field opens before the workspace bar is asked to shed its labels. Below
    /// this a folder name and the caret stop fitting together.
    public static let floorWidth: CGFloat = 320

    /// The widest it ever opens; the results list under it shares the field's width.
    public static let ceilingWidth: CGFloat = 620

    /// A point and a half larger than the pill's word, because the field is typed into rather than
    /// read.
    public static let textPointSize: CGFloat = 13.5

    /// The key parked at the field's trailing end, which closes it. Named once for both the field
    /// that draws it and the arithmetic that reserves its room; if they disagree, nothing shows
    /// until the toolbar folds behind a chevron.
    public static let closeKeycap = "esc"

    /// The two invitations. The short one keeps the nouns a stranger can't guess, folder and
    /// person, and drops "place", which the list shows first.
    public static let fullPlaceholder = "Go to a place, a folder, a person, or an action…"
    public static let shortPlaceholder = "Go to a folder, person, or action…"

    /// Everything in the field that isn't text: the pill's paddings, glyph and gap, plus the
    /// trailing key. Taken from ``CommandPaletteBarMetrics``, not restated, so the reserve can't be
    /// right for the closed control and wrong for the open one; that failure shows only once the
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
