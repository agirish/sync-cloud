import SwiftUI
import AppKit
import Design

/// The content behind Help ▸ SyncCloud Help (⌘?). Pure data — a handful of sections, each a
/// list of topics, each topic a short article of typed blocks — kept UI-free so SyncCloudTests
/// can pin the shape (unique ids, resolvable cross-links, no empty copy) without a view.
///
/// Every article is a hand-maintained mirror of what the app actually does; when a feature
/// changes, update the matching topic and the pin test together. Deliberately no Sync/Events
/// dependency: this is words about the app, not the app's logic.
enum HelpBook {

    /// *Requires macOS N or later.* — **read off the bundle, never typed.**
    ///
    /// This bullet was the literal `"Requires macOS 15 or later."`. On this line that number is
    /// right, and on `v3.x` — same file, same sentence, `deploymentTarget: "26.0"` — it was wrong
    /// for the whole life of the line: the book told a reader on macOS 15 that a build requiring
    /// 26 would run. Nothing fails when it is wrong, because nothing else in the app states a
    /// system requirement; the reader finds out by downloading a build that will not launch, and
    /// it is the one claim in the book they consult *before* downloading.
    ///
    /// So the number comes from `LSMinimumSystemVersion`, which Xcode writes into the built
    /// `Info.plist` from `project.yml`'s `deploymentTarget`. Raising the deployment target now
    /// moves this sentence with it, in the same edit, with nobody remembering to — which is the
    /// half that matters here, since a correct literal on this line is exactly what `v3.x` had
    /// before its target moved out from under it.
    ///
    /// **The fallback is vague on purpose.** With no key to read this says nothing about a version
    /// rather than guessing at one: a stale number reads as authoritative, "a recent version" reads
    /// as what it is.
    static var minimumSystemRequirement: String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
              !raw.isEmpty else {
            return "Requires a recent version of macOS."
        }
        // "26.0" is not how anyone says it; "15.4" is. Only a trailing `.0` goes.
        let shown = raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw
        return "Requires macOS \(shown) or later."
    }

    /// One rendered piece of an article. The renderer owns layout; the data owns words.
    enum Block: Equatable {
        /// A paragraph of running text.
        case paragraph(String)
        /// A short list of points, each rendered as its own row.
        case bullets([String])
        /// A highlighted aside — a tip or a safety note — set off with a bulb.
        case tip(String)
        /// The difference-badge key: icon + mood + label + one-line meaning. Only "Reading the
        /// list" uses it, but modeling it as data keeps that legend testable and consistent.
        case legend([LegendItem])

        /// Flattened text of the block, for the sidebar search index.
        var searchableText: String {
            switch self {
            case .paragraph(let s), .tip(let s):
                return s
            case .bullets(let items):
                return items.joined(separator: " ")
            case .legend(let items):
                return items.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
            }
        }
    }

    /// The mood of a legend row — maps to the same semantic colors the differences list uses,
    /// resolved to a concrete `Color` at render time so this stays pure data.
    enum Mood: Equatable {
        case accent, warning, danger, success, neutral
        /// The Differences list's name-conflict yellow (`DifferenceGlyph.color(for: .nameConflict)`)
        /// — softer than danger-red, which the list never paints for a conflict.
        case caution
        /// The copy-direction tints the Differences list actually paints
        /// (`DifferenceGlyph.color(toRight:)`): blue for →, purple for ←.
        case copyRight, copyLeft
    }

    /// One row of the difference-badge legend.
    struct LegendItem: Equatable {
        let systemImage: String
        let mood: Mood
        let title: String
        let detail: String
    }

    /// A single help article, addressed by the `Topic` that owns it.
    struct Article: Equatable {
        /// The one-line summary under the title.
        let intro: String
        /// The body, top to bottom.
        let blocks: [Block]
        /// Ids of related topics, rendered as tappable chips. Every id must resolve to a real
        /// topic — `HelpBookTests` enforces it.
        let related: [String]

        init(intro: String, blocks: [Block] = [], related: [String] = []) {
            self.intro = intro
            self.blocks = blocks
            self.related = related
        }
    }

    /// A navigable entry in the sidebar.
    struct Topic: Equatable {
        /// Stable identifier used for selection and cross-links — never shown to the user.
        let id: String
        let title: String
        let systemImage: String
        let article: Article
    }

    /// A titled group of topics in the sidebar.
    struct Section: Equatable {
        let title: String
        let topics: [Topic]
    }

    // MARK: Content

    static let sections: [Section] = [
        Section(title: "Getting started", topics: [
            Topic(id: "what-is-synccloud", title: "What is SyncCloud?", systemImage: "sparkles", article: Article(
                intro: "SyncCloud puts two cloud folders side by side, finds what's different, and helps you copy, move, or tidy the differences — without ever removing anything you didn't approve.",
                blocks: [
                    .paragraph("The left and right panes each show one folder. A scan compares them and lists everything that isn't identical, so you can bring the two into line on your terms."),
                    .bullets([
                        "The two panes — pick any two cloud folders, or two folders inside the same provider.",
                        "The differences list — what a scan found, and which way a copy would go.",
                        "Cleanup tools — Tidy removes duplicate copies; Filing sorts loose files into folders.",
                    ]),
                    .tip("Nothing is copied, moved, or removed until you ask, and every action can be undone with ⌘Z."),
                ],
                related: ["choose-folders", "scan"]
            )),
            Topic(id: "choose-folders", title: "Choose your folders", systemImage: "cloud", article: Article(
                intro: "SyncCloud finds your cloud providers automatically. Each pane names the one it's showing, right in its header — click that name to point the pane somewhere else.",
                blocks: [
                    .paragraph("Providers are discovered from the system's cloud-storage folder — iCloud Drive, Dropbox, OneDrive, Google Drive, Box, and others show up on their own, each in its own brand color."),
                    .bullets([
                        "Click the provider name at the top of a pane and pick another from the menu.",
                        "Use the swap button to flip the left and right panes.",
                        "Compare two folders inside one provider by choosing it on both sides.",
                    ]),
                    .tip("Don't see a provider? Add or rename one in Settings ▸ Providers."),
                ],
                related: ["scan", "providers"]
            )),
            Topic(id: "scan", title: "Scan for differences", systemImage: "arrow.triangle.2.circlepath", article: Article(
                intro: "A scan walks both folders and compares them file by file. It reads names, sizes, and dates — and optionally checksums — but never changes anything.",
                blocks: [
                    .bullets([
                        "Click Scan to compare whatever the two panes currently show.",
                        "Large trees scan in parallel; the status bar tracks progress.",
                        "Re-scan any time — after a copy, SyncCloud refreshes the affected rows for you.",
                    ]),
                    .tip("Turn on checksum verification in Settings ▸ Sync to compare contents byte-for-byte, not just size and date."),
                ],
                related: ["reading-differences", "sync-preferences"]
            )),
        ]),
        Section(title: "Working with differences", topics: [
            Topic(id: "reading-differences", title: "Reading the list", systemImage: "list.bullet.rectangle", article: Article(
                intro: "After a scan, every item that isn't identical on both sides appears here. A badge tells you what changed and which way a copy would go.",
                blocks: [
                    .legend([
                        // The badge shapes below mirror DifferenceGlyph exactly (the filled card
                        // variants) — the legend must show the symbols the list actually draws.
                        LegendItem(systemImage: "arrow.right.circle.fill", mood: .copyRight, title: "Only on the left", detail: "Missing on the right — copy it over"),
                        LegendItem(systemImage: "arrow.left.circle.fill", mood: .copyLeft, title: "Only on the right", detail: "Missing on the left — copy it back"),
                        // One row, one badge: the list renders a single glyph for a date OR size
                        // mismatch, so the legend doesn't invent two.
                        LegendItem(systemImage: "arrow.triangle.2.circlepath", mood: .warning, title: "Different date or size", detail: "One copy is newer than the other, or the contents differ"),
                        LegendItem(systemImage: "exclamationmark.triangle.fill", mood: .caution, title: "Name conflict", detail: "Same name once surrounding spaces, trailing dots, and Unicode form are normalized — or differing only by case where the volume ignores case"),
                    ]),
                    .tip("Select rows and press ⌘→ or ⌘← to copy them across. Add ⇧ to move instead of copy."),
                ],
                related: ["copy-move", "guided-review"]
            )),
            Topic(id: "copy-move", title: "Copy and move", systemImage: "arrow.left.arrow.right", article: Article(
                intro: "Copying leaves the original in place; moving removes it from the source once the copy safely lands. SyncCloud confirms before it changes anything on either side.",
                blocks: [
                    .bullets([
                        "Copy a single row with its inline arrow, or select several and use ⌘→ / ⌘←.",
                        "In a pane, select rows and use its action bar — “Copy to …” and “Move to …” name the other side — or the row's right-click menu.",
                        "Bulk-sync every difference in one direction from the toolbar.",
                    ]),
                    .tip("A transfer that would overwrite a newer file, or remove the last copy, always asks first. Tune these prompts in Settings ▸ Sync."),
                ],
                related: ["reading-differences", "undo-redo", "staying-safe"]
            )),
            Topic(id: "guided-review", title: "Guided review", systemImage: "checklist", article: Article(
                intro: "Guided review steps through the differences one at a time so you can decide each on its own — ideal for a first big reconcile.",
                blocks: [
                    .paragraph("Open it from the Review button below the differences list, then work through the queue from the keyboard."),
                    .bullets([
                        "Return copies the current item.",
                        "Delete skips it.",
                        "Space opens Quick Look.",
                        "Esc ends the review.",
                    ]),
                ],
                related: ["reading-differences", "keyboard-shortcuts"]
            )),
            Topic(id: "undo-redo", title: "Undo and redo", systemImage: "arrow.uturn.backward", article: Article(
                intro: "Every file operation is undoable. If a copy or move wasn't what you wanted, take it straight back.",
                blocks: [
                    .bullets([
                        "⌘Z undoes the last operation; ⇧⌘Z redoes it.",
                        "Undoing a move restores the file to where it came from.",
                        "The Activity Log records every operation with a timestamp.",
                    ]),
                    .tip("Undo won't overwrite a file that changed in the meantime — it refuses rather than clobber your newer copy."),
                ],
                related: ["staying-safe", "activity-log", "sync-history"]
            )),
        ]),
        Section(title: "Cleanup tools", topics: [
            Topic(id: "tidy-duplicates", title: "Tidy up duplicates", systemImage: "doc.on.doc", article: Article(
                intro: "Tidy finds files with identical contents under different names or folders and offers to trash the extra copies — keeping the best one.",
                blocks: [
                    .bullets([
                        "Scan a pane for duplicates from the Tidy tab.",
                        "SyncCloud picks a keeper — shortest path, cleanest name — and marks the rest.",
                        "Review the groups, then move the extras to the Trash.",
                    ]),
                    .tip("The last remaining copy of a file is never trashed, and removed files go to the Trash — never a hard delete."),
                ],
                related: ["file-loose-items", "staying-safe"]
            )),
            Topic(id: "file-loose-items", title: "File loose items", systemImage: "tray.and.arrow.down", article: Article(
                intro: "Filing suggests a home for loose files and can move them there — using your folder names, the file's own contents, and, optionally, AI.",
                blocks: [
                    .bullets([
                        "SyncCloud reads your folder layout and proposes where each loose file belongs.",
                        "On-device content signals handle files whose name says nothing on its own.",
                        "Accept a suggestion to move the file, or remember a rule so similar files file themselves next time.",
                    ]),
                    .tip("Cloud AI is opt-in and needs a key (Settings ▸ Tidy). Without it, filing runs entirely on-device."),
                ],
                related: ["tidy-duplicates", "sync-preferences"]
            )),
        ]),
        Section(title: "Settings and more", topics: [
            Topic(id: "providers", title: "Providers and connections", systemImage: "externaldrive", article: Article(
                intro: "Manage which cloud services SyncCloud shows. Add a custom folder, rename a provider, or hide the ones you don't use.",
                blocks: [
                    .bullets([
                        "Discovered providers appear automatically; toggle any off to hide it.",
                        "Add a custom provider by pointing SyncCloud at any folder.",
                        "Rename a provider to whatever makes sense — the pane colors follow the name.",
                    ]),
                ],
                related: ["choose-folders", "appearance"]
            )),
            Topic(id: "sync-preferences", title: "Sync preferences", systemImage: "slider.horizontal.3", article: Article(
                intro: "Control how SyncCloud decides and confirms. Each setting applies to the very next operation.",
                blocks: [
                    .bullets([
                        "Conflict policy — when both sides changed: keep newer, keep larger, always ask, or skip.",
                        "Confirm before copying or moving — a summary prompt before each transfer.",
                        "Date tolerance and checksum — how strict a match has to be.",
                        "Confirm before deleting — an extra guard on removals.",
                    ]),
                ],
                related: ["scan", "staying-safe"]
            )),
            Topic(id: "appearance", title: "Appearance", systemImage: "paintbrush", article: Article(
                intro: "Tune how SyncCloud looks — theme, surface style, translucency, provider hues, and list density.",
                blocks: [
                    .bullets([
                        "Theme — System follows macOS (including its light/dark schedule); Light and Dark pin SyncCloud regardless of the system setting.",
                        "Accent color and tint for the translucent surfaces.",
                        "Glass effect — Clear, Frosted, or Solid surfaces.",
                        "Content surface — Unified or Cards panes.",
                        "List density — comfortable or compact rows across the file panes and lists.",
                    ]),
                ],
                related: ["providers"]
            )),
            Topic(id: "keyboard-shortcuts", title: "Keyboard shortcuts", systemImage: "keyboard", article: Article(
                intro: "SyncCloud is fully keyboard-drivable. The complete list lives in its own window.",
                blocks: [
                    .bullets([
                        "Open the full reference from Help ▸ Keyboard Shortcuts, or press ⌘/.",
                        "⌘→ / ⌘← copy the selected differences; add ⇧ to move.",
                        "Space opens Quick Look; ⌥-click a breadcrumb navigates both panes at once.",
                    ]),
                ],
                related: ["copy-move", "guided-review"]
            )),
        ]),
        Section(title: "Help and safety", topics: [
            Topic(id: "staying-safe", title: "Staying safe", systemImage: "checkmark.shield", article: Article(
                intro: "SyncCloud is built so a wrong click can't quietly cost you data. Several guards stand between you and any irreversible change.",
                blocks: [
                    .bullets([
                        "Confirmations before transfers, overwrites, and deletes — each tunable in Settings.",
                        "Removed files go to the Trash, never a hard delete, and the last copy is always kept.",
                        "⌘Z undoes any operation, and undo refuses to overwrite something that changed underneath it.",
                        "Quitting mid-operation warns you first, so a sync is never left half-done.",
                    ]),
                ],
                related: ["undo-redo", "activity-log"]
            )),
            Topic(id: "activity-log", title: "Activity Log and troubleshooting", systemImage: "clock.arrow.circlepath", article: Article(
                intro: "Every scan and file operation is logged. If something looks off, the Activity Log is where to look — and what to send if you need help.",
                blocks: [
                    .bullets([
                        "Open Activity Log from the Help menu to watch the live event stream.",
                        "Filter by severity and copy lines straight from the window.",
                        "The full log is written to sync-cloud.log — Help ▸ Reveal Log File in Finder opens it.",
                    ]),
                    .tip("Attaching the log file to a bug report is the fastest way to get a problem understood."),
                ],
                related: ["sync-history", "staying-safe", "about"]
            )),
            Topic(id: "sync-history", title: "Sync History", systemImage: "clock.arrow.circlepath", article: Article(
                intro: "Every copy, move, and delete is recorded in a durable history that survives quitting — filterable, exportable, and reversible a whole run at a time.",
                blocks: [
                    .paragraph("Unlike the live Activity Log, which forgets when you quit, Sync History is written to disk as a structured record of each operation — its time, action, direction, the paths involved, and the size."),
                    .bullets([
                        "Open it from Help ▸ Open Sync History.",
                        "Filter by action, date range, or path, and search across everything recorded.",
                        "Export the current view to CSV or JSON for a spreadsheet or your own tooling.",
                        "Undo Last Run reverses the most recent sync in one step, moving files back where they were.",
                    ]),
                    .tip("Undoing a run reuses the same safe reversal as ⌘Z — files come back from where they went, and you can redo afterward."),
                ],
                related: ["undo-redo", "activity-log", "staying-safe"]
            )),
            Topic(id: "about", title: "About SyncCloud", systemImage: "info.circle", article: Article(
                intro: "SyncCloud compares and syncs two folders — a macOS app, plus a matching synccloud command-line tool for scripted workflows.",
                blocks: [
                    .bullets([
                        "See the version and build in Help ▸ About SyncCloud.",
                        "The CLI mirrors the app's scan and sync for the terminal.",
                        minimumSystemRequirement,
                    ]),
                ],
                related: ["what-is-synccloud"]
            )),
        ]),
    ]

    // MARK: Lookups

    /// Every topic across all sections, in sidebar order.
    static var allTopics: [Topic] { sections.flatMap(\.topics) }

    /// The topic with the given id, or nil.
    static func topic(id: String) -> Topic? { allTopics.first { $0.id == id } }

    /// The section title that owns a topic — the eyebrow above an article's heading.
    static func sectionTitle(forTopicID id: String) -> String? {
        sections.first { $0.topics.contains { $0.id == id } }?.title
    }

    /// Sections filtered to topics matching `query` (case-insensitive over title + intro +
    /// body). An empty/whitespace query returns everything; sections with no match drop out.
    static func filteredSections(matching query: String) -> [Section] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let hits = section.topics.filter { $0.matches(needle) }
            return hits.isEmpty ? nil : Section(title: section.title, topics: hits)
        }
    }
}

