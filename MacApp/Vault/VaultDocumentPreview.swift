import AppKit
import Design
import QuickLookThumbnailing
import SwiftUI
import Sync

/// The first page of the document a number was read from, at the top of the detail pane, so it
/// is plain which document is meant.
///
/// The scan prints the number in full, so nothing of it is drawn, or even rendered, until the
/// number may be shown: a hidden number's preview is a page shape and "Show to Preview", which
/// asks for the same proof as Show. Once shown, a click opens Quick Look. The rendering is
/// Quick Look's own thumbnail, made on this Mac and kept only while the number shows.
struct VaultDocumentPreview: View {
    let path: String
    let shown: Bool
    let onTap: () -> Void

    /// The rendered page, with the file it was rendered from: drawn only for that file, so a
    /// render that finishes late never shows one number's scan under another's.
    @State private var rendered: (path: String, image: NSImage)?
    @Environment(\.displayScale) private var displayScale

    private var image: NSImage? { rendered.flatMap { $0.path == path ? $0.image : nil } }

    static let height: CGFloat = 190

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: Radius.well)
                    .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
                if shown, let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 10)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 26)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: shown ? "doc" : "doc.viewfinder")
                            .scaledFont(.title.weight(.light))
                            .foregroundStyle(.secondary)
                        if !shown {
                            Text("Show to Preview")
                                .scaledFont(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.background.opacity(0.85)))
                                .overlay(Capsule().strokeBorder(.quaternary))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 14)
                }
                HStack(spacing: 6) {
                    // The file's name can hold the number too: masked while the number is.
                    Text(shown ? (path as NSString).lastPathComponent : VaultMask.fileName(path))
                        .scaledFont(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if shown {
                        Text("Space for Quick Look")
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: Radius.well).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: Radius.well))
        }
        .buttonStyle(.plain)
        .help(shown ? "Quick Look" : "Show the ID to see its document")
        .accessibilityLabel(shown ? "Document preview. Opens Quick Look" : "Document preview, hidden until the ID is shown")
        // Rendered only while the number may be shown, and let go the moment it hides.
        .task(id: shown ? path : nil) {
            guard shown else { rendered = nil; return }
            let wanted = path
            let made = await Self.thumbnail(wanted, scale: displayScale)
            // Quick Look's render is not cancelled with the task: one that lands after the number
            // hid, or after another was chosen (either cancels this task), is let go.
            guard !Task.isCancelled, let made else { return }
            rendered = (wanted, made)
        }
        .onChange(of: shown) { _, now in if !now { rendered = nil } }
    }

    private static func thumbnail(_ path: String, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                   size: CGSize(width: 320, height: height - 36),
                                                   scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
