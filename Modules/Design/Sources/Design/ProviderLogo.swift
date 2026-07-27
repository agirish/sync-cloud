import SwiftUI

/// A cloud provider's brand mark, rendered on the ground it was drawn for.
///
/// The one place a provider logo is drawn. It exists because these four assets share a property
/// that only shows up on a dark appearance: measured at their rendered size, **not one of them
/// paints a single opaque near-white pixel** (0 of 113k-156k opaque pixels, all four). The white
/// in them — Dropbox's folded-box seams, Google Drive's triangle seams, the gap between OneDrive's
/// lobes — is not painted, it is *transparent*, supplied by the page behind. A light appearance
/// supplies it. A dark one supplies nothing, so the marks lose their internal structure and read
/// as coloured blobs.
///
/// Luminance is a red herring here and tuning the artwork would have been the wrong fix: against a
/// stable dark surface these marks measure 2.0-5.0:1 median, *better* than they do in light mode.
/// What dark takes away is not contrast, it is the page. So on a dark appearance the mark gets a
/// light plate of its own.
///
/// Deliberately behind the LOGO and not behind the whole provider capsule. The name beside it wears
/// `ProviderHue.tint`, whose dark variants are lifted specifically to clear AA on a DARK ground
/// (iCloud's is `#6FB6FF`); lightening the pill under them would trade a legible logo for an
/// illegible name. The plate is the mark's page, not the capsule's.
///
/// Metrically identical in both appearances — the plate is exactly `size`, and the mark insets
/// *within* it — so the provider capsule's `ViewThatFits` ladder picks the same rung either way.
public struct ProviderLogo: View {
    private let imageName: String
    private let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(_ imageName: String, size: CGFloat) {
        self.imageName = imageName
        self.size = size
    }

    public var body: some View {
        let onPlate = colorScheme == .dark
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: size * (onPlate ? Self.markScale : 1),
                   height: size * (onPlate ? Self.markScale : 1))
            // The outer frame is the view's size in BOTH appearances, so adding the plate cost the
            // header no width and cannot move the ladder.
            .frame(width: size, height: size)
            .background {
                if onPlate {
                    RoundedRectangle(cornerRadius: size * Self.cornerScale, style: .continuous)
                        .fill(Self.plate)
                }
            }
    }

    /// The mark's share of the plate; the remainder is the margin a printed logo carries on a page.
    /// Below about 0.7 the plate starts reading as a button rather than as the mark's ground.
    static let markScale: CGFloat = 0.76

    /// Proportional so a 16pt logo in the Tidy rail and a 28pt one in the pane header wear the same
    /// shape rather than the same absolute radius, which at 16pt would be nearly a circle.
    static let cornerScale: CGFloat = 0.25

    /// Not pure white: at full strength the plate reads as a light leak punched through a dark
    /// header. This is as bright as it can go while still sitting *in* the surface.
    static let plate = Color.white.opacity(0.93)
}
