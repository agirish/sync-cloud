import SwiftUI
import AppKit
import Design
import FileExplorer

/// The content behind Help ▸ SyncCloud Help (⌘?). Pure data — a handful of sections, each a
/// list of topics, each topic a short article of typed blocks — kept UI-free so SyncCloudTests
/// can pin the shape (unique ids, resolvable cross-links, no empty copy) without a view.
///
/// Every article is a hand-maintained mirror of what the app actually does; when a feature
/// changes, update the matching topic and the pin test together. Deliberately no Sync/Events
/// dependency: this is words about the app, not the app's logic. The `FileExplorer` import below
/// is the view half's, for the one wrapping layout the related chips need — nothing in ``HelpBook``
/// itself reads it, which is what keeps the data testable without a view.
enum HelpBook {

    /// *Requires macOS N or later.* — **read off the bundle, never typed.**
    ///
    /// This bullet was the literal `"Requires macOS 15 or later."` until v4.2, and it stayed that
    /// way across **two** major bumps: it is the one claim in the book a reader consults *before*
    /// downloading, and nothing about a wrong answer fails — the app simply refuses to launch on a
    /// Mac the book told them was fine. The v4.2 pass corrected the number to 26, which fixes this
    /// install and re-arms the identical trap for v5: a literal that is right today is exactly what
    /// the last one was.
    ///
    /// So the number comes from `LSMinimumSystemVersion`, which Xcode writes into the built
    /// `Info.plist` from `project.yml`'s `deploymentTarget`. Raising the deployment target now
    /// moves this sentence with it, in the same edit, with nobody remembering to.
    ///
    /// **The fallback is vague on purpose.** With no key to read — which is every host that is not
    /// the app bundle — this says nothing about a version rather than guessing at one. A stale
    /// number reads as authoritative; "a recent version" reads as what it is, and the app-target
    /// test below is what keeps the real bundle off that path.
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
            Topic(id: "setup", title: "Set up SyncCloud", systemImage: "checklist", article: Article(
                intro: "Setup asks for the handful of things SyncCloud cannot work out by looking at your folders: your name as documents print it, which of the places on this Mac you actually use, who else your documents belong to, and which tree to learn from. It runs itself once on a new install, and Help ▸ Set Up SyncCloud… opens it again any time.",
                blocks: [
                    .bullets([
                        "You — the name your folders use, and the fuller forms a document might print. A full name is matched before any single word, so a shared surname stops making two people out of one document.",
                        "Sources — everything found in the system's cloud-storage folder, plus any folder you add. Turn off what you don't use, and mark one as primary: that's the tree SyncCloud learns your folder conventions from.",
                        "People — anyone else whose documents live in your folders. SyncCloud proposes the names it found — a folder sitting directly under one that says what its children are, like a person's folder under Family — and each chip carries the folder that vouches for it. Nothing is ticked to begin with, and you can type a name that has no folder at all.",
                        "Folders — the tree SyncCloud learns from, and the places it found in that tree. Pick a root, confirm which of the proposed place names are real, and press the button: the walk reads folder names only, so it takes seconds. Nothing is ticked here either — handed only the names you confirm, the same code is right about all of them.",
                    ]),
                    .paragraph("What that last step writes is the folder survey: the record of how your tree is shaped. It is what lets Organize propose a destination for a loose file and a better name for a badly named one, and it is the only thing Restructure reads — without it that section has nothing to compare. It takes effect straight away, with no relaunch, and Restructure can re-read the tree at any time."),
                    .paragraph("Nothing here is locked in. Every answer has a home in Settings — Sources, People and Organize — and setup is a faster way to give them all at once rather than the only way."),
                    .tip("It all happens on this Mac. The one thing that can reach a third party is Organize's optional Refine pass, which asks Claude about a scan's results, is off until you turn it on in Settings ▸ Intelligence, and never runs on its own."),
                ],
                related: ["what-is-synccloud", "choose-folders", "people", "organize-workspace"]
            )),
            Topic(id: "what-is-synccloud", title: "What is SyncCloud?", systemImage: "sparkles", article: Article(
                intro: "SyncCloud works on your cloud folders through four workspaces — Browse one provider's files, Compare two folders side by side, Organize what's out of place, and Storage to see where the space goes — without ever removing anything you didn't approve.",
                blocks: [
                    .paragraph("They are four different kinds of place rather than four tasks. Browse shows one tree and proposes nothing, Compare holds two trees side by side, Organize changes one tree on the app's suggestion, and Storage reads one tree and changes nothing at all."),
                    .bullets([
                        "Browse — the plain file browser: one provider's tree at full width, nothing proposed, nothing changed.",
                        "Compare — pick any two cloud folders, or two folders inside the same provider, and scan them. The differences list shows everything that isn't identical, and which way a copy would go.",
                        "Organize — five sections over a single tree: To File, Duplicates, Renames, Restructure, and Rules.",
                        "Storage — a treemap of where a folder's bytes are, its largest and longest-untouched files, and the large-and-idle overlap worth reclaiming.",
                    ]),
                    .tip("Nothing is copied, moved, or removed until you ask, and ⌘Z takes back what you just did. ⌘1 through ⌘4 switch workspaces."),
                ],
                related: ["setup", "browse-workspace", "organize-workspace", "scan"]
            )),
            Topic(id: "browse-workspace", title: "Browse your files", systemImage: "folder", article: Article(
                intro: "Browse is where SyncCloud opens, and it's the plain file browser: one provider's tree at the full width of the window, with nothing proposed and nothing changed. It's where you go to work on files by hand, without a lens's opinion.",
                blocks: [
                    .bullets([
                        "Move through Finder-style columns — clicking a folder opens the next column — or switch the pane to a tree; the choice is remembered for Browse on its own.",
                        "In columns, selecting a file opens a preview beside the list; Space opens Quick Look in either view.",
                        "Hold two places at once with tabs: right-click a folder and choose “Open in New Tab”, or press ⌘T to open a second tab on the folder you are in. The strip appears as soon as there is a second tab.",
                        "Each tab keeps its own folder, and its selection, search and Back history for as long as the app is open. With “Reopen panes where I left off” on — it is on by default — the tabs you leave open come back the next time you launch. ⇧⌘] and ⇧⌘[ step between them; ⌘W closes one, and closes the window on the last.",
                        "Drag a tab along the strip to reorder it. Right-click one to pin it: a pinned tab sits at the front, keeps its place when the strip runs out of room, survives “Close Other Tabs”, and drops its ✕ so a stray click can't take it.",
                        "⌘F searches the tree you're browsing; ⌘K opens Go to, which reaches anywhere the app can go by name.",
                        "Right-click a folder for “Organize This Folder…”, “Check This Folder’s Shape”, “Plan This Folder’s Shape…” or “Set Up Like Its Siblings”, or a file for “Find Duplicates of This” — each lands in the matching Organize section. Most of them are in the Organize menu as well, aimed at whatever the focused pane has selected, with “Undo This Reorganisation” at the bottom for the last landing Restructure applied. “Check This Folder’s Shape” is the one that lives in the row menu and ⌘K instead.",
                        "The rest of a row's right-click menu is in the File menu for the same reason — Open in New Tab, Quick Look, Reveal in Finder, Rename, Copy to… and Move to… all act on the focused pane's selection, so none of them needs you to find the right row to right-click first. Rename also answers to ↩ with a row selected, the way it does in Finder; the menu item carries no key because a bare ↩ registered there would take the Return that commits every sheet in the app.",
                    ]),
                    .tip("Browse and Compare's left pane share the same spot, so switching over keeps you in the folder you were just browsing — tabs and all. To aim Organize at a folder, use “Organize This Folder…” from its right-click menu."),
                ],
                related: ["what-is-synccloud", "folder-sidebar", "choose-folders", "command-palette"]
            )),
            Topic(id: "folder-sidebar", title: "The folder sidebar", systemImage: "sidebar.left", article: Article(
                intro: "The column down the left of every workspace holds the folders you keep, the accounts you have signed into, and the folders you were last in. View ▸ Sidebar shows or hides it, and ⌃⌘S does the same from the keyboard.",
                blocks: [
                    .paragraph("It has three sections, and each heading folds away — a folded one says how many rows are behind it, so it never reads as empty. The column's own edge sets its width."),
                    .legend([
                        LegendItem(systemImage: "star", mood: .accent, title: "Favorites",
                                   detail: "The folders and places you keep. It starts as your home folder, Desktop, Documents, Downloads and your startup disk."),
                        LegendItem(systemImage: "externaldrive", mood: .neutral, title: "Locations",
                                   detail: "Every account you have signed into, then any disks Favorites is not already holding, then the Trash."),
                        LegendItem(systemImage: "clock", mood: .neutral, title: "Recents",
                                   detail: "The folders you were last in, newest first."),
                    ]),
                    .paragraph("Favorites and Recents span every source, not one account at a time. A folder you keep in Dropbox is right there while you are looking at iCloud, and Recents is a single list ordered by when you were there — which is what “the folder I was in five minutes ago” actually means."),
                    .bullets([
                        "Put a place in Favorites by right-clicking it in Locations, and take one out by right-clicking it in Favorites. A place moves between the two rather than appearing in both.",
                        "Keep a folder you are looking at by right-clicking it in a pane and choosing “Add to Favorites”. The same menu removes it again.",
                        "“Restore Standard Places”, on the Favorites heading, brings the five it starts with back without disturbing anything you have added. It appears only when one of them is missing.",
                        "Drag a row to put the section in your own order. Locations shares its order with the pane header's source menu, so the two always agree.",
                        "“Show in Enclosing Folder” opens the folder a favorite or a recent lives in, rather than the folder itself — what you want when two folders share a name.",
                        "A row for a local folder SyncCloud has not been given yet says so before it becomes a source, and offers to take it back. The Trash opens in Finder and is never scanned.",
                        "“Remove Source…”, on a folder you added yourself, takes it out of SyncCloud from where you are looking at it rather than from Settings. It asks first: the folder is untouched, but the name you gave the source and where it opens are not kept.",
                        "“Eject”, on a disk or memory card, is Finder's own verb without leaving the app. It asks first, because it reaches past SyncCloud: the volume is unmounted from macOS, so it leaves Finder and every other app too. It appears on any volume you could eject in Finder, whether or not SyncCloud has it as a source.",
                    ]),
                    .paragraph("Eject a card — here or in Finder — and SyncCloud forgets the sources on it, so no row is left behind. A card that merely stops answering is a different thing and is left alone: its row dims until it comes back, because a source that is asleep has not gone. Folders you pinned on that card are kept too, and are still there if you plug it in and add it again."),
                    .paragraph("Rename a disk or a memory card in Finder and SyncCloud follows it — the source, its pinned folders and its place in Favorites all move to the new name. Rename one while SyncCloud is closed and it cannot be followed; that is the row “Remove Source…” is for."),
                    .paragraph("In Compare the column acts on one pane, and says which above its first row: “Opens on Left” or “Opens on Right”. That is the pane you last clicked in — anywhere in it, not only on a row — and it is drawn with a faint border around its cards so you can see which one is listening. To send a single folder to the other side without changing that, right-click the row and choose “Open in Left Pane” or “Open in Right Pane”."),
                    .tip("A row's right-click menu also holds “Open in New Tab”, which is the quickest way to keep the folder you are in and open another beside it."),
                ],
                related: ["browse-workspace", "choose-folders", "command-palette"]
            )),
            Topic(id: "choose-folders", title: "Choose your folders", systemImage: "cloud", article: Article(
                intro: "SyncCloud finds your cloud providers automatically, and any folder on this Mac can be a source too. Each pane names the one it's showing, right in its header — click that name to point the pane somewhere else.",
                blocks: [
                    .paragraph("Providers are discovered from the system's cloud-storage folder — iCloud Drive, Dropbox, OneDrive, Google Drive, Box, and others show up on their own, each in its own brand color."),
                    .paragraph("A plain folder works the same way. Add one under Settings ▸ Sources and it appears in every pane menu beside the clouds, with the same comparing, organizing and undo behind it."),
                    .bullets([
                        "Click the provider name at the top of a pane and pick another from the menu.",
                        "Use the swap button to flip the left and right panes.",
                        "Compare two folders inside one provider by choosing it on both sides.",
                    ]),
                    .tip("Don't see a source? Add a cloud provider or a folder in Settings ▸ Sources."),
                ],
                related: ["scan", "providers"]
            )),
            Topic(id: "scan", title: "Scan for differences", systemImage: "arrow.triangle.2.circlepath", article: Article(
                intro: "A scan walks both folders and compares them file by file. It reads names, sizes, and dates — and optionally checksums — but never changes anything.",
                blocks: [
                    .bullets([
                        "Click Scan, or press ⌘R, to compare whatever the two panes currently show.",
                        "Large trees scan in parallel; the status bar tracks progress.",
                        "Re-scan any time — after a copy, SyncCloud refreshes the affected rows for you.",
                        "⇧⌘V verifies date-only differences by checksum, so a file that merely has a different timestamp stops looking like a change.",
                    ]),
                    .tip("Turn on checksum verification in Settings ▸ Sync to compare contents byte-for-byte, not just size and date."),
                ],
                related: ["reading-differences", "sync-preferences"]
            )),
            Topic(id: "storage-lens", title: "See where space goes", systemImage: "chart.pie.fill", article: Article(
                intro: "Storage maps a folder's biggest areas, ranks its largest and longest-untouched files, and flags large idle ones worth keeping online-only.",
                blocks: [
                    .bullets([
                        "Analyze a folder to get a treemap of where its bytes actually are. It is a single ramp in your accent color ordered by size — the deepest tile is the biggest — so the color is the ranking, with no legend to learn.",
                        "The ranked lists show the largest files, the ones untouched longest, and the large-and-idle overlap worth reclaiming.",
                        "The two size-ordered lists draw a magnitude bar beside each size, measured against that section’s own largest file, so a four-fold difference reads as one without comparing digits. Filtering removes rows rather than rescaling the ones left, so the bar keeps meaning the same thing while you search.",
                        "The oldest-first list has no bar — it would rise and fall against an order it has nothing to do with. Every row of all three carries its share of the scan instead, and a file too small to round reads “<1%” rather than “0%”, which would claim it is not there at all.",
                        "Reopening Storage shows your last analysis, with its age beside it — re-analyze for current numbers.",
                    ]),
                    .tip("Storage never moves, deletes, or evicts anything. “Offload” reveals a file in Finder so you can decide there — the reading is the whole feature."),
                ],
                related: ["what-is-synccloud", "tidy-duplicates"]
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
                    .bullets([
                        "⌘D shows or hides the list; ⇧⌘F collapses or expands every folder in it.",
                        "⇧⌘V verifies date-only rows by checksum — the ones that differ only by a timestamp drop out.",
                        "Right-click a row that exists on both sides and choose “Compare…” to see the two files side by side — the same viewer the Duplicates page describes, with a facts strip, live previews, the pixel modes for PDFs and images, and a line diff for text. It is read-only: copying, moving and ignoring a row stay on the row.",
                    ]),
                    .tip("Select rows and press ⌘→ or ⌘← to copy them across. Add ⇧ to move instead of copy."),
                ],
                related: ["copy-move", "guided-review", "tidy-duplicates"]
            )),
            Topic(id: "copy-move", title: "Copy and move", systemImage: "arrow.left.arrow.right", article: Article(
                intro: "Copying leaves the original in place; moving removes it from the source once the copy safely lands. SyncCloud confirms before it changes anything on either side.",
                blocks: [
                    .bullets([
                        "Select one or more difference rows and use ⌘→ / ⌘← (⇧ makes it a move), or the row's right-click menu.",
                        "In a pane, select rows and use its action bar — “Copy to …” and “Move to …” name the other side — or the row's right-click menu.",
                        "Bulk-sync every difference in one direction from the toolbar.",
                        "The Compare menu carries the same four transfers, with Review and Verify below them.",
                        "File ▸ Copy to… and Move to… are a different offer: they open a folder picker rather than sending the selection to the other pane, so they are the way to put something somewhere neither pane is showing.",
                        "For anywhere else — including Finder — use the clipboard: ⌘C or ⌘X in a pane, then ⌘V where you want them.",
                    ]),
                    .tip("A transfer that would overwrite a newer file, or remove the last copy, always asks first. Tune these prompts in Settings ▸ Sync."),
                ],
                related: ["clipboard", "reading-differences", "undo-redo", "staying-safe"]
            )),
            Topic(id: "clipboard", title: "Cut, copy and paste", systemImage: "doc.on.clipboard", article: Article(
                intro: "Edit ▸ Cut, Copy and Paste work on files, in any pane, and they exchange files with Finder in both directions. ⌘X then ⌘V is a move; ⌘C then ⌘V is a copy.",
                blocks: [
                    .bullets([
                        "Select rows in a pane and press ⌘C, or ⌘X to take them. ⌘V pastes into whichever pane has focus — so selecting on the left, pressing ⌃⇥, then ⌘V carries the files across. Cut and copy read the selection wherever it is; paste always aims at the focused pane’s current folder.",
                        "⌘C here and ⌘V in Finder puts the files down where you are in Finder, and ⌘C in Finder then ⌘V here brings them the other way. Whichever clipboard was written last is the one that answers.",
                        "A cut pasted into Finder copies rather than moves. Only SyncCloud’s own clipboard records that you cut, and the Mac’s pasteboard carries no flag for it — in Finder that is ⌥⌘V, a decision made at the receiving end.",
                        "Once a cut has been pasted the clipboard lets go of what moved, so ⌘V is not left armed over files that are no longer where it would look for them.",
                        "⌘A selects everything in the focused pane’s current folder. In a tree that is the top-level rows: selecting a folder already covers what is inside it, because every verb here treats a folder as its contents.",
                        "All three are on a row’s right-click menu as well — “Cut”, “Copy” and “Paste here” — and “Paste here” is on the empty space below the rows too, which is where you want it when nothing is selected.",
                        "A paste spends through the same copy or move as any other transfer — one undo step for the whole paste, the same banner, and the same prompt before anything is overwritten.",
                    ]),
                    .tip("Cut, Copy, Paste and Select All are never greyed out, because with a caret in a field they still mean text: ⌘C copies the words in the pane search, a rename box, the differences search or the ⌘K field. The price is that Paste stays available over an empty clipboard, where it does nothing."),
                ],
                related: ["copy-move", "browse-workspace", "undo-redo"]
            )),
            Topic(id: "guided-review", title: "Guided review", systemImage: "checklist", article: Article(
                intro: "Guided review steps through the differences one at a time so you can decide each on its own — ideal for a first big reconcile.",
                blocks: [
                    .paragraph("Open it from the Review button below the differences list, from Compare ▸ Review Differences, or with ⇧⌘R — then work through the queue from the keyboard."),
                    .bullets([
                        "↩ takes the item — copying or moving it, whichever that row calls for. The keypad's Enter does the same thing.",
                        "⌫ skips it. A skipped row does not come back around, so both keys act once per press: holding one down will not run through the queue behind your back.",
                        "Both want a plain keystroke, and both want the card itself to have focus. ⌘↩ and ⇧⌫ do nothing here, and with Full Keyboard Access on, an ↩ aimed at the focused Skip button no longer moves anything — a Mac button answers Space, not Return.",
                        "Space opens Quick Look. Esc ends the review.",
                    ]),
                ],
                related: ["reading-differences", "keyboard-shortcuts"]
            )),
            Topic(id: "undo-redo", title: "Undo and redo", systemImage: "arrow.uturn.backward", article: Article(
                intro: "If a copy or move wasn't what you wanted, take it straight back — ⌘Z reverses it. Two things it cannot reach: a removal that never went to the Trash, because there is nothing to bring back from, and anything from a session you have already quit.",
                blocks: [
                    .bullets([
                        "⌘Z undoes the last operation; ⇧⌘Z redoes it.",
                        "Undoing a move restores the file to where it came from.",
                        "A removal offers an undo only when all of it reached the Trash. If even one item in the batch had to be destroyed outright, no undo is offered at all — rather than one that would restore part of it and leave the rest gone without saying so.",
                        "A Restructure landing is one ⌘Z for the whole thing, however many folders it touched.",
                        "The Activity Log records every operation with a timestamp.",
                    ]),
                    .paragraph("Restructure's landings have a second undo of their own, and the difference matters. ⌘Z lives in memory and is gone when you quit; “Undo this reorganisation” replays a reversal kept on disk, so it still works tomorrow. It runs through the same guards as the landing did, it can partly fail on a file that has moved on since — which it names rather than glossing over — and only the newest landing can be taken back."),
                    .tip("Undo won't overwrite a file that changed in the meantime — it refuses rather than clobber your newer copy."),
                ],
                related: ["staying-safe", "activity-log", "sync-history", "restructure-apply"]
            )),
        ]),
        Section(title: "Organize", topics: [
            Topic(id: "organize-workspace", title: "The Organize workspace", systemImage: "folder.badge.gearshape", article: Article(
                intro: "Organize is the one workspace that changes a single tree, and every way of changing it is a section in its rail. Five of them, always in the same order — and before you pick one, the overview is what you see.",
                blocks: [
                    .bullets([
                        "To File — loose files, and where each one belongs.",
                        "Duplicates — identical content under different names or folders.",
                        "Renames — names worth changing: ones that won't store cleanly, files that ignore their folder's convention, and files whose numbering has drifted.",
                        "Restructure — families of sibling folders that were set up differently at different times. It finds them, derives a plan you review operation by operation, and can carry it out — keeping the way back on disk.",
                        "Rules — say once where a kind of file belongs, so To File stops asking the same question every time one turns up.",
                    ]),
                    .paragraph("A rail item is always there, whatever the counts are. The badge beside it is not: it appears when there is something to see and is absent at zero rather than showing one. So an empty section is a place you can legitimately stand — it says nothing here rather than vanishing from under you."),
                    .paragraph("The overview in front of the five sections raises one thing on its own. When a new year's folder turns up holding files and no folders, it says so in a line with a Set up… beside it — the month it happens, rather than whenever you next open Restructure. Dismiss it and it stays gone until the year turns again."),
                    .paragraph("There is an Organize menu in the menu bar too. The five sections are at the top, ticked so it says which one is on screen. Under them come the verbs that aim a section at whatever the focused pane has selected — Organize This Folder…, Find Duplicates of This, Plan This Folder’s Shape… and Set Up Like Its Siblings — then the two about a name, Fix Name… and Always Allow This Name, which appear only for a name SyncCloud would rewrite. Undo This Reorganisation sits alone at the bottom, and is the one item there that needs no selection: it takes back the newest reorganisation Restructure applied, from a record on disk, even after a quit. Everything above it acts on one thing, so selecting two rows greys them out, and the two that need a finding are greyed out when the folder you have selected has none. ⌘3 reaches the workspace they all live in; none of the items takes a chord of its own."),
                    .tip("Right-click a folder in any pane and choose “Organize This Folder…” to point Organize at it. The section then answers about the folder you aimed it at, rather than wherever Organize happened to be."),
                ],
                related: ["file-loose-items", "tidy-duplicates", "fix-names", "restructure-shapes", "automation-rules"]
            )),
            Topic(id: "file-loose-items", title: "Put loose files away", systemImage: "tray.and.arrow.down", article: Article(
                intro: "Organize's To File section suggests a home for the files sitting loose in a folder and can move them there — reusing the folders you already keep, and proposing a new one only when it's sure.",
                blocks: [
                    .bullets([
                        "SyncCloud reads your folder layout — the survey setup learned — and proposes where each loose file belongs.",
                        "On-device content signals handle files whose name says nothing on its own.",
                        "Accept a suggestion to move the file. For a pattern you will meet again, say it once as a rule in Organize ▸ Rules.",
                        "Ask for a specific folder from a pane: right-click it and choose “Organize This Folder…”.",
                        "Restructure hands work here rather than growing its own. A year's worth of files parked above the year folders, and the files left loose after a new year has been given its shape, both arrive as To File scoped to that one folder — the same evidence and the same undo as anything else here.",
                    ]),
                    .tip("Nothing moves without your say-so, and every move is undoable. Which engines run is up to you — see Settings ▸ Intelligence."),
                ],
                related: ["organize-workspace", "automation-rules", "intelligence", "restructure-scaffold"]
            )),
            Topic(id: "tidy-duplicates", title: "Clear out duplicates", systemImage: "doc.on.doc", article: Article(
                intro: "Duplicates scans one folder's tree for content that repeats under different names or in different places, and offers to trash the extra copies — keeping the best one.",
                blocks: [
                    .bullets([
                        "Scan the folder you're standing on from Organize ▸ Duplicates, or right-click a file and choose “Find Duplicates of This”.",
                        "SyncCloud picks a keeper — shortest path, cleanest name — and marks the rest.",
                        "Filter the groups by how they match: Needs review, Identical, Same text, Overlapping, or Versions.",
                        "The counts above the list are that filter too, not decoration beside it. Clicking “groups” is the way back to everything, and “need review” shows only the same-name-different-contents groups. The reclaimable figure describes the whole scan rather than a subset of the rows, so it is plain text and deliberately not clickable — a header that answers some clicks and not others is worse than one that never invited them.",
                        "A badge marks the exception, not the rule. Most groups are byte-identical, so they wear none and their line simply reads “byte-for-byte”. “Same text” is the badge worth having: copies whose bytes differ, which no byte-for-byte check could have matched.",
                        "Review the groups, then move the extras to the Trash.",
                        "“Compare copies” opens any two copies side by side — for files as well as folders. A facts strip across the top shows name, location, size and date for both, with whatever differs picked out; below it, two live previews. Pick which copy to keep with ←/→ or the button over either pane, then Done, or trash the other one from the same bar. ⏎ and esc both mean Done: trashing is always a deliberate click.",
                        "A byte-identical pair says so, and offers to re-check it: “Verify now” hashes both files as they are on disk right now. If they no longer match, the scan is stale and it says so rather than letting you act on it.",
                        "A copy that hasn't been downloaded shows why its pane is empty, with a Download button — previewing it would pull the whole file down, which on a cloud folder is the normal case rather than the exception.",
                        "Two PDFs or two images scroll and zoom together, and ⇞/⇟ page both at once. Hold ⌥ to move one pane on its own. A strip under the panes marks every page once it has been compared: green where nothing changed, amber where something did, blue where only one document has that page, red where a side could not be rendered. A page with no mark has not been compared yet. Where one document is longer, the shorter side stops at its last page rather than hiding the pages only one file has.",
                        "1–4 switch how the two pages are shown: side by side, a draggable swipe divider, a blend, or the pixel difference on black where identical is black and anything changed glows. That last one compares pixels with no alignment, so two scans of the same sheet of paper will glow all over — it says so on screen.",
                        "Text, source, CSV and JSON files get a read-only line diff instead. An edited line is one row with both versions and the changed words picked out; ↑/↓ step between changes rather than between lines. A file that is too large, not downloaded, or not really text says which of those it is.",
                    ]),
                    .paragraph("What counts as a duplicate is yours to set. Settings ▸ Duplicates turns on version detection — Report, Report (1), Report-final as one family — and reading PDFs to find copies a byte-for-byte hash would miss. That same content reading is what lets Restructure notice two whole branches holding the same documents under different names."),
                    .tip("The last remaining copy of a file is never trashed, and removed files go to the Trash — never a hard delete."),
                ],
                related: ["organize-workspace", "staying-safe", "storage-lens"]
            )),
            Topic(id: "fix-names", title: "Fix names", systemImage: "textformat", article: Article(
                intro: "Renames looks across the provider for names worth changing, and shows you every one of them before anything happens.",
                blocks: [
                    .bullets([
                        "Names that won't store cleanly — this provider's own rules, plus the invisible hazards any cloud mangles, which is why an iCloud or a plain-folder source fills this section too.",
                        "Files that don't follow the convention their own folder uses.",
                        "Files renumbered to make room for one of those.",
                        "Files whose one-digit ordinals gain a leading zero, so 1. Jan 2011.pdf becomes 01. Jan 2011.pdf and the folder sorts the way you meant.",
                    ]),
                    .paragraph("What gets renamed here is always a file. A folder is how the list groups the work — never the thing being renamed. Folders are Restructure's half, and it only renames one as part of a plan you have reviewed."),
                    .tip("Nothing is renamed without your say-so, and every rename is undoable. Organize ▸ Fix Name… opens this on a pane's selected item, and Always Allow This Name tells SyncCloud to stop proposing a change for it."),
                ],
                related: ["organize-workspace", "undo-redo", "providers", "restructure-shapes"]
            )),
            Topic(id: "restructure-shapes", title: "What Restructure finds", systemImage: "square.stack.3d.up", article: Article(
                intro: "Restructure is the section that looks at whole families of folders rather than one file at a time: siblings set up differently at different times, a year that never got its folders, two spellings of one name. It names what it saw and says what fixing it would cost, and nothing changes until you apply a plan.",
                blocks: [
                    .paragraph("It compares sibling families across the whole surveyed tree, not inside the one folder you happen to be standing in. A finding carries the family, what it found, and the class of change that would fix it — so you can tell a rename from a merge before any sheet opens. Once a plan is drafted the card drops the general sentence for the actual numbers: how many folders would be renamed, how many merged, and how many files would move."),
                    .bullets([
                        "Shape — a family whose siblings are organised more than one way: “17 folders, 3 internal shapes”. Each way is listed with the siblings that vouch for it and the subfolders they agree on. Renames or merges folders.",
                        "Series — the newest member of a year run holds files and no folders yet. Creates the folders its siblings expect; see “Set up a new year”.",
                        "Year in name — a folder like IRS Docs - 2023 sitting beside bare-year siblings. A rename, or a merge where that year already exists beside it.",
                        "Echo — two names for one thing: a child restating its parent, or Form W-2 sitting beside Form W2. A merge.",
                        "Mirrored inbox — a folder inside an inbox that mirrors a real destination beside the inbox. A merge into the destination.",
                        "Loose files — files parked in the parent of a year run that has folders for them. These are per-file judgements, so they hand off to To File rather than growing a plan.",
                        "Loose folder — a leaf sitting beside the folder that owns its concept. Moves the folder in; its files ride along.",
                        "Duplicated — two branches holding the same documents under parallel names. It reads the duplicate scan rather than the folder survey, so where no scan has covered a pair it says exactly that instead of calling it clean.",
                    ]),
                    .paragraph("Above the findings sit three counts — pass-through folders, single-file folders, and empty ones. Crowding is a property of any real tree rather than a list of defects, so none of them takes a badge and none becomes a card. Each opens its list, grouped by top-level folder once there are more than a few dozen. Only the empty one offers to do anything about it, because only it has a rule anyone could state: “Remove empty folders…” takes the ones you tick to the Trash, with date buckets ticked to begin with and category names left alone. An empty 2019 is debt; an empty Payslips is a destination waiting for its next file."),
                    .bullets([
                        "The badge on the rail counts only the findings that can end in a plan — a badge you cannot drive to zero is a badge people stop reading. The “Show N findings” button counts everything the list will show, so the two numbers differ on purpose.",
                        "Two detectors can both be right about one folder. Their cards sit together, and the second drops the path heading so it reads as a second thing about the same place rather than a repeat.",
                        "Findings about a folder your scope sits inside are shown too, kept visually subordinate and labelled — under a scope pointed at a leaf they are often the only honest answer there is.",
                        "Where a family's members are years, a strip across the card shows the eras in order and colours them by shape, so “the last three years all disagree” reads in a glance rather than out of a list. The rows underneath stay, and they are the authority.",
                        "Children named for a year, a person, a jurisdiction or an inbox are set aside before two siblings are compared. Those recur by design, and counting them as structure would bury the real findings under hundreds of folders doing nothing wrong.",
                        "A small trend line says how the finding count has moved since the survey started keeping them, with a dot for each landing — the counts the detectors produced, not a score.",
                    ]),
                    .paragraph("Restructure reads a survey of your folder names rather than the disk, so it has nothing to say until SyncCloud has learned your tree — setup's Folders step is what writes one. The card says when the tree was last looked at; once that stamp is old enough to matter it says so with a Rescan beside it, and “Update the survey” re-reads the tree at any time. That re-read is the only thing here that makes the answer current: showing the findings costs nothing, because they are already in hand."),
                    .paragraph("“Nothing is wrong” and “I could not check” never share words here. A clean result names how many folders it checked; a missing survey says it has nothing to read; and the one detector that depends on a duplicate scan says when no scan has reached a pair, rather than calling it clean."),
                    .tip("Looking is entirely read-only, and so is every count on this screen. Everything that writes goes through a plan you review first — see “Plan a new shape”."),
                ],
                related: ["organize-workspace", "restructure-plan", "restructure-scaffold", "setup"]
            )),
            Topic(id: "restructure-plan", title: "Plan a new shape", systemImage: "list.bullet.rectangle.portrait", article: Article(
                intro: "A plan is one mapping — every folder name the family uses, listed once — applied to every member of that family. You answer “what should this be called” once per name instead of moving the files by hand, and every operation is derived from your answers rather than typed.",
                blocks: [
                    .paragraph("“Plan…” on a finding opens the sheet. It runs top to bottom, and nothing in it moves a folder."),
                    .paragraph("Which sheet depends on where the two folders sit. A family of siblings, and a pair under one parent — two spellings of one name, or a year hiding inside a longer name beside the bare year — are a mapping, so they open the sheet described here; a pair is simply opened with its one row already filled in. A folder that belongs under a different parent — an inbox mirroring the real destination, a loose folder beside the container it belongs in, a child restating its parent — cannot be written as a mapping row at all, so it opens a shorter sheet instead: the two paths, the operations they imply, and the same Export and Apply. Both derive every operation the same way, and neither moves anything until Apply."),
                    .bullets([
                        "Target shape — the shapes actually in use, each listing the siblings that vouch for it, with the largest group and the most recent marked. Nothing is pre-selected: neither of those is automatically the right answer, and a field under them lets you name the folders yourself instead. Where the newest folders all disagree the sheet says outright that there is no current shape to continue, so choosing one is a decision rather than carrying on.",
                        "Mapping — one row per distinct name found across the whole family, every row defaulting to “keep”. Point two names at one target and the row says it is a merge, and in how many members. A count says how many rows you have mapped; above about a dozen rows a filter appears, and near-identical names — Payment beside Payments — are sorted next to each other so the choice between them is made in one place.",
                        "Refine names with Claude — optional and paid, on the names only. It answers row by row against your own mapping, declines where the folder says nothing, and flags a proposal that reverses another. Accepting a row edits your mapping, and the plan is then derived from it exactly as before.",
                        "Derived operations — one line per operation, each naming the member it happens in and the files it carries, in the order they will run. Above them is the one-line count the footer repeats; beside them, a before-and-after of one member's folders, so the shape is visible and not only listed.",
                    ]),
                    .paragraph("The rules that turn a mapping into operations are fixed, and worth knowing, because they decide how much actually moves. A mapping is one level deep: it names a member's direct children, and whatever is inside a folder is carried along. One name to one free target is a rename — a single operation that carries every file inside it, and on a cloud tree it never forces a stored-online file to download. Several names to one target renames the fullest and merges the rest into it. A merge moves the contents in; it never puts one folder inside the other, which would be the opposite of converging."),
                    .bullets([
                        "Nothing is dropped to make the shape fit. A folder the target shape has no slot for stays exactly where it is and is listed as kept.",
                        "Collisions keep both. A file whose name already exists at the destination arrives under a new name and is counted on its own line — never an overwrite, never a deletion.",
                        "The footer keeps apart the numbers people confuse: folders renamed, files moved by a merge, and files merely carried along by a rename — which move nothing at all. Folders kept, folders created and collisions join them when there are any, and a count of zero stays out of the sentence.",
                        "“Export plan…” is the safe way to stop, and it does two things. It writes the plan as a dated JSON file beside your survey — readable in any text editor, with nothing at risk — and names the file in the sheet. It also keeps the plan, so the finding card swaps “Plan…” for “Review N operations” and still says so after you quit and come back. Closing the sheet without exporting keeps nothing.",
                        "Where sibling families share this one's vocabulary the sheet names them, because a shape chosen for one alone can leave the others disagreeing with it. You can plan them together on a single shared mapping — each family's operations are still derived, reviewed and applied separately, since a row that is right for one can be wrong for its sibling.",
                    ]),
                    .tip("The only button in this sheet that touches your folders is Apply, and it is styled as the destructive act it is — see “Apply, and take it back”."),
                ],
                related: ["restructure-shapes", "restructure-apply", "intelligence", "organize-workspace"]
            )),
            Topic(id: "restructure-apply", title: "Apply, and take it back", systemImage: "arrow.uturn.backward.circle", article: Article(
                intro: "Apply is the only thing in Restructure that writes. It runs the operations you reviewed, and it puts the way back on disk before it starts. The steps tick past as they run, so the reversal is visibly in place before the first folder moves.",
                blocks: [
                    .paragraph("What one landing does, in order:"),
                    .bullets([
                        "It refuses to start while a scan, a Verify All, or another file operation is running — with a sentence saying so, rather than a queue that would run later without you.",
                        "The reversal is written to disk first, so a crash halfway still leaves something to undo.",
                        "Every source and destination is re-probed immediately before its own operation. A folder holding a file the plan never listed is skipped and named, and the rest of the plan still runs. A destination taken since the plan was made gets a new name rather than an overwrite.",
                        "The result is checked by re-listing every touched folder and counting it a second way, independently of the code that did the work. The card carries the verdict. A mismatch is reported and never rolled back on its own — a checker that says everything is broken is usually the thing that is broken.",
                        "The survey is re-derived from a fresh walk of the tree. That walk reads folder and file names only, so it takes seconds — and it is why a finding disappears because the tree was re-read, not because something was marked done.",
                    ]),
                    .paragraph("The banner afterwards has the same shape whether or not everything ran: what happened, what did not, and what to press. A pass that skipped something never reports the way a clean one does. If the operations landed but the survey could not be refreshed, the card says that in its own words rather than borrowing either the success or the failure sentence."),
                    .paragraph("Removing folders is a separate, opt-in step, and it only ever removes folders — no file is deleted by Restructure at any stage. “Remove emptied folders…” on an applied card offers the folders that landing itself emptied; the empty count in the crowding strip offers the same sheet for folders that were already empty before you started. Both split the list the same way: date buckets ticked, category names left for you to decide, each path printed in full because there are few enough to read. Everything ticked goes to the Trash."),
                    .bullets([
                        "⌘Z takes back the whole landing as one step. It lives in memory, so it is gone once you quit.",
                        "“Undo this reorganisation” is the other one, and it is not ⌘Z. It replays the reversal kept on disk through the same guards and the same re-probing, points the survey back at the profile the landing started from, and survives quitting. It can partly fail — a file that has moved on since is left where it is and named — and the card says what could not be put back.",
                        "Only the newest landing can be taken back. Older ones are listed under it, newest first, each saying to undo the newer landing first rather than offering a button that would refuse.",
                        "Undo This Reorganisation is in the Organize menu too, where it needs no selection at all.",
                    ]),
                    .tip("Every landing is written to the Activity Log on one line — what ran, what it counted, what the check said, and which survey it produced. That line is how the truth of an apply is found months later."),
                ],
                related: ["restructure-plan", "undo-redo", "staying-safe", "activity-log"]
            )),
            Topic(id: "restructure-scaffold", title: "Set up a new year", systemImage: "calendar.badge.plus", article: Article(
                intro: "Every January a folder turns up with files in it and no structure. “Set up like its siblings” gives it the folders the rest of the series already has — and moves nothing.",
                blocks: [
                    .bullets([
                        "Restructure reports it as a Series finding, listing the folders the family expects and how many of its siblings have each one.",
                        "“Set up like its siblings” creates exactly those folders and nothing else. No file moves, and ⌘Z removes them again — as long as they are still empty.",
                        "To File then opens scoped to that folder alone and proposes a home for each loose file, with its usual evidence and its usual undo.",
                        "A family whose members all disagree offers no button, because there is no shape to copy. The card says so; the loose files still go to To File as they are.",
                        "Until the survey catches up the card reads “Scaffolded”. “Update the survey now” re-reads the tree, and the finding then resolves itself.",
                    ]),
                    .paragraph("It is the smallest thing Restructure does and the one you will reach for most often, which is why the Organize overview raises it on its own the month it happens rather than waiting for you to go looking."),
                    .tip("It is also the safest thing Restructure does: the worst it can leave behind is a few empty folders in the wrong place, and one ⌘Z removes them."),
                ],
                related: ["restructure-shapes", "file-loose-items", "organize-workspace", "undo-redo"]
            )),
            Topic(id: "automation-rules", title: "Rules that run for you", systemImage: "wand.and.stars", article: Article(
                intro: "Rules is where you say once where a kind of file belongs — “PDFs that mention ‘invoice’ go in Documents/Invoices/{year}” — instead of answering the same question every time one turns up.",
                blocks: [
                    .bullets([
                        "A rule is a set of conditions — all of them, or any of them — and a destination. Every condition is matched on this Mac.",
                        "The destination is relative to the provider root and can carry tokens like {year}, filled from each file. A file that can't supply one is flagged as needing a look rather than guessed at.",
                        "Preview the rule against the folder you're standing in before keeping it, so one that's too broad shows itself immediately. A word too generic to match on is refused with a reason.",
                        "A rule is written once and steers every scan of that provider's tree, not one folder's.",
                        "Settings ▸ Organize holds the inbox and rule preferences behind the section.",
                    ]),
                    .tip("Rules steer suggestions — they never move anything on their own, and nothing moves without your confirmation."),
                ],
                related: ["organize-workspace", "file-loose-items", "intelligence"]
            )),
        ]),
        Section(title: "Settings and more", topics: [
            // The id stays `providers` — it is a frozen identifier that cross-links and the
            // settings deep link both resolve through, and it is not copy. The title is copy, and
            // it follows the tab: that pane lists plain folders alongside the cloud accounts, which
            // is why it stopped being called Providers.
            Topic(id: "providers", title: "Sources and connections", systemImage: "externaldrive", article: Article(
                intro: "Settings ▸ Sources is where SyncCloud lists everywhere it can work: the cloud accounts it found on this Mac, and any folder you add yourself. Rename them, hide the ones you don't use, or point one somewhere else.",
                blocks: [
                    .bullets([
                        "Cloud accounts are discovered automatically from the system's cloud-storage folder; toggle any off to hide it from the pane menus. At least one source has to stay on.",
                        "Add any folder on this Mac as a source — Compare and Organize work the same over it.",
                        "Rename a source to whatever makes sense — the pane colors follow the name.",
                        "One source can be marked primary during setup: that's the tree SyncCloud learns your folder conventions from.",
                    ]),
                ],
                related: ["choose-folders", "setup", "appearance"]
            )),
            Topic(id: "people", title: "People and names", systemImage: "person.2", article: Article(
                intro: "Settings ▸ People is the household Organize works for. It is a short list of names, and it is what lets the app tell one person's document from another's.",
                blocks: [
                    .bullets([
                        "It keeps one person's document out of another's folder.",
                        "It chooses between two folders that differ only by person — School/Aditi beside School/Divit.",
                        "Add each person's full names as documents print them. That is what makes a shared surname attributable to the right person.",
                        "Names are matched longest-first, so “Aditi Abhishek” reads as Aditi alone rather than as two people — which matters when a first name is also somebody else's surname.",
                        "“Look for names” reads the documents you have already filed and offers the forms it finds, so a name you never thought to type can still be added with one click.",
                    ]),
                    .paragraph("Setup asks for the list and proposes what a walk of your folders found, but nothing is ever locked in: a name can be added, changed or removed here at any time, and ⌘K's People rows gather everything belonging to whoever is on it."),
                    .tip("Nothing here leaves your Mac, and no document text is kept — only the names you add. A name left off costs nothing but attribution; those documents are sorted by their content instead."),
                ],
                related: ["setup", "file-loose-items", "command-palette"]
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
                intro: "Tune how SyncCloud looks — theme, accent, translucency, and the shape of its surfaces.",
                blocks: [
                    .bullets([
                        "Theme — System follows macOS (including its light/dark schedule); Light and Dark pin SyncCloud regardless of the system setting.",
                        "Accent color — the hue everything is tinted with — and Tint, how strongly the window carries it. Subtle keeps a faint tint rather than removing it; for none at all, pick the None accent.",
                        "Glass effect — Clear, Frosted, or Solid surfaces.",
                        "Content surface — Unified or Cards panes.",
                    ]),
                    .tip("Text size and row spacing have a tab of their own — Settings ▸ Readability, directly below this one."),
                ],
                related: ["readability", "providers"]
            )),
            Topic(id: "readability", title: "Text size and row spacing", systemImage: "textformat.size", article: Article(
                intro: "Settings ▸ Readability answers one question — how much do you want on screen? Text size and row spacing sit together, with a row of presets over them and a live preview under them.",
                blocks: [
                    .bullets([
                        "The presets are one click for both settings at once: every step to the right shows less and reads bigger. Default is 100% text with comfortable rows.",
                        "Text size runs from 90% to 135%, in steps of 5, with Small, Default, Large and Largest named under the slider's ticks.",
                        "The boost is spent where it's needed — the 9 to 11pt captions and secondary rows grow noticeably, while headings barely move. It's a readability setting, not a uniform zoom.",
                        "Row spacing is Comfortable or Compact. Comfortable keeps the standard row height and shows each file's size and date; Compact fits more rows and hides that line to do it.",
                        "The preview under the controls draws real file rows at the pair you've chosen — the one thing on screen that shows what Compact actually costs.",
                    ]),
                    .tip("The presets are a shortcut over the two controls, never a replacement for them. Large text with compact rows is a perfectly good combination; choose it below and the preset row simply shows nothing selected."),
                ],
                related: ["appearance", "keyboard-shortcuts"]
            )),
            Topic(id: "intelligence", title: "Suggestions and AI", systemImage: "sparkles", article: Article(
                intro: "Organize's suggestions come from more than one place, and Settings ▸ Intelligence is where you choose which of them run. Everything that costs money is off until you turn it on, and nothing leaves this Mac unless you say so.",
                blocks: [
                    .bullets([
                        "Names and layout, always — matching a file against what your folders are called and what its own metadata says. No model involved.",
                        "On-device AI (Apple Intelligence) — free, private, and the first pass. Where it isn't available, Organize falls back to names and metadata.",
                        "Reading file contents on-device — more to go on for a file whose name says nothing.",
                        "Refine with Claude — the opt-in second pass. Once a scan has results, a Refine button re-asks Claude about them, billed to an API key you supply and kept in the macOS Keychain.",
                        "“Try another” on a single suggestion is the second route that can spend, asking the better model again about that one file. It has no confirmation of its own, on purpose — a dialog on every card would cost more attention than it saves — so it is the one paid click you make without being asked twice.",
                        "“Refine names with Claude”, inside a Restructure plan, is the third — and the only one not about a file. It asks what a family's folders should be called, sending their paths and the candidate names, plus up to five file names per folder if you turn that on, and never a file's contents. What comes back edits your mapping, so nothing from it reaches your folders except through the operations you review.",
                    ]),
                    .paragraph("The cloud pass never runs on its own. You press Refine, and you see a cost estimate to confirm before each one — it is a bulk action, so it is priced before you agree to it. All three answer to the same two caps: a monthly one, off by default, and a lifetime cap that ships at $5 as a backstop. Reaching either stands the paid work down and leaves the free on-device suggestions in place, and so does a model this build has no price for — silently on screen for a single card, and in the Activity Log either way."),
                    .tip("A file that hasn't been edited, renamed, or moved keeps the suggestion it already had, so scanning the same folder again doesn't ask the model — or pay for it — a second time."),
                ],
                related: ["file-loose-items", "automation-rules", "staying-safe"]
            )),
            Topic(id: "command-palette", title: "Go to anything (⌘K)", systemImage: "magnifyingglass", article: Article(
                intro: "⌘K grows the Go to pill at the right of the toolbar into a field, with its results hanging underneath — so the tree you are navigating stays on screen while you type the name of the folder you want. It reaches anywhere the app can go, including places that aren’t on screen at all, and Go ▸ Go to… is the same field, first in that menu because it’s the only item there that can reach a destination you’re not already near.",
                blocks: [
                    .bullets([
                        "Places — the four workspaces, and each of Organize's five sections.",
                        "People — everything belonging to someone on your list.",
                        "Folders — anywhere SyncCloud has surveyed, plus recent and pinned folders. Type a path and it will take you there.",
                        "Sources — point the pane at another cloud account or folder.",
                        "Actions — Rescan, New Folder…, Choose Folder…, Check This Folder’s Shape, Find in Pane…, Settings…, Keyboard Shortcuts, Activity Log.",
                        "Settings — one row per tab, titled “Settings ▸ Appearance”, and matched on the words of the controls on that page rather than on the tab's own name: “glass”, “accent” and “log level” each find the page that carries them. These appear once you type. The empty field answers with where you have been and where you can go, and “Settings…” in Actions is the honest reply there — somebody who has typed nothing has not named a tab.",
                    ]),
                    .paragraph("It answers to your words rather than the menu's: “keys” finds Keyboard Shortcuts, “preferences” finds Settings…, “search” finds Find in Pane…, and “refresh” finds Rescan — not one of which is the item's own name."),
                    .bullets([
                        "Your recent folders are kept between launches, so the first ⌘K of the day opens on the folder you were in yesterday rather than on nothing.",
                        "A path it can’t deliver says which of four things is in the way rather than doing nothing: “Not in any source”, “In Dropbox — switch source first”, “Backup SSD is not mounted”, or “No folder at that path”. Only the last is a claim that nothing is there.",
                        "Folders on a drive that isn’t awake are still listed, marked “Not available” — an empty ⌘K would otherwise read as “you have no recents”. The highlight skips past them and ↩ won’t run one.",
                        "⌘K with the field already open selects what you typed, the way it does in every Mac search field, so the next keystroke replaces it rather than closing the field.",
                    ]),
                    .tip("Everything here already exists as a menu item or an on-screen control — Go to is a second way to reach them, never the only way. A row it can't act on says so rather than doing nothing."),
                ],
                related: ["keyboard-shortcuts", "browse-workspace", "organize-workspace"]
            )),
            Topic(id: "keyboard-shortcuts", title: "Keyboard shortcuts", systemImage: "keyboard", article: Article(
                intro: "SyncCloud is fully keyboard-drivable, and it will show you its own shortcuts — hold ⌥ and they appear on the buttons.",
                blocks: [
                    .bullets([
                        "Hold ⌥ on its own for a moment and every control with a shortcut grows a key badge; let go and they vanish. Press any key, click, or add a second modifier and the badges stay away — so ⌥-click and ⌥-typed characters work exactly as before.",
                        "Because ⌥ is held, the shortcut itself won't fire while the badges are up: look, release, then press.",
                        "The full reference is a window of its own: Window ▸ Keyboard Shortcuts, or ask for it by name in ⌘K.",
                        "⌘1 – ⌘4 switch workspaces; ⌘→ / ⌘← copy the selected differences, and ⇧ makes it a move.",
                        "Space opens Quick Look; ⌥-click a breadcrumb navigates both panes at once.",
                        "⌘X, ⌘C and ⌘V are the file clipboard, and they reach Finder; ⌘A selects the folder the focused pane is in; ↩ renames the selected row.",
                    ]),
                    .paragraph("The menu bar carries the rest, a menu per place. File holds the folder and tab items, the verbs that act on the selected row, and Delete — its Ignore in Comparison appears only while you are comparing, because ignoring is a statement about a comparison and Browse and Storage have none. Edit holds the file clipboard — Cut, Copy, Paste and Select All — with Find in Pane… under them. Go holds ⌘K and the per-pane Back and Forward. Compare holds the four transfers plus Review and Verify. Organize holds its five sections, the verbs that aim them at the selected folder, and Undo This Reorganisation, which is the only item there that needs no selection. View holds the four workspaces and the show/hide switches — View ▸ Hidden Files and View ▸ Info Inspector among them."),
                ],
                related: ["command-palette", "copy-move", "clipboard"]
            )),
        ]),
        Section(title: "Help and safety", topics: [
            Topic(id: "staying-safe", title: "Staying safe", systemImage: "checkmark.shield", article: Article(
                intro: "SyncCloud is built so a wrong click can't quietly cost you data. Several guards stand between you and any irreversible change.",
                blocks: [
                    .bullets([
                        "Confirmations before transfers, overwrites, and deletes — each tunable in Settings.",
                        "Removed files go to the Trash wherever the volume has one, and the last copy is always kept.",
                        "Some volumes have no Trash — a network share, most often — and there is nowhere to put a file on the way out. SyncCloud says so and asks before removing anything there, naming the files it is about to destroy rather than counting them. That removal is permanent, and no undo is offered for it.",
                        "⌘Z undoes an operation, and refuses to overwrite something that changed underneath it. It cannot reach the permanent removal above, and it does not outlive the session — for a reorganisation, that is what the reversal on disk is for.",
                        "Quitting mid-operation warns you first, so a sync is never left half-done.",
                        "Organize proposes and never acts on its own. Every section shows what it would do and waits; nothing moves, renames or goes to the Trash without your confirmation.",
                        "Restructure's plan is the longest reach any of them has, so it carries the most guards: every operation is listed with its reason before you agree to it, re-checked against the disk at the moment it runs, counted afterwards by a second piece of code, and reversible from a record written to disk before the first folder moves.",
                        "Restructure deletes no files, at any stage. It renames, moves and merges folders; the only removal it offers is empty folders, ticked one at a time, to the Trash.",
                    ]),
                ],
                related: ["undo-redo", "activity-log", "intelligence", "restructure-apply"]
            )),
            Topic(id: "activity-log", title: "Activity Log and troubleshooting", systemImage: "clock.arrow.circlepath", article: Article(
                intro: "Every scan and file operation is logged. If something looks off, the Activity Log is where to look — and what to send if you need help.",
                blocks: [
                    .bullets([
                        "Open it from Window ▸ Activity Log, or press ⌘L, to watch the live event stream.",
                        "Filter by severity and copy lines straight from the window.",
                        "The full log is written to sync-cloud.log — Help ▸ Reveal Log File in Finder opens it.",
                    ]),
                    .tip("Attaching the log file to a bug report is the fastest way to get a problem understood."),
                ],
                related: ["sync-history", "staying-safe", "about"]
            )),
            Topic(id: "sync-history", title: "Sync History", systemImage: "clock.arrow.circlepath", article: Article(
                intro: "Copies, moves and deletes are recorded in a durable history that survives quitting — filterable, exportable, and reversible a whole run at a time.",
                blocks: [
                    .paragraph("Unlike the live Activity Log, which forgets when you quit, Sync History is written to disk as a structured record of each operation — its time, action, direction, the paths involved, and the size."),
                    .bullets([
                        "Open it from Window ▸ Sync History.",
                        "Filter by action, date range, or path, and search across everything recorded.",
                        "Export the current view to CSV or JSON for a spreadsheet or your own tooling.",
                        "Undo Last Run reverses the most recent sync in one step, moving files back where they were.",
                        "A Restructure landing is the one thing that does not appear here. It moves files, but it keeps its own reversal — the one behind “Undo this reorganisation” — and writes a single summary line to the Activity Log.",
                    ]),
                    .tip("Undoing a run reuses the same safe reversal as ⌘Z — files come back from where they went, and you can redo afterward."),
                ],
                related: ["undo-redo", "activity-log", "staying-safe", "restructure-apply"]
            )),
            Topic(id: "about", title: "About SyncCloud", systemImage: "info.circle", article: Article(
                intro: "SyncCloud compares and organizes your cloud folders — a macOS app, plus a matching synccloud command-line tool for scripted workflows.",
                blocks: [
                    .bullets([
                        "SyncCloud ▸ About SyncCloud gives the version and the build number; the foot of the Settings rail carries the version on its own.",
                        "The CLI mirrors the app's scan and sync for the terminal.",
                        "It also reports structure: synccloud restructure prints what Restructure would find in the surveyed tree, as a summary or as JSON for your own tooling. It is report-only by design — there is no flag that applies a plan, because every guard around Apply is about a person reading the operations first.",
                        minimumSystemRequirement,
                    ]),
                ],
                related: ["what-is-synccloud", "activity-log", "restructure-shapes"]
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

/// The Window ▸ Activity Log item. A separate View (not inline in the `.commands` builder)
/// because `openWindow` is an Environment value the App struct doesn't carry — the same reason
/// `ShortcutsWindowCommand` exists.
struct ActivityLogWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Activity Log") { openWindow(id: "activity-log") }
            .keyboardShortcut(AppChord.activityLog.key, modifiers: AppChord.activityLog.modifiers)
    }
}

/// The Window ▸ Sync History item — the durable, exportable, reversible history window (X2).
/// A separate View for the same reason as `ActivityLogWindowCommand`: `openWindow` is an
/// Environment value the App struct doesn't carry.
struct SyncHistoryWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Sync History") { openWindow(id: "sync-history") }
    }
}

