import SwiftUI
import AppKit
import QuickLookThumbnailing
import Design

/// Async QuickLook content thumbnails for duplicate copies, so for photos, scans and PDFs you can
/// see that the copies match before trashing them, with the keeper sealed.
///
/// Generation crosses an actor boundary, so under Swift 6 nothing non-Sendable may travel with it.
/// What travels is the immutable `CGImage` QuickLook produced, in a box that asserts what the
/// compiler can't see (``RenderedThumbnail``); the `NSImage` is built and cached on the main actor.
/// Not PNG `Data`: that round trip compressed on QuickLook's queue and decompressed lazily on the
/// main thread at draw time, during the scroll that asked for it.
enum DuplicateThumbnail {
    /// Where decoded previews are kept between the task that stores one and the peek that reads it
    /// back. The shelf only: the key is always ``key(path:side:scale:modified:)``'s.
    ///
    /// A protocol because the app's shelf can be emptied by the OS between two lines. It is an
    /// `NSCache` (``PurgingStorage``), and a memory-pressure warn freezes each cache at its current
    /// entry count, so one that is empty then evicts every `setObject` before the next line can
    /// read it, until the pressure clears. Right for the app, fatal to a test that stores and
    /// peeks, so the tests hand in a shelf of their own; see "An NSCache emptied by memory pressure
    /// between a store and the next line" in docs/flaky-tests.md.
    @MainActor protocol Storage: AnyObject, Sendable {
        func image(forKey key: String) -> NSImage?
        func setImage(_ image: NSImage, forKey key: String)
    }

    /// The app's shelf: bounded, and `NSCache` also drops entries under memory pressure, where a
    /// dict would grow with every duplicate viewed in a session.
    @MainActor private final class PurgingStorage: Storage {
        private let cache = NSCache<NSString, NSImage>()

        init(countLimit: Int) { cache.countLimit = countLimit }

        func image(forKey key: String) -> NSImage? { cache.object(forKey: key as NSString) }

        func setImage(_ image: NSImage, forKey key: String) {
            cache.setObject(image, forKey: key as NSString)
        }
    }

    /// The one shelf every tile shares, and the only one the app makes. Keyed by path, size, scale
    /// and modification time, so a re-scan of a changed file regenerates instead of serving a stale
    /// preview. `static`, so it outlives every view and a tile rebuilt after a workspace switch
    /// finds the picture an earlier one stored; see ``DuplicateThumbnailView/previews``.
    @MainActor static let imageCache: any Storage = PurgingStorage(countLimit: 256)

    /// Keys QuickLook has already declined, so a file it can't preview isn't re-requested every
    /// time its card scrolls back into view.
    ///
    /// A separate set rather than a sentinel in `imageCache`, because evicting a cached image costs
    /// one regeneration while forgetting a refusal costs a round trip known to fail. Cleared
    /// wholesale at the cap, like `DetailsMetadataCache.warnedPaths`. One set whichever ``Storage``
    /// the caller hands ``image``: a refusal is a fact about the file, not the shelf.
    @MainActor private static var declined: Set<String> = []
    private static let maxDeclined = 512

