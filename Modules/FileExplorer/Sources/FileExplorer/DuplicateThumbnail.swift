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
/// with the keeper sealed in green.
///
/// **Presentation, not a control — and it was briefly both, which is the interesting part.** The
/// tile was made clickable to answer "the thumbnails aren't really functional?", and then the whole
/// row was made clickable to answer "it's not obvious that only the thumbnail needs to be clicked".
/// The second change did not retire the first: `DuplicateGroupCard.copyRow` wraps the row in a
/// `Button` under exactly the condition that made the tile clickable — `isRowPickable` and the
/// tile's old `choice` were both `DuplicateKeeperMarker.style(…) == .selectable`, the same
/// predicate — so every pickable row carried two hit targets, two `.help` tooltips, two hover
/// treatments, and two nested `.isButton` elements announcing one action twice.
///
/// Nothing here fires the pick any more. The row does, once. What the tile keeps is the part only
/// it can say: which copy this is a picture of, and whether it is the one being kept.
///
/// The hover lift went with the click. It was defended as an affordance — "it appears only where
/// the tile can actually be clicked" — but an affordance for a control that is now the row's is
/// just motion, and `HoverAffordance`'s own table has no hover scale at all: the only scale in it
/// is the 0.97 press. The row's wash is the affordance now.
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
    /// Whether the word under the tile is drawn.
    ///
    /// **False in a copy row, where the row already says it.** The tile sits beside a fate chip
    /// reading "Keep" or "Move to Trash"; a caption reading "keeper" under it is the same fact a
    /// second time, in the vertical space that made the old thumbnail strip its own band.
    var showsCaption: Bool = true
    /// Whether to ask QuickLook for a real preview, or settle for the file-type icon.
    ///
    /// **The cap the thumbnail strip used to carry.** That strip rendered at most six tiles; the
    /// inline rows render one per copy, so a forty-copy group would kick off forty QuickLook
    /// generations the moment it is expanded. The tile is still the picker either way — only the
    /// picture is skipped.
    var loadsPreview: Bool = true

    @State private var image: NSImage?

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
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
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
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

            // "duplicate" is the identical group's word and it overclaims for a same-text one,
            // where all that is proven is that the two READ alike — the caller passes the group's
            // own vocabulary so the thumbnail cannot say more than the badge above it.
            if showsCaption {
                Text(isKeeper ? "keeper" : nonKeeperLabel)
                    .scaledFont(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isKeeper ? AnyShapeStyle(SemanticColor.success)
                                              : AnyShapeStyle(.tertiary))
            }
        }
        .task(id: "\(path)|\(modified?.timeIntervalSince1970 ?? 0)|\(loadsPreview)") {
            guard loadsPreview else { return }
            image = await DuplicateThumbnail.image(path: path, side: side, scale: max(1, displayScale), modified: modified)
        }
        // **No tooltip here at all.** An inner `.help` wins over its container's, so a `.help` on
        // the tile would carve the one part of a clickable row that refuses to say what clicking
        // it does. `DuplicateGroupCard.copyRow` states the action AND the path, once, for the
        // whole row.
        // **One element, no traits.** The tile is inside a row that is itself a `Button`, so a
        // `.isButton` here would put a control inside a control: VoiceOver announces two nested
        // buttons, with the same hint, for one action. The row is the control; this is its picture.
        .accessibilityElement()
        .accessibilityLabel(isKeeper ? "Kept copy preview" : "Duplicate copy preview")
    }
}