// MARK: - Resizing

/// Which part of the Help card's frame a resize drag has hold of.
///
/// The card stays **centred**, so a drag moves the grabbed edge and the opposite one moves with
/// it — see ``HelpCardSize/resized(from:by:grip:within:)`` for why that means doubling the
/// translation rather than adding it.
/// The Help card's eight grips.
///
/// **A forward to ``ResizableCardGrip``, not a second table.** The direction table this used to
/// spell out — `.leading` grows the card when dragged LEFT — moved to `Design` when the Compare
/// Copies overlay became resizable too, because two copies of a sign table can only agree by
/// luck. The name stays so this file's 29 test references keep naming the thing they test.
typealias HelpCardGrip = ResizableCardGrip

/// The Help card's size: its bounds, and the one rule that resolves a drag into a new one.
///
/// **Pure, because the view around it cannot be built in a test.** `HelpView` is a SwiftUI `View`
/// with `@State` and `@AppStorage`; a clamp written inline there is a clamp no test can flip. The
/// call site is pinned separately so the rule cannot become one nobody calls.
enum HelpCardSize {

    /// What the card opens at on a machine that has never resized it — the size it was fixed at
    /// before it could be resized at all, so nothing about the default view changes.
    static let initial = CGSize(width: 760, height: 520)

