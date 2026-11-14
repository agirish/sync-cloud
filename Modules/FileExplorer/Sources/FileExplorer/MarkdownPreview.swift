import SwiftUI
import Design

/// The rendered Markdown, in the app's own type ramp.
///
/// SwiftUI text, not a web view: a `WKWebView` would bring its own fonts, selection and scroll
/// physics into the window, and ignore Settings ▸ Text size.
///
/// Read-only except for a task item's checkbox, so the buffer stays the single source of truth and
/// switching modes can't lose an edit. A click on the box goes through ``onToggleTask``, which
/// flips exactly one line via ``MarkdownEdits/taskToggle(onLine:in:)`` (converting a file's
/// carriage returns, as any first edit does; see ``EditorLineEndings``). A document that can't be
/// saved gets no control at all.
struct MarkdownPreview: View {

    let blocks: [MarkdownBlock]
    let accent: Color
    /// Which source line the preview should bring into view, or `nil` to leave it where it is.
    ///
    /// Carries a token for the reason ``PlainTextEditor/scrollRequest`` does. In split mode it
    /// changes once per line scrolled past on the other side.
    var scrollRequest: EditorScrollRequest?
    /// Ticks or unticks the task on a source line, or `nil` when this document must not be edited,
    /// which makes the checkbox a picture rather than a control.
    var onToggleTask: ((Int) -> Void)?
    /// The folder the open document lives in, which a relative image path is relative to. `nil`
    /// when nothing is open, and then no relative image path resolves.
    var documentFolder: String?
    /// Sends the reader to a heading in this same document, for a `#fragment` link.
    var onFollowAnchor: ((String) -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            scroller
                // The one place a link is decided. A fragment names a heading on screen, so it is a
                // scroll, not a launch; anything else returns `.systemAction`, leaving the system to
                // judge which schemes are acceptable, as it already does.
                .environment(\.openURL, OpenURLAction { url in openLink(url) })
                // The `.task` alone answers a request; an `.onChange(of: scrollRequest)` beside it
                // would scroll twice, once against rows that may not exist yet. The task yields
                // first, so the `LazyVStack` rows it names have been built.
                .task(id: EditorPreviewScrollKey(request: scrollRequest, count: blocks.count)) {
                    // One turn, so the rows named below have been built.
                    await Task.yield()
                    // A request is answered once. The count is in the key so a request made before
                    // its blocks were parsed is answered when they arrive, not so an answered one is
                    // asked again: a quiet reload that adds a paragraph must not yank the reader
                    // back to a heading chosen long before.
                    guard Self.shouldScroll(scrollRequest, answered: answeredRequest) else { return }
                    if scroll(to: scrollRequest, with: proxy) { answeredRequest = scrollRequest }
                }
        }
    }

    /// The last request this preview scrolled for (see ``shouldScroll(_:answered:)``). View state,
    /// so a preview built by a mode switch starts with none and opens where its request says.
    @State private var answeredRequest: EditorScrollRequest?

    /// Whether a request still needs a scroll: whether it is unanswered. A request carries a token,
    /// so asking for the same line again is a new request and is answered again.
    static func shouldScroll(_ request: EditorScrollRequest?, answered: EditorScrollRequest?) -> Bool {
        guard let request else { return false }
        return request != answered
    }

    /// What a click on a link does.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        // A fragment-only link, `[go](#the-two-numbers)`, has no scheme and no path.
        let isFragmentOnly = url.scheme == nil && url.path.isEmpty
        if isFragmentOnly, let fragment = url.fragment, let onFollowAnchor {
            onFollowAnchor(fragment)
            return .handled
        }
        return .systemAction
    }

    /// Scrolls to the request's block, or does nothing when its blocks aren't rendered yet; returns
    /// whether it scrolled, so an unanswered request waits for the blocks.
    @discardableResult
    private func scroll(to request: EditorScrollRequest?, with proxy: ScrollViewProxy) -> Bool {
        guard let request,
              let index = MarkdownOutline.blockIndex(forLine: request.line, in: blocks) else {
            return false
        }
        // No animation: in split this fires on every line scrolled past on the other side, and an
        // animated scroll chasing a scroll wheel lags and then overshoots.
        proxy.scrollTo(index, anchor: .top)
        return true
    }

    /// What a preview scroll depends on: the request, and whether the blocks it names exist yet.
    private struct EditorPreviewScrollKey: Equatable {
        var request: EditorScrollRequest?
        var count: Int
    }

    private var scroller: some View {
        ScrollView {
            // Lazy, because the read cap is 4 MiB: a plain `VStack` would build every one of tens of
            // thousands of blocks on the main actor in one pass, parse off it or not.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    // `MarkdownBlockView` is shared with the printed page, so File ▸ Print's claim
                    // to be "the preview" stays true.
                    MarkdownBlockView(block: block, accent: accent, documentFolder: documentFolder,
                                      onToggleTask: onToggleTask)
                        // The scroll target: the index, not the source line, which a block may
                        // lack (``MarkdownBlock/line``).
                        .id(index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            // The measure a reader's eye can hold; wider, long paragraphs get hard to track back to
            // the start of the next line.
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

}

/// One image from the document's own folder, or the reason it is not being drawn.
///
/// Resolved and loaded off the main actor, and only when the row is built: the preview is a
/// `LazyVStack`, so a note with forty screenshots touches only those on screen. Resolving
/// (`MarkdownImageSource.resolve`, four filesystem calls) sits beside the decode in the task, not
/// in a `body` that runs on every keystroke. So a source that can't be drawn shows "Loading…" for
/// a frame before its reason arrives.
struct MarkdownImageView: View {

    /// The raw source from `![alt](source)`, unresolved; see the note above.
    let source: String
    /// The open document's folder, which is what a relative source resolves against.
    let folder: String?
    let alt: String
    /// An image already resolved and decoded by somebody else, or `nil` to load it here.
    ///
    /// Paper's route in. The load below is a `.task`, which doesn't run in an offscreen render, so
    /// every printed page would show "Loading…". ``DocumentPDF`` resolves and decodes through the
    /// same two calls this view uses and hands the answer over.
    var preloaded: Preloaded?

    /// A resolved image, or the reason there isn't one: the two states ``load()`` produces.
    enum Preloaded: Equatable {
        case image(NSImage)
        case refused(String)
    }

    @State private var image: NSImage?
    /// Why there is no image, or `nil` while nothing has been decided yet.
    @State private var refusal: String?

    /// The tallest an image is drawn, whatever its own size.
    ///
    /// A cap on the drawn height, separate from the file's byte cap: a tall phone screenshot would
    /// otherwise take four screens of a document read for its words. Width is the column's; the
    /// aspect ratio is kept.
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
        // On the `Group`, not inside the placeholder's arm, where the task would be torn down when
        // the image arrives and not re-run when the source changes under a drawn image. Skipped
        // when the answer was handed over: it is already resolved and decoded.
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

    /// The alt text and the reason, in the preview's own type, never a broken-image glyph. The alt
    /// text leads, since the author wrote it to stand for the picture; the reason follows, smaller.
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

    /// Resolves the source, then decodes it, both off the main actor.
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
            // `NSImage(contentsOfFile:)`, not `contentsOf:`: the path is already resolved and
            // checked, and a URL round trip could give a second opinion about what it means.
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