extension HelpBook.Topic {
    /// Whether this topic matches an already-lowercased search needle.
    func matches(_ needle: String) -> Bool {
        if title.lowercased().contains(needle) { return true }
        if article.intro.lowercased().contains(needle) { return true }
        return article.blocks.contains { $0.searchableText.lowercased().contains(needle) }
    }
}

extension HelpBook.Mood {
    /// The concrete color for a legend icon — the same semantic vocabulary the differences list
    /// uses (copyRight/copyLeft = the blue/purple direction tints, warning = a mismatch,
    /// caution = the yellow name-conflict badge).
    // Help stays on the system accent deliberately (C7): its accent flows through this non-View
    // Mood table and the AccentLabelColor on-fill helper, so threading the glass hue isn't the
    // trivial @AppStorage read the main-window sites get — and it's a standalone overlay surface.
    var color: Color {
        switch self {
        case .accent: return .accentColor
        case .warning: return SemanticColor.warning
        case .danger: return SemanticColor.error
        case .success: return SemanticColor.success
        case .neutral: return .secondary
        // The exact colors DifferenceGlyph paints in the real list (it's internal to
        // FileExplorer, so the values are mirrored here): nameConflict = caution-yellow,
        // → = blue, ← = purple. The legend must describe what the list renders, not a
        // nicer palette.
        case .caution: return SemanticColor.caution
        case .copyRight: return .blue
        case .copyLeft: return .purple
        }
    }
}