    /// The floor. The sidebar is a fixed 220pt and does not shrink, so the width floor is really
    /// a floor on the ARTICLE column: 560 leaves it 339pt, which still sets a bullet's second
    /// line without hyphenating. Below this the article stops being readable rather than merely
    /// getting narrow.
    static let minimum = CGSize(width: 560, height: 400)

    /// The topic rail's width. Fixed, and it does NOT grow with the card — so a title too long for
    /// it is too long at every card size, which is why `everyTopicTitleFitsTheRail` measures
    /// against this rather than against whatever the card happens to be.
    static let sidebarWidth: CGFloat = 220

    /// The width a topic's title has to set in, derived from the row rather than written down
    /// twice: the rail, less the row's outer 6pt inset a side, its inner 8pt a side, the 18pt
    /// glyph, and the 9pt between glyph and text.
    ///
    /// **A title wider than this wraps; it used to be truncated.** The row set `lineLimit(1)`, so
    /// anything over the budget lost its tail to an ellipsis — silently, and invisibly to every
    /// test that reads the copy as data, where the string is whole. "Who your documents belong to"
    /// shipped that way and read "Who your documents be…" in the rail, and five other titles were
    /// already over it at Default. `HelpRailFitTests` measures against this so the replacement
    /// bar — no title needs more than two lines — is about the rail the card really draws.
    static let sidebarTitleWidth: CGFloat = sidebarWidth - 2 * 6 - 2 * 8 - 18 - 9