    /// What identifies one rendered preview: the file, the size it was drawn at, and the version of
    /// the file it was drawn from.
    ///
    /// One expression, so both ends of a lookup agree: if ``cached(path:side:scale:modified:)``
    /// spelled its key differently from ``image``, it would silently miss entries that are right
    /// there, a miss that looks exactly like a cold cache.
    private static func key(path: String, side: CGFloat, scale: CGFloat, modified: Date?) -> String {
        "\(path)|\(Int(side))|\(Int(scale))|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    /// The already-decoded preview for this key, or nil, without suspending.
    ///
    /// ``image`` is `async`, so it is reachable only from a `.task`, which runs after the first
    /// render. The cache outlives every view, but the view's `@State` starts nil, so without this
    /// peek a tile draws the file-type icon for one frame on a return to Duplicates before the task
    /// puts the preview back.
    ///
    /// Doesn't consult ``declined``: a refusal means "no image", which nil already says.
    @MainActor
    static func cached(path: String, side: CGFloat, scale: CGFloat, modified: Date?,
                       in storage: any Storage) -> NSImage? {
        storage.image(forKey: key(path: path, side: side, scale: scale, modified: modified))
    }

    /// Puts one rendered preview in the cache. Separate from ``image`` so a test can warm the cache
    /// through the production key; a test spelling the key itself would only agree with itself. The
    /// shelf is a parameter so the test can warm its own, since the app's may drop the entry before
    /// the next line's peek; see ``Storage``.
    @MainActor
    static func store(_ image: NSImage, path: String, side: CGFloat, scale: CGFloat, modified: Date?,
                      in storage: any Storage) {
        storage.setImage(image, forKey: key(path: path, side: side, scale: scale, modified: modified))
    }

    @MainActor
    static func image(path: String, side: CGFloat, scale: CGFloat, modified: Date?,
                      in storage: any Storage) async -> NSImage? {
        let key = Self.key(path: path, side: side, scale: scale, modified: modified)
        if let hit = storage.image(forKey: key) { return hit }
        // The key carries the modification date, so a file whose content changed gets a fresh
        // attempt: a refusal is remembered for one version of one file, not forever.
        if declined.contains(key) { return nil }
        guard let rendered = await render(path: path, side: side, scale: scale) else {
            if declined.count >= maxDeclined { declined.removeAll() }
            declined.insert(key)
            return nil
        }
        // Sized in pixels at 72dpi, as the earlier PNG round trip produced. The view draws it
        // `.resizable().aspectRatio(.fit)` in a fixed frame, so only the ratio reaches the screen.
        let image = NSImage(cgImage: rendered.cgImage,
                            size: CGSize(width: rendered.cgImage.width, height: rendered.cgImage.height))
        store(image, path: path, side: side, scale: scale, modified: modified, in: storage)
        return image
    }

    /// The immutable `CGImage` ferried back from QuickLook's queue.
    ///
    /// `@unchecked` because `CGImage` has no Sendable conformance, not because anything is unsound:
    /// it is immutable, created inside the generator callback, and never mutated on either side of
    /// the hop.
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

/// One copy's content thumbnail, a QuickLook preview when available and the file-type icon
/// otherwise, with the keeper sealed in green.
///
/// Presentation, not a control. `DuplicateGroupCard.copyRow` makes the whole row the button for
/// picking the keeper; a clickable tile inside it would add a second hit target, tooltip, hover
/// treatment and nested `.isButton` for the same action. The tile says only which copy this is a
/// picture of and whether it is being kept. No hover lift either: the row's wash is the affordance.
struct DuplicateThumbnailView: View {
    let path: String
    let name: String
    let isKeeper: Bool
    /// The copy's modification date, part of the cache key, so a re-scan that changed the file
    /// refreshes the preview.
    let modified: Date?
    /// What a non-keeper copy is called under its thumbnail. Defaults to the identical group's
    /// word.
    var nonKeeperLabel: String = "duplicate"
    var side: CGFloat = 54
    /// Whether the word under the tile is drawn. False in a copy row, where the fate chip beside
    /// the tile ("Keep" or "Move to Trash") already says it.
    var showsCaption: Bool = true
    /// Whether to ask QuickLook for a real preview, or settle for the file-type icon. The card caps
    /// it, so expanding a forty-copy group doesn't start forty QuickLook generations.
    var loadsPreview: Bool = true
    /// Where this tile keeps and looks up its previews: always ``DuplicateThumbnail/imageCache`` in
    /// the app.
    ///
    /// The default matters: the peek in ``shownImage`` removes the icon flash only because every
    /// tile looks on the one shelf that outlived the last, and `DuplicateThumbnailCacheTests` pins
    /// it by identity. The tests pass their own because the app's is an `NSCache` the OS may empty
    /// between a store and the next line; see ``DuplicateThumbnail/Storage``.
    var previews: any DuplicateThumbnail.Storage = DuplicateThumbnail.imageCache

    @State private var image: NSImage?

    @Environment(\.displayScale) private var displayScale

    /// The picture to draw: what the task has loaded, or, before it has run, whatever the shared
    /// cache already holds for this exact key.
    ///
    /// Leaving Organize destroys this view, so `image` comes back nil and the `.task` can't answer
    /// until after the first render; the static cache survives, so a tile shown before never draws
    /// the generic icon. Reads the same `side`, `scale` and shelf the task stores with, since a
    /// peek keyed differently is a permanent miss; see
    /// ``DuplicateThumbnail/key(path:side:scale:modified:)``.
    ///
    /// Non-private so `DuplicateThumbnailCacheTests` can pin it, as with
    /// `FileTreeView.expansionPruned`: "it drew the icon rather than the picture" can't be asked of
    /// a render.
    var shownImage: NSImage? {
        if let image { return image }
        guard loadsPreview else { return nil }
        return DuplicateThumbnail.cached(path: path, side: side,
                                         scale: previewScale, modified: modified, in: previews)
    }

    /// The scale a preview for this tile is rendered and looked up at. One expression for the peek
    /// and the task: if the task's scale changed alone, the cache would still fill but `cached`
    /// would answer nil forever, bringing back the one-frame flash with a green suite.
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

            // "duplicate" overclaims for a same-text group, where all that is proven is that the
            // copies read alike, so the caller passes the group's own word.
            if showsCaption {
                Text(isKeeper ? "keeper" : nonKeeperLabel)
                    .scaledFont(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isKeeper ? AnyShapeStyle(SemanticColor.success)
                                              : AnyShapeStyle(.tertiary))
            }
        }
        .task(id: "\(path)|\(modified?.timeIntervalSince1970 ?? 0)|\(loadsPreview)") {
            guard loadsPreview else { return }
            // `previewScale`, not a second `max(1, displayScale)`; see that member.
            image = await DuplicateThumbnail.image(path: path, side: side, scale: previewScale,
                                                   modified: modified, in: previews)
        }
        // No tooltip: an inner `.help` wins over its container's, so one here would hide the row's,
        // which `DuplicateGroupCard.copyRow` gives once with the action and the path. One element,
        // no traits: the row is itself a `Button`, and `.isButton` here would make VoiceOver
        // announce two nested buttons for one action.
        .accessibilityElement()
        .accessibilityLabel(isKeeper ? "Kept copy preview" : "Duplicate copy preview")
    }
}
