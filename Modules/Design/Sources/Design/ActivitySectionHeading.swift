import SwiftUI

/// A section heading in the Activity window: the run list's "Running", the Now tab's sections,
/// Cloud Apps and the one-way sync lists. Small semibold secondary text, a header to VoiceOver.
public struct ActivitySectionHeading: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .scaledFont(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
