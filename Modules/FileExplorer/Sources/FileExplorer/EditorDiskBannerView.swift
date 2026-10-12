import SwiftUI
import Design

/// What a press on the disk banner asks for (TE59) — answered by the host, which owns the alert,
/// the diff overlay and the writes.
public enum EditorDiskBannerAction: Equatable, Sendable {
    /// Show the buffer and the file on disk side by side — the existing diff overlay.
    case compare
    /// Write the buffer over the version on disk, after the same consent the save-over-divergence
    /// alert asks for.
    case keepMine
    /// Replace the buffer with the version on disk, as one step ⌘Z takes back.
    case useDisks
    /// Put the document away.
    case close
    /// Write the text back where the file was.
    case saveAgain
}

/// **The banner in the document card while a change from elsewhere waits for an answer** (TE59).
///
/// In the card, above the text and with the read-only banner's shape, rather than an alert: the
/// question is not urgent — nothing is being written while it stands (the host has stopped
/// autosave) — and an alert would take the text away from somebody who wants to read both versions
/// before answering. Amber, as the header's stopped state is, because it is that state.
struct EditorDiskBannerView: View {

    let banner: EditorDiskBanner
    let name: String
    /// Save Again is offered only where the document could be written at all.
    let canSaveAgain: Bool
    let onAction: (EditorDiskBannerAction) -> Void

    /// The buttons, in order — a value so a test can read them without a rendered banner.
    static func actions(for banner: EditorDiskBanner, canSaveAgain: Bool) -> [EditorDiskBannerAction] {
        switch banner {
        case .changed: return [.compare, .keepMine, .useDisks]
        case .deleted: return canSaveAgain ? [.close, .saveAgain] : [.close]
        }
    }

    static func title(_ action: EditorDiskBannerAction) -> String {
        switch action {
        case .compare: return "Compare"
        case .keepMine: return "Keep Mine"
        case .useDisks: return "Use the Disk's"
        case .close: return "Close"
        case .saveAgain: return "Save Again"
        }
    }

    static func help(_ action: EditorDiskBannerAction) -> String {
        switch action {
        case .compare: return "Show your version and the one on disk side by side"
        case .keepMine: return "Write your version over the one on disk — the changes made elsewhere are lost"
        case .useDisks: return "Replace your typing with the version on disk — ⌘Z brings it back"
        case .close: return "Close the document — the text on screen is the only copy left"
        case .saveAgain: return "Write the text back where the file was"
        }
    }

    var body: some View {
        // Wraps rather than truncates: the buttons go under the sentence in a narrow column, and the
        // sentence is the part that must be read whole.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                sentence
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 6) {
                sentence
                buttons
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
    }

    private var sentence: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: banner == .changed ? "exclamationmark.triangle" : "questionmark.folder")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(banner.message(name: name))
                .scaledFont(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            ForEach(Self.actions(for: banner, canSaveAgain: canSaveAgain), id: \.self) { action in
                Button(Self.title(action)) { onAction(action) }
                    .controlSize(.small)
                    .help(Self.help(action))
            }
        }
        .fixedSize()
    }
}
