import SwiftUI
import Design

/// What a press on the disk banner asks for, answered by the host, which owns the alert, the diff
/// overlay and the writes.
public enum EditorDiskBannerAction: Equatable, Sendable {
    /// Show the buffer and the file on disk side by side, in the diff overlay.
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

/// The answers to "the file changed on disk", in one set of words: the banner, the ⌘S alert
/// (`EditorAlerts.divergenceButtonTitles`) and the comparison sheet's foot all read them here, so
/// the banner's Compare… opens a sheet whose buttons are the banner's own. One order too: Compare…,
/// Use Disk Version, Keep Mine…. Save Again is for a file that's gone, on the banner and in the ⌘S
/// alert alike.
///
/// Keep Mine… carries an ellipsis everywhere because it always asks "Replace the version on disk
/// with yours?" before it writes. Compare… opens the sheet; Use Disk Version acts at once.
public enum EditorDiskVerbs {
    public static let compare = "Compare…"
    public static let keepMine = "Keep Mine…"
    public static let useDiskVersion = "Use Disk Version"
    public static let saveAgain = "Save Again"
}

/// The banner in the document card while a change from elsewhere waits for an answer.
///
/// In the card, not an alert: nothing is written while it stands (the host has stopped autosave),
/// and an alert would take the text away from somebody who wants to read both versions first.
/// Amber, because it is the header's stopped state.
///
/// Floats over the card's foot, above the status line, so nothing moves under a pointer when a
/// change is noticed. It stands on the floating ground Edit's other floating pieces use, and the
/// text view gains a bottom inset of its height (``EditorWorkspaceView``) so the last lines scroll
/// clear of it.
struct EditorDiskBannerView: View {

    let banner: EditorDiskBanner
    let name: String
    /// Save Again is offered only where the document could be written at all.
    let canSaveAgain: Bool
    let onAction: (EditorDiskBannerAction) -> Void

    /// The buttons, in order: a value so a test can read them without a rendered banner.
    static func actions(for banner: EditorDiskBanner, canSaveAgain: Bool) -> [EditorDiskBannerAction] {
        switch banner {
        case .changed: return [.compare, .useDisks, .keepMine]
        case .deleted: return canSaveAgain ? [.close, .saveAgain] : [.close]
        }
    }

    static func title(_ action: EditorDiskBannerAction) -> String {
        switch action {
        case .compare: return EditorDiskVerbs.compare
        case .keepMine: return EditorDiskVerbs.keepMine
        case .useDisks: return EditorDiskVerbs.useDiskVersion
        case .close: return "Close"
        case .saveAgain: return EditorDiskVerbs.saveAgain
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

    /// The find card's shape, one outline for the amber and the ground under it.
    static let shape: HoverAffordanceShape = .roundedRect(Radius.card)

    var body: some View {
        // Wraps rather than truncates: in a narrow column the buttons go under the sentence, which
        // must be read whole.
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
        // The amber over the ground, not instead of it: the text runs under this card.
        .background(Self.shape.outline.fill(Color.orange.opacity(0.12)))
        .modifier(EditorPDFFloatingGround(shape: Self.shape))
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

/// Why the open document is read-only (text that isn't all valid, or a file that changed on disk
/// and can no longer be read), floating over the text's foot above the disk banner
/// (``EditorWorkspaceView``) so the format bar and text don't move when it appears. Grey on the
/// banner's ground: it asks nothing.
struct EditorReadOnlyNoteView: View {
    let reason: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(.system(size: 11))
                .accessibilityHidden(true)
            Text(reason)
                .scaledFont(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(EditorPDFFloatingGround(shape: EditorDiskBannerView.shape))
        .accessibilityElement(children: .combine)
    }
}