    /// The defaults keys. Two, rather than one archived `CGSize`, because a width that survives a
    /// height's decoding failure is strictly better than losing both — and `@AppStorage` reads
    /// `Double` natively.
    static let widthDefaultsKey = "helpCardWidth"
    static let heightDefaultsKey = "helpCardHeight"

    /// The new size for a drag of `translation` that started with the card at `start`.
    ///
    /// **The translation is doubled, and that is what keeps the pointer on the grip.** The card is
    /// centred in the overlay, so half of any growth goes to each side: to move the trailing edge
    /// 10pt right, the width has to grow 20. Adding the translation once would leave the edge
    /// drifting at half the pointer's speed, which reads as lag rather than as a rule.
    static func resized(from start: CGSize, by translation: CGSize,
                        grip: HelpCardGrip, within available: CGSize) -> CGSize {
        ResizableCardSize.resized(from: start, by: translation, grip: grip,
                                  minimum: minimum, within: available)
    }

    /// A size held to the floor and to what the window can actually show.
    ///
    /// **The `max(minimum, available)` is live, not defensive padding.** `GeometryReader` reports
    /// `.zero` on its first layout pass, and clamping straight to `available` there would collapse
    /// the card to nothing on the frame it appears. Preferring the floor when the window is
    /// smaller than the card also fails in the safer direction: an overflowing card is legible and
    /// a 0×0 one is gone.
    static func clamped(_ size: CGSize, within available: CGSize) -> CGSize {
        ResizableCardSize.clamped(size, minimum: minimum, within: available)
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
    /// The topic to open on, when something pointed here rather than opening Help cold.
    var openAt: String?
    let onClose: () -> Void

    var body: some View {
        // The card can now be dragged bigger, so it needs to know what "bigger" runs out at.
        // `GeometryReader` here rather than inside the card: this view already fills the window,
        // and the card's own geometry is the thing being resized — reading the size from inside it
        // would be reading the answer out of the question.
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                card(available: proxy.size)
                    // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                    .contentShape(Rectangle())
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity)
    }

