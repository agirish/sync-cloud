import SwiftUI
import Design

/// The rendered Markdown, in the app's own type ramp.
///
/// **SwiftUI text, not a web view**, which is the whole design of this surface: a `WKWebView` would
/// bring its own fonts, its own selection behaviour and its own scroll physics into a window that
/// has spent a lot of effort on all three — and would render the document at a size unrelated to
/// Settings ▸ Text size.
///
/// **Read-only except for one thing: a task item's checkbox.** Everything else here draws from the
/// document's text and cannot write back, so the buffer stays the single source of truth and
/// toggling modes cannot lose an edit. The checkbox is the exception because a checklist you can
/// read and not tick is a checklist you have to switch modes to use — and it is a safe one: the
/// click leaves through ``onToggleTask``, which rewrites exactly three characters of exactly one
/// line through ``MarkdownEdits/toggleTask(onLine:in:)``, and it is withheld entirely on a document
/// that cannot be saved.
struct MarkdownPreview: View {

    let blocks: [MarkdownBlock]
    let accent: Color
    /// Which source line the preview should bring into view, or `nil` to leave it where it is.
    ///
    /// Carries a token for the reason ``PlainTextEditor/scrollRequest`` does — and in split mode it
    /// changes constantly, once per line scrolled past on the other side.
    var scrollRequest: EditorScrollRequest?
    /// Ticks or unticks the task on a source line, or `nil` when this document must not be edited —
    /// which is what makes the checkbox a picture rather than a control on a read-only file.
    var onToggleTask: ((Int) -> Void)?
    /// The folder the open document lives in, which is what a relative image path is relative to.
    /// `nil` when nothing is open, and then no image resolves — a path with nothing to resolve
    /// against is not a path.
    var documentFolder: String?
    /// Sends the reader to a heading in this same document, for a `#fragment` link.
    var onFollowAnchor: ((String) -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            scroller
                // **The one place a link is decided.** A fragment names a heading in the document
                // already on screen, so following it is a scroll rather than a launch; everything
                // else is handed to the system. Returning `.systemAction` rather than opening it
                // here is what keeps the app out of the business of deciding which schemes are
                // acceptable — that is the system's job and it already asks.
                .environment(\.openURL, OpenURLAction { url in openLink(url) })
                // **One scroll per request, not two.** An `.onChange(of: scrollRequest)` sat here
                // as well, and it fired for exactly the requests the `.task` below already answers
                // — the task's id carries the same request — so every scroll ran twice: once
                // against rows that may not exist yet, then again a turn later. In split that is
                // two `scrollTo`s per line scrolled past on the other side. The task is the one
                // that is correct on its own (it yields first, so the `LazyVStack` rows named
                // below have been built), so it is the one that stayed.
                .task(id: EditorPreviewScrollKey(request: scrollRequest, count: blocks.count)) {
                    // One turn, so the rows named below have been built.
                    await Task.yield()
                    scroll(to: scrollRequest, with: proxy)
                }
        }
    }

    /// What a click on a link does.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        // A fragment-only link — `[go](#the-two-numbers)` — has no scheme and no path.
        let isFragmentOnly = url.scheme == nil && url.path.isEmpty
        if isFragmentOnly, let fragment = url.fragment, let onFollowAnchor {
            onFollowAnchor(fragment)
            return .handled
        }
        return .systemAction
    }

    /// Where a scroll lands, or nothing when the request names a document this preview has not
    /// rendered yet.
    private func scroll(to request: EditorScrollRequest?, with proxy: ScrollViewProxy) {
        guard let request,
              let index = MarkdownOutline.blockIndex(forLine: request.line, in: blocks) else {
            return
        }
        // **No animation.** In split this fires on every line scrolled past on the other side, and
        // an animated scroll chasing a scroll wheel lags behind it and then overshoots.
        proxy.scrollTo(index, anchor: .top)
    }

    /// What a preview scroll depends on: the request, and whether the blocks it names exist yet.
    private struct EditorPreviewScrollKey: Equatable {
        var request: EditorScrollRequest?
        var count: Int
    }

    private var scroller: some View {
        ScrollView {
            // **Lazy, because the read cap is 4 MiB.** A plain `VStack` materialises every block
            // on the main actor in one pass — moving the *parse* off it says nothing about the
            // render, and a large document is tens of thousands of blocks.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    // The arms themselves are `MarkdownBlockView`'s — shared with the printed
                    // page so that File ▸ Print's claim to be "the preview" stays true.
                    MarkdownBlockView(block: block, accent: accent, documentFolder: documentFolder,
                                      onToggleTask: onToggleTask, onFollowAnchor: onFollowAnchor)
                        // The scroll target. The index rather than the source line, because a
                        // block does not have to have one — see ``MarkdownBlock/line``.
                        .id(index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            // The measure a reader's eye can hold. Wider than this and long paragraphs become hard
            // to track back to the start of the next line.
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

}

/// One image from the document's own folder, or the reason it is not being drawn.
///
/// **Resolved AND loaded off the main actor, and only when the row is built.** The preview is a
/// `LazyVStack`, so a note with forty screenshots touches the two that are on screen.
///
/// **Resolving used to happen in the preview's `body`**, which meant `MarkdownImageSource.resolve`
/// — an existence check, a cloud-placeholder check, a symlink resolve and a `stat`, four filesystem
/// calls — ran for every visible image on every render pass. In preview or split mode that is every
/// keystroke. It is a question about a file on disk, so it belongs beside the decode, in the task
/// that already goes off the main actor for it.
///
/// The one visible consequence: a source that cannot be drawn now shows "Loading…" for the frame
/// before the answer arrives, where before the reason was known by the time anything was drawn.
struct MarkdownImageView: View {

    /// The raw `![alt](source)` text, unresolved — see the note above.
    let source: String
    /// The open document's folder, which is what a relative source resolves against.
    let folder: String?
    let alt: String
    let accent: Color
    /// An image already resolved and decoded by somebody else, or `nil` to load it here.
    ///
    /// **Paper's route in.** The load below is a `.task`, and a task does not run during an
    /// offscreen render — an image drawn that way would be the "Loading…" placeholder on every
    /// printed page, forever, with nothing on screen to say so. ``DocumentPDF`` resolves and
    /// decodes through the same two calls this view uses and hands the answer over.
    var preloaded: Preloaded?

    /// A resolved image, or the reason there is not one — the two states ``load()`` produces.
    enum Preloaded: Equatable {
        case image(NSImage)
        case refused(String)
    }

    @State private var image: NSImage?
    /// Why there is no image, or `nil` while nothing has been decided yet.
    @State private var refusal: String?

    /// The tallest an image is drawn, whatever its own size.
    ///
    /// **A cap on the DRAWN height, which is a different question from the file's byte cap.** A
    /// tall narrow image — a phone screenshot — would otherwise take four screens of a document
    /// somebody is reading for its words. Width is the column's; the aspect ratio is kept.
    static let maxHeight: CGFloat = 420

    var body: some View {
        Group {
            if case .refused(let reason) = preloaded {
                placeholder(reason)
            } else if let image = decoded {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: Self.maxHeight, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.well))
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
            } else {
                placeholder(refusal ?? "Loading…")
            }
        }
        .padding(.vertical, 6)
        // **On the `Group`, not inside the `else` arm.** Hung inside the branch that draws the
        // placeholder, the task is torn down the instant the image arrives and the branch swaps —
        // which is harmless while it has finished, and is exactly the kind of arrangement that
        // stops re-running when the source changes under a drawn image.
        // **Skipped entirely when the answer was handed over.** A preloaded image is one that
        // has already been resolved and decoded; re-doing both in a task would be four filesystem
        // calls and a decode to arrive at the picture already on screen.
        .task(id: MarkdownImageKey(source: source, folder: folder)) {
            guard preloaded == nil else { return }
            await load()
        }
    }

    /// The image to draw: the one handed over, else the one this view loaded.
    private var decoded: NSImage? {
        if case .image(let ready) = preloaded { return ready }
        return image
    }

    /// What a new image is: a different source, or the same source in a different folder.
    private struct MarkdownImageKey: Equatable {
        var source: String
        var folder: String?
    }

    /// The alt text and the reason, in the preview's own type — never a broken-image glyph.
    ///
    /// **The alt text leads.** It is what the document's author wrote to stand for the picture, so
    /// it is the more useful half when the picture is missing; the reason is why, in smaller type.
    private func placeholder(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "photo")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(alt.isEmpty ? "Image" : alt)
                    .scaledFont(.system(size: 12))
                Text(reason)
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Radius.well).fill(.quaternary.opacity(0.3)))
    }

    /// Resolves the source, then decodes it — both off the main actor.
    private func load() async {
        let raw = source
        let against = folder
        let resolved = await Task.detached(priority: .userInitiated) {
            MarkdownImageSource.resolve(raw, relativeTo: against)
        }.value
        guard !Task.isCancelled else { return }
        guard case .local(let path) = resolved else {
            if case .refused(let reason) = resolved {
                image = nil
                refusal = reason
            }
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            // `NSImage(contentsOfFile:)` and not `contentsOf:` — the path has already been resolved
            // and checked; building a URL here only to have AppKit take it apart again invites a
            // second, different opinion about what the path meant.
            NSImage(contentsOfFile: path)
        }.value
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
            refusal = nil
        } else {
            image = nil
            refusal = "Couldn’t be read as an image."
        }
    }
}

