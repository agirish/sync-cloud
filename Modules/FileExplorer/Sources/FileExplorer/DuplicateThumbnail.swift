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

    /// What identifies one rendered preview: the file, the size it was drawn at, and the version of
    /// the file it was drawn from.
    ///
    /// **One expression, because two ends of a lookup that spell a key separately come to disagree.**
    /// ``cached(path:side:scale:modified:)`` has to produce byte-identical keys to ``image`` or it
    /// silently answers nil for entries that are sitting right there — a miss that looks exactly
    /// like a cold cache and would make the peek below a no-op nobody could see was broken.
    private static func key(path: String, side: CGFloat, scale: CGFloat, modified: Date?) -> String {
        "\(path)|\(Int(side))|\(Int(scale))|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    /// The already-decoded preview for this key, or nil — **without suspending**.
    ///
    /// **Why a synchronous peek exists at all.** ``image`` is `async`, so its caller can only reach
    /// it from a `.task`, which runs *after* the first render. The cache itself is `static` and
    /// outlives every view, so on a return to Duplicates the entries are still there — but the
    /// view's `@State` starts nil, so the tile drew the generic file-type icon for one frame before
    /// the task resumed and put the real preview back. That flash is the whole of the "thumbnails
    /// reload when I come back" complaint: nothing is re-requested, and for a cache hit nothing is
    /// even recomputed. It is one frame of the fallback, and this removes it.
    ///
    /// Deliberately does **not** consult ``declined``: a refusal means "there is no image", which is
    /// what returning nil already says, and the caller's fallback is the same either way.
    @MainActor
    static func cached(path: String, side: CGFloat, scale: CGFloat, modified: Date?) -> NSImage? {
        imageCache.object(forKey: key(path: path, side: side, scale: scale, modified: modified) as NSString)
    }

    /// Puts one rendered preview in the cache.
    ///
    /// Extracted from ``image`` rather than written beside it so a test can warm the cache through
    /// the **production** store — a test that inserted by its own spelling of the key would prove
    /// only that it agrees with itself, which is precisely the failure ``key`` exists to prevent.
    @MainActor
    static func store(_ image: NSImage, path: String, side: CGFloat, scale: CGFloat, modified: Date?) {
        imageCache.setObject(image, forKey: key(path: path, side: side, scale: scale, modified: modified) as NSString)
    }

    @MainActor
    static func image(path: String, side: CGFloat, scale: CGFloat, modified: Date?) async -> NSImage? {
        let key = Self.key(path: path, side: side, scale: scale, modified: modified)
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
        store(image, path: path, side: side, scale: scale, modified: modified)
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

    /// The picture to draw: what the task has loaded, or — before it has run — whatever the shared
    /// cache is already holding for this exact key.
    ///
    /// **The fallback is what survives a workspace switch.** Leaving Organize destroys this view, so
    /// `image` comes back nil and the `.task` below cannot answer until after the first render.
    /// ``DuplicateThumbnail/imageCache`` is `static` and survives, so for a tile that has been shown
    /// before the answer is already in hand and the generic icon never has to be drawn at all.
    ///
    /// Reads the same `side` and `scale` the task asks with, because a peek keyed differently from
    /// the store is a permanent miss — see ``DuplicateThumbnail/key(path:side:scale:modified:)``.
    ///
    /// Non-private so `DuplicateThumbnailCacheTests` can pin it, on the same reasoning
    /// `FileTreeView.expansionPruned` is: the alternative is a decision reachable only by rendering
    /// a tile and looking at it, and "it drew the icon rather than the picture" is not something a
    /// render can be asked.
    var shownImage: NSImage? {
        if let image { return image }
        guard loadsPreview else { return nil }
        return DuplicateThumbnail.cached(path: path, side: side,
                                         scale: previewScale, modified: modified)
    }

    /// The scale a preview for this tile is rendered and looked up at.
    ///
    /// **One expression, read by both the peek above and the task below.** They were two copies of
    /// `max(1, displayScale)` for exactly as long as it took to write them, and two copies is how a
    /// peek comes to ask for a key the store never wrote: change the task's scale and the cache
    /// still fills, `cached` still answers, and it answers **nil forever** — a silent return to the
    /// one-frame flash with a green suite and nothing on screen to say why.
    var previewScale: CGFloat { max(1, displayScale) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                if let image = shownImage {
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
            // `previewScale`, not a second `max(1, displayScale)` — see that member for what the
            // second copy costs the peek above.
            image = await DuplicateThumbnail.image(path: path, side: side, scale: previewScale, modified: modified)
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