    /// The card, decorated exactly like the Settings and Welcome cards: the accent tint, then the
    /// glass material at the level's face value via `groundedGlassCard`. It used to floor `.clear`
    /// to `.frosted` because this card sits over live app content; the ground under the content
    /// answers that without collapsing Clear and Frosted into the same card.
    @ViewBuilder
    private func card(available: CGSize) -> some View {
        HelpView(available: available, openAt: openAt, onClose: onClose)
            .contentSurface(hue: glassHue, tint: surfaceTint)
            // No hairline overlay here: `groundedGlassCard` now draws it for BOTH schemes. Adding
            // one on top put a second border over the dark specular edge.
            .groundedGlassCard(level: glassLevel)
            .overlayPanelShadow()
    }
}

/// The Help card's content: a searchable topic sidebar on the left and the selected article on
/// the right.
///
/// **Resizable, and still an overlay.** It was fixed at 760×520 on the argument that the content
/// is bounded — which is true of the sidebar and false of the articles, whose longest ones run
/// well past the card and scroll. Nothing else about the overlay changes: the scrim, the centring,
/// the glass card and all three ways out are as they were. The size is dragged from any edge or
/// corner, held between ``HelpCardSize/minimum`` and what the window can show, and remembered.
struct HelpView: View {
    /// What the window can show — the ceiling a drag is clamped to. Passed in rather than measured
    /// here because this view IS the thing being measured.
    let available: CGSize
    let onClose: () -> Void