// MARK: - Menu commands

/// The Help ▸ Open Activity Log item. A separate View (not inline in the `.commands` builder)
/// because `openWindow` is an Environment value the App struct doesn't carry — the same reason
/// `ShortcutsWindowCommand` exists.
struct ActivityLogWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Activity Log") { openWindow(id: "activity-log") }
    }
}

/// The Help ▸ Open Sync History item — the durable, exportable, reversible history window (X2).
/// A separate View for the same reason as `ActivityLogWindowCommand`: `openWindow` is an
/// Environment value the App struct doesn't carry.
struct SyncHistoryWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Sync History") { openWindow(id: "sync-history") }
    }
}

// MARK: - Overlay

/// The in-window Help overlay (⌘? / Help ▸ SyncCloud Help): a dimmed backdrop behind a centered
/// card, mirroring the Settings and Welcome overlays so the three read as one system. Click
/// outside, Esc, or the ✕ all dismiss. Living inside the main window (rather than a separate
/// scene) keeps it floating over the content even in full screen.
struct HelpOverlay: View {
    let glassHue: LiquidGlassHue
    let glassLevel: GlassLevel
    let surfaceTint: Double
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            card
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    /// The card, decorated exactly like the Settings and Welcome cards: the accent tint, then the
    /// glass material at the level's face value via `groundedGlassCard`. It used to floor `.clear`
    /// to `.frosted` because this card sits over live app content; the ground under the content
    /// answers that without collapsing Clear and Frosted into the same card.
    @ViewBuilder
    private var card: some View {
        HelpView(onClose: onClose)
            .contentSurface(hue: glassHue, tint: surfaceTint)
            // No hairline overlay here: `groundedGlassCard` now draws it for BOTH schemes. Adding
            // one on top put a second border over the dark specular edge.
            .groundedGlassCard(level: glassLevel)
            .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
    }
}

