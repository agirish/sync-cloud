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
/// travel with it. What travels is the immutable `CGImage` QuickLook produced, in a box that
/// asserts what the compiler cannot see (``RenderedThumbnail``); the `NSImage` wrapper is built and
/// cached on the main actor.
///
/// **It used to travel as PNG `Data`, and the round trip was the whole cost.** `Data` is Sendable
/// without an assertion, so the hop was paid for by compressing the thumbnail on QuickLook's queue
/// and decompressing it again — the decompression landing on the main thread at DRAW time, since
/// `NSImage(data:)` is lazy, which is to say during the scroll that asked for it. Neither half was
/// wanted; both existed to satisfy `Sendable`, and an immutable reference satisfies it for free.
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

    /// Keys QuickLook has already declined, so a file it cannot preview isn't re-requested every
    /// time its card scrolls back into view.
    ///
    /// A separate set rather than a sentinel in `imageCache`, because the two want opposite
    /// eviction behaviour: dropping a cached IMAGE under memory pressure costs one regeneration,
    /// while dropping the memory of a REFUSAL costs a full generator round-trip that is already
    /// known to fail. Bounded by the same rule `DetailsMetadataCache.warnedPaths` uses — cleared
    /// wholesale at the cap, which is O(1) and costs at most one repeated request per key after.
    @MainActor private static var declined: Set<String> = []
    private static let maxDeclined = 512

    @MainActor
    static func image(path: String, side: CGFloat, scale: CGFloat, modified: Date?) async -> NSImage? {
        let key = "\(path)|\(Int(side))|\(Int(scale))|\(modified?.timeIntervalSince1970 ?? 0)"
        if let hit = imageCache.object(forKey: key as NSString) { return hit }
        // The key carries the modification date, so a file whose CONTENT changed gets a new key
        // and a fresh attempt — a refusal is remembered for one version of one file, not forever.
        if declined.contains(key) { return nil }
        guard let rendered = await render(path: path, side: side, scale: scale) else {
            if declined.count >= maxDeclined { declined.removeAll() }
            declined.insert(key)
            return nil
        }
        // Sized in PIXELS, which is what the PNG round trip also produced: `NSBitmapImageRep`
        // carried the CGImage's pixel dimensions at 72dpi, and reading the PNG back gave an
        // `NSImage` of that same size. The view draws `.resizable().aspectRatio(.fit)` inside a
        // fixed frame, so only the RATIO reaches the screen — but matching the old size exactly
        // keeps that an observation rather than something to re-verify.
        let image = NSImage(cgImage: rendered.cgImage,
                            size: CGSize(width: rendered.cgImage.width, height: rendered.cgImage.height))
        imageCache.setObject(image, forKey: key as NSString)
        return image
    }

    /// The immutable `CGImage` ferried back from QuickLook's queue.
    ///
    /// `@unchecked` because `CGImage` carries no Sendable conformance, not because anything here is
    /// unsound: a `CGImage` is immutable once created, this one is created inside the generator
    /// callback and never handed anywhere else, and nothing on either side of the hop mutates it.
    private struct RenderedThumbnail: @unchecked Sendable {
        let cgImage: CGImage
    }

    /// Renders the best QuickLook thumbnail. Runs the render on QuickLook's own queue; returns nil
    /// when the file can't be previewed (unreadable, vanished, or an opaque type), and the caller
    /// falls back to the file-type icon.
    nonisolated private static func render(path: String, side: CGFloat, scale: CGFloat) async -> RenderedThumbnail? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail)
        return await withCheckedContinuation { (continuation: CheckedContinuation<RenderedThumbnail?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let cgImage = representation?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: RenderedThumbnail(cgImage: cgImage))
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
    /// What a non-keeper copy is called under its thumbnail. Defaulted to the identical group's
    /// word so every existing call site is unchanged.
    var nonKeeperLabel: String = "duplicate"
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

            // "duplicate" is the identical group's word and it overclaims for a same-text one,
            // where all that is proven is that the two READ alike — the caller passes the group's
            // own vocabulary so the thumbnail cannot say more than the badge above it.
            Text(isKeeper ? "keeper" : nonKeeperLabel)
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