    @State private var selectedTopicID: String
    @State private var query: String = ""

    /// The remembered size. Two `Double`s rather than an archived `CGSize` — see
    /// ``HelpCardSize/widthDefaultsKey``.
    @AppStorage(HelpCardSize.widthDefaultsKey) private var storedWidth: Double
        = HelpCardSize.initial.width
    @AppStorage(HelpCardSize.heightDefaultsKey) private var storedHeight: Double
        = HelpCardSize.initial.height

    /// The size for the drag in progress, or nil when none is. Kept apart from the stored pair so
    /// a drag that is abandoned mid-flight leaves nothing written, and so the defaults are touched
    /// once per drag rather than once per frame.
    @State private var dragging: CGSize?

    init(available: CGSize, openAt topic: String? = nil, onClose: @escaping () -> Void) {
        self.available = available
        self.onClose = onClose
        // An addressable opening topic, so a surface can point at its own page instead of
        // dropping the reader at the front of the book (proposal O14). An id that does not
        // resolve opens the front, which is the same thing the book does with no id at all —
        // a broken pointer must not be a blank card.
        let opening = topic.flatMap { id in
            HelpBook.sections.contains { $0.topics.contains { $0.id == id } } ? id : nil
        }
        _selectedTopicID = State(
            initialValue: opening ?? HelpBook.sections.first?.topics.first?.id ?? "")
    }

