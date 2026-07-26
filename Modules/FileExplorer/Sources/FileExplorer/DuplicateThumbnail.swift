import SwiftUI
import AppKit
import QuickLookThumbnailing
import Design

/// Async QuickLook content thumbnails for duplicate copies. The duplicate card already names each
/// copy, marks the keeper, and shows a fate chip — but every copy wore the same file-type icon, so
/// for photos, scans, and PDFs you couldn't *see* that the copies matched before trashing them.
/// This renders a real preview per copy, keeper sealed, so "probably safe" becomes "obviously safe".
///
/// Generation crosses an actor boundary, so under the Swift 6 language mode nothing non-Sendable may
/// travel with it: the background generator hands back PNG `Data` (Sendable) and the `NSImage` is
/// built and cached on the main actor.
enum DuplicateThumbnail {
    /// Bounded, self-purging cache of decoded previews — an unbounded dict would grow with every
    /// duplicate file viewed across a session, and `NSCache` also drops entries under memory
    /// pressure. Keyed by path + size + scale + modification time, so a re-scan where a file's
    /// content changed regenerates rather than serving a stale preview.
    @MainActor private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    @MainActor
    static func image(path: String, side: CGFloat, scale: CGFloat, modified: Date?) async -> NSImage? {
        let key = "\(path)|\(Int(side))|\(Int(scale))|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let data = await pngData(path: path, side: side, scale: scale),
              let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Renders the best QuickLook thumbnail and returns it as PNG `Data` — Sendable, so it can cross
    /// back to the main actor. Runs the render on QuickLook's own queue; returns nil when the file
    /// can't be previewed (unreadable, vanished, or an opaque type), and the caller falls back to the
    /// file-type icon.
    nonisolated private static func pngData(path: String, side: CGFloat, scale: CGFloat) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let cgImage = representation?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
            }
        }
    }
}

/// One copy's content thumbnail — a QuickLook preview when available, the file-type icon otherwise —
/// with the keeper sealed in green and a subtle lift on hover ("enlarge on hover").
struct DuplicateThumbnailView: View {
    let path: String
    let name: String
    let isKeeper: Bool
    /// The copy's modification date — part of the cache key, so a re-scan that changed the file's
    /// content refreshes the preview instead of serving the stale one.
    let modified: Date?
    var side: CGFloat = 54

    @State private var image: NSImage?
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(nsImage: FileIconCache.icon(name: name, isDirectory: false))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side * 0.5, height: side * 0.5)
                }
            }
            .frame(width: side, height: side * 1.2)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isKeeper ? SemanticColor.success.opacity(0.65) : Color.primary.opacity(0.12),
                                  lineWidth: isKeeper ? 1.5 : 0.8)
            )
            .overlay(alignment: .bottomTrailing) {
                if isKeeper {
                    Image(systemName: "checkmark.seal.fill")
                        .scaledFont(.system(size: 15))
                        .foregroundStyle(SemanticColor.success)
                        // Adaptive knockout disc: hard-coded white glowed in dark mode.
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2))
                        .offset(x: 4, y: 4)
                }
            }
            .shadow(color: .black.opacity(isHovering ? 0.22 : 0), radius: isHovering ? 7 : 0, y: isHovering ? 3 : 0)
            // Modest lift — kept small so it doesn't clip against the horizontal scroll container.
            .scaleEffect(isHovering && !reduceMotion ? 1.1 : 1)
            .zIndex(isHovering ? 1 : 0)

            Text(isKeeper ? "keeper" : "duplicate")
                .scaledFont(.system(size: 10, design: .monospaced))
                .foregroundStyle(isKeeper ? AnyShapeStyle(SemanticColor.success) : AnyShapeStyle(.tertiary))
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
        .task(id: "\(path)|\(modified?.timeIntervalSince1970 ?? 0)") {
            image = await DuplicateThumbnail.image(path: path, side: side, scale: max(1, displayScale), modified: modified)
        }
        .help(path)
        .accessibilityElement()
        .accessibilityLabel(isKeeper ? "Kept copy preview" : "Duplicate copy preview")
    }
}