/// The Help card's content: a searchable topic sidebar on the left and the selected article on
/// the right. Fixed size, like the Keyboard Shortcuts window — the content is bounded, so the
/// card doesn't need to resize.
struct HelpView: View {
    let onClose: () -> Void

    @State private var selectedTopicID: String
    @State private var query: String = ""

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        _selectedTopicID = State(initialValue: HelpBook.sections.first?.topics.first?.id ?? "")
    }

    private var results: [HelpBook.Section] { HelpBook.filteredSections(matching: query) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 520)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lifepreserver")
                .foregroundStyle(.secondary)
            Text("SyncCloud Help")
                .scaledFont(.headline)
            Spacer()
            CloseButton(action: onClose)
                .keyboardShortcut(.cancelAction)
                .help(ShortcutHint.tooltip("Close Help", "esc"))
                .accessibilityLabel("Close Help")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if results.isEmpty {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "No topics found",
                            layout: .compact
                        )
                        .padding(.top, 8)
                    }
                    ForEach(results, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .scaledFont(.caption2.weight(.semibold))
                                .textCase(.uppercase)
                                .kerning(0.4)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 2)
                            ForEach(section.topics, id: \.id) { topic in
                                topicRow(topic)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .scaledFont(.callout)
            TextField("Search Help", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .hoverInk(rest: .tertiary)
                }
                .buttonStyle(.hoverAffordance(.inline))
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .searchFieldSurface()
    }

    private func topicRow(_ topic: HelpBook.Topic) -> some View {
        let isSelected = topic.id == selectedTopicID
        // White on a DEEPENED accent fill, which is what a native selected row has always been:
        // AppKit's alternateSelectedControlTextColor returns white under every accent because it
        // pairs with `selectedContentBackgroundColor`, a darkened accent — the old bug here was
        // pairing a label with the RAW accent (white-on-Yellow, ~1.6:1). Rather than flip the label
        // dark on the light accents, this row now deepens its fill like every other solid accent
        // surface in the app, so the Help sidebar reads the same as the buttons beside it.
        let accentFill = AccentFill.deepened(.accentColor)
        let onAccent = Color.white
        return Button {
            selectedTopicID = topic.id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: topic.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? onAccent : .secondary)
                Text(topic.title)
                    .foregroundStyle(isSelected ? onAccent : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .scaledFont(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? accentFill : .clear)
            )
        }
        // Selected already wears the accent fill, so it takes the ring-and-lift treatment; the
        // rest wash the same shape they would fill if chosen.
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .row,
                                      shape: .roundedRect(6)))
        .padding(.horizontal, 6)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let topic = HelpBook.topic(id: selectedTopicID) {
            ScrollView {
                HelpArticleView(
                    topic: topic,
                    sectionTitle: HelpBook.sectionTitle(forTopicID: topic.id),
                    onSelectRelated: { selectedTopicID = $0 }
                )
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Only reachable if a search leaves the selection off-list; keep it graceful.
            EmptyStateView(
                icon: "book",
                title: "Choose a topic from the list.",
                layout: .compact
            )
        }
    }
}