    private var results: [HelpBook.Section] { HelpBook.filteredSections(matching: query) }

    /// The size to draw at: the live drag if there is one, otherwise what was remembered — and
    /// clamped either way, because the window may have been made smaller since, or the stored pair
    /// may have come from a larger display.
    private var size: CGSize { dragging ?? baseSize }

    /// The size with no drag in progress — what is remembered, held to what the window can show.
    ///
    /// **This is also every drag's base, which is why no drag-start needs capturing.**
    /// `DragGesture.translation` is cumulative from the drag's start, and the remembered pair does
    /// not move until `commitDrag` writes it on release, so this expression is constant for the
    /// whole gesture. The first version stashed the size on the first `onChanged` instead, in a
    /// second piece of `@State` that had to be cleared in `commitDrag` — and a gesture that ends
    /// without `onEnded` (interrupted, cancelled) left both set, so the NEXT drag on that grip
    /// re-based on the stale start and jumped by the previous drag's delta before following the
    /// pointer. Deriving the base removes the variable and the failure with it.
    private var baseSize: CGSize {
        HelpCardSize.clamped(CGSize(width: storedWidth, height: storedHeight), within: available)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: HelpCardSize.sidebarWidth)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay { resizeHandles }
    }

    // MARK: Resize handles

    /// The eight grips, laid over the card's own edges and corners.
    ///
    /// **Corners after edges, deliberately.** An edge strip runs the card's whole side, so it sits
    /// under both corners at that end; declaring the corners last puts them on top, where a
    /// diagonal drag expects to find them.
    ///
    /// **8pt strips and 16pt corners, and those numbers are clearances rather than taste.** The
    /// grips sit OVER the content, the way a window's own resize band does, so anything they cover
    /// stops being clickable. The two controls close enough to matter both clear them: the close
    /// button is inset 16pt horizontally and 12pt vertically, so the trailing strip (8) and the top
    /// strip (8) stop short of it and the 16pt corner ends exactly where it begins; the sidebar's
    /// search field is inset 10pt, clearing the leading strip by 2. Thickening either of these
    /// without re-measuring those two would take the ✕ or the field with it.
    private var resizeHandles: some View {
        ZStack {
            edgeGrip(.top)
            edgeGrip(.bottom)
            edgeGrip(.leading)
            edgeGrip(.trailing)
            cornerGrip(.topLeading)
            cornerGrip(.topTrailing)
            cornerGrip(.bottomLeading)
            cornerGrip(.bottomTrailing)
        }
    }

    /// One side, using the window's own seam component so the fixed-coordinate-space rule that
    /// every other resize in this app follows is not re-derived here.
    private func edgeGrip(_ grip: HelpCardGrip) -> some View {
        ResizeHandle(
            axis: grip.vertical == 0 ? .horizontal : .vertical,
            thickness: 8,
            // NEVER `.local`: the strip moves as the card it resizes grows, so in its own space
            // the gesture feeds back on itself and the drag stutters. `ResizeHandle` documents
            // this and requires the parameter for exactly this reason.
            coordinateSpace: .global,
            onDrag: { apply($0.translation, grip: grip) },
            onCommit: commitDrag
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: grip.alignment)
    }

    /// One corner. `ResizeHandle` is single-axis by construction — it draws a strip and shows a
    /// column-or-row pointer — so the diagonal grips are their own small view rather than a third
    /// axis bolted onto a component four pane seams depend on.
    private func cornerGrip(_ grip: HelpCardGrip) -> some View {
        Color.clear
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: grip.pointer))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { apply($0.translation, grip: grip) }
                    .onEnded { _ in commitDrag() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: grip.alignment)
    }

    /// Resolve a drag into a live size, always from ``baseSize`` — see there for why the drag's
    /// starting size needs no capturing.
    private func apply(_ translation: CGSize, grip: HelpCardGrip) {
        dragging = HelpCardSize.resized(from: baseSize, by: translation,
                                        grip: grip, within: available)
    }

    /// Write the dragged size once, on release.
    private func commitDrag() {
        if let dragging {
            storedWidth = dragging.width
            storedHeight = dragging.height
        }
        dragging = nil
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
                .shortcutKeycap("esc")
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
                    // **No `lineLimit`, matching `SettingsRail.railRow`**, which has never had
                    // one. The rail is fixed at 220pt and does not widen when the card is
                    // resized, so a `lineLimit(1)` here does not shorten a long title — it
                    // TRUNCATES it, silently, and worse the larger the text. Measured: five
                    // titles were already past the 165pt a row gives them at Default, and
                    // "Activity Log and troubleshooting" wanted 213pt at Large — on the one
                    // surface a reader enlarges the type to read. Wrapping costs a taller row
                    // in a rail that already scrolls; truncating costs the word.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .scaledFont(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(isSelected ? accentFill : .clear)
            )
        }
        // Selected already wears the accent fill, so it takes the ring-and-lift treatment; the
        // rest wash the same shape they would fill if chosen.
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .row,
                                      shape: .roundedRect(6)))
        // **Which topic is open is carried by ink and fill, and neither is audible.** Without this
        // every row announces as "<Title>, button" and the one that is open is indistinguishable
        // from the ten that are not. `SettingsRail.railRow` is this row with this line — the same
        // shape, the same accent fill, the same selection question — so the omission was a copy
        // that stopped one line early rather than a decision.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.well, style: .continuous))

        case .legend(let items):
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                            .scaledFont(.system(size: 12, weight: .semibold))
                            .foregroundStyle(item.mood.color)
                            .frame(width: 22, height: 22)
                            .background(item.mood.color.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
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
                RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
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

/// The related-topic chips under an article, wrapping onto as many rows as they need.
///
/// Each chip shows a real topic's title and jumps the selection when clicked. Ids are validated by
/// `HelpBookTests`, so a lookup miss here would be a test failure, not a runtime surprise.
///
/// **This was an `HStack`, and "Flexible" was the only flexible thing about it.** An `HStack` given
/// more children than fit does not wrap — it squeezes — and a capsule with a fixed 12pt horizontal
/// inset has nowhere to give but its label, so the text wrapped *inside* the chip. At five chips on
/// the 515pt article column that rendered "Clear out dupli-cates" hyphenated across two lines
/// inside a tall oval. It degraded quietly at three or four long titles too; five is where it
/// stopped being deniable, and only a render showed it — a layout test measures the row, and a
/// squeezed row is exactly as wide as an intact one.
///
/// `FileExplorer.FlowLayout` rather than a third wrapping layout in this repo: it is the more
/// complete of the two already here (it clamps an over-wide child to the row instead of drawing
/// past the edge) and its geometry is tested in `FlowLayoutMathTests`. Spelled with its module so
/// it cannot be confused with `Settings.FlowLayout`, which is a different type of the same name.
private struct FlexibleChips: View {
    let ids: [String]
    let onSelect: (String) -> Void

    var body: some View {
        FileExplorer.FlowLayout(spacing: 8, lineSpacing: 8) {
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