/// Renders one `HelpBook.Article`: an eyebrow + title + intro, the typed body blocks, and a
/// row of related-topic chips that jump the selection.
struct HelpArticleView: View {
    let topic: HelpBook.Topic
    let sectionTitle: String?
    let onSelectRelated: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let sectionTitle {
                    Text(sectionTitle)
                        .scaledFont(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .kerning(0.4)
                        .foregroundStyle(Color.accentColor)
                }
                Text(topic.title)
                    .scaledFont(.title2.weight(.semibold))
                Text(topic.article.intro)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(topic.article.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }

            if !topic.article.related.isEmpty {
                relatedChips
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: HelpBook.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .scaledFont(.callout)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .scaledFont(.system(size: 4))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 5)
                        Text(item)
                            .scaledFont(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .tip(let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(Color.accentColor)
                Text(text)
                    .scaledFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .legend(let items):
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                            .scaledFont(.system(size: 12, weight: .semibold))
                            .foregroundStyle(item.mood.color)
                            .frame(width: 22, height: 22)
                            .background(item.mood.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        HStack(spacing: 6) {
                            Text(item.title)
                                .scaledFont(.callout.weight(.medium))
                            Text("— \(item.detail)")
                                .scaledFont(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
        }
    }

    private var relatedChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related")
                .scaledFont(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(.tertiary)
            FlexibleChips(ids: topic.article.related, onSelect: onSelectRelated)
        }
        .padding(.top, 4)
    }
}

/// The related-topic chips. A simple wrapping row: each chip shows a real topic's title and
/// jumps the selection when clicked. Ids are validated by `HelpBookTests`, so a lookup miss
/// here would be a test failure, not a runtime surprise.
private struct FlexibleChips: View {
    let ids: [String]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ids, id: \.self) { id in
                if let topic = HelpBook.topic(id: id) {
                    Button {
                        onSelect(id)
                    } label: {
                        HStack(spacing: 4) {
                            Text(topic.title)
                            Image(systemName: "arrow.right")
                                .scaledFont(.caption2)
                        }
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .overlay(
                            Capsule().strokeBorder(.quaternary, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.hoverAffordance(.segment))
                }
            }
        }
    }
}
