# SyncCloud — Release Notes

User-facing changes, newest first. For the full commit history see the
[repository](https://github.com/agirish/sync-cloud).

---

## v5.2

### Storage moves into Organize

- **Storage is a section of Organize now, not a workspace of its own.** It is the sixth item on
  Organize's rail, after Rules, and everything it does is unchanged — the treemap, the ranked lists,
  the magnitude bars, and the promise that it never moves, deletes, or evicts a file. What changes
  is where you find it: **⌘3**, then Storage on the rail, instead of a tab of its own. If you quit
  with Storage open, it reopens exactly there.
- **⌘4 was Storage and is now Edit.** The bar is still four segments — Browse, Compare, Organize,
  Edit — so the count has not moved; which four has. That one chord is the thing to relearn.
- **All / Largest / Untouched / Reclaim moved into the page**, as a capsule above the list, because
  the row they used to sit in belongs to Organize's rail.
- **Storage follows Organize's scope.** Set a scope and it re-analyses that folder rather than
  filtering the report it already had — a treemap is a picture of a whole, so a filtered one would
  misstate every proportion in it.
- **Organize's overview page carries a Storage card**: when the last analysis ran, which folder it
  covered, and the totals, with Re-analyze beside it. It is a receipt rather than a to-do — Storage
  never wears a count badge, because a badge means there is something to act on.

### A new workspace: Edit

- **SyncCloud can now change what is inside a file.** Every workspace until now moved files around;
  Edit opens one text file, shows it, and writes it back when you ask. A collapsible file pane on
  the left browses to any folder, a rail beside it lists that folder's text files, and the document
  sits beside them. ⌘4, or the new segment in the workspace bar.
- **Markdown renders in Source, Preview or Split**, with a divider you can drag. Real Markdown — tables
  and task lists included — laid out in the app's own type at Settings ▸ Text size, not a web view's.
- **It saves itself.** A couple of seconds after you stop typing, and whenever the document leaves
  the screen — switching workspace, closing the tab, quitting. Every write is staged and swapped in
  atomically, exactly like every other write in the app, so there is no moment where the file on
  disk is half of anything. **⌘S still means "now"**, and stays available even when the document is
  clean.
- **Autosave stops rather than guessing.** If the file changes on disk while you have it open — or
  an Organize run files it somewhere else — writing would either discard what arrived or leave a
  second copy at the old path. So it stops, says so on the header line, and asks straight away which
  version wins. Declining leaves it stopped rather than asking again every two seconds, and ⌘S is
  how you settle it when you are ready.
- **A file comes back as the file it was.** Line endings are untouched, and a file written in UTF-16
  or carrying a byte-order mark is saved in the encoding it was read in rather than quietly becoming
  UTF-8.
- **It asks before writing over a surprise.** If the file changed on disk since it was opened — or
  was filed somewhere else by an Organize run — ⌘S says so and names which, and Cancel means nothing
  happened.
- **It refuses rather than guess.** A file that is not valid text opens read-only, because saving it
  would replace the parts that could not be read. One that is too large, still in the cloud, or
  holds no text at all is listed and dimmed with the reason, instead of opening empty.
- **The rail has two tabs: Text Files and Outline.** Text Files is the folder's list, with the
  folder it is reading named under the tabs — the same folder ⌘N creates in. Outline is the headings
  in the open Markdown document: click one to go to it, and the heading you are in is marked as you
  move about. Each tab gets the whole rail, so a long document's outline is a list rather than a
  peephole — and it keeps its place per file, so coming back to a document does not send you to the
  top of it. The one exception is the heading you are actually in: if remembering the place would
  leave that off the fold, the outline opens there instead.
- **⌘N makes a new file** in the folder you are in — a name row in the rail, nothing on disk until
  you press ↩, and a name with no extension becomes `.md`.
- **Open in Edit** is on the right-click menu of any text file anywhere in the app — Browse, either
  Compare pane, the columns view — and brings it here with the rail already pointed at its folder.
- **Typing has its own undo.** ⌘Z in the editor takes back what you typed and can never reach into a
  file move or a copy, which have their own history and their own Undo button.

### Writing Markdown, and moving around a document

- **The markup verbs are on the right-click menu** — Bold, Italic, Strikethrough, Inline Code,
  Link…, Heading 1–3 and Body, Bulleted and Numbered List, Task Item, Block Quote, Code Block,
  Horizontal Rule. They are toggles rather than inserts, so Bold on bold text takes the asterisks
  off again, and a verb dragged across several lines asks whether *every* line already carries the
  prefix before it decides to remove one — toggling line by line turns a mixed selection inside out,
  which is never what dragging across a paragraph meant. Each verb goes in the way typing does, so
  ⌘Z takes back exactly one of them, and Cut, Copy, Look Up and the spelling submenu stay where the
  system puts them.
- **A checkbox in Preview can be ticked from Preview.** Clicking it writes the change into the file.
  A checkbox written in the middle of a sentence stays prose, which is the same distinction the
  Markdown parse makes.
- **⌘F searches the open document, and the Replace row is showing when it opens.** Find, replace,
  replace-all, next and previous, and a live match count. The chord routes rather than choosing: with
  the caret in the document it opens the document's bar, and everywhere else it is Find in Pane,
  unchanged.
- **A status line under the document** gives words, characters and lines, where the caret is by line
  and column, the encoding the file was read in, and how its lines are terminated — LF, CRLF, CR, or
  Mixed where a file holds more than one kind. **Line endings are named, never normalised:** these
  are cloud folders shared with other machines, and an editor that quietly rewrote a file that
  arrived from Windows would report the whole of it as modified to every sync client on the account.
  The strip sheds segments as the column narrows, keeping the caret longest — it is the only one that
  changes as you work and the only one you cannot get anywhere else.
- **The rail filters by name**, behind a button rather than a permanent row, because 232pt is too
  narrow to spend one on a control most sessions never touch. Case- and diacritic-insensitive, and a
  filter of nothing but whitespace is no filter at all: somebody who has typed a space and stopped is
  mid-thought, and answering "no files" to that is a rail that appears to have emptied itself.
- **The file with unsaved changes wears a dot in the rail**, at the leading edge of its row — accent
  while the write is pending, amber when writing has stopped, nothing when the file matches the
  buffer. Only the row that is actually open can wear one.
- **Wrapping and spell checking are yours to set**, on the text view's context menu and remembered
  across launches. Everything that rewrites text *unasked* — smart quotes, dash substitution, text
  replacement, autocorrect — stays off with no switch anywhere, because these are real files in real
  cloud folders and a curly quote in somebody's YAML is a corrupted file. Continuous spell checking
  rewrites nothing; it draws a red line, which is why it is the one that is offered.
- **Links open, and local images draw.** A `#heading` link scrolls the preview instead of leaving the
  app, and a near-miss scrolls nowhere rather than sending you somewhere you did not ask to go. An
  image already on this disk is drawn; **one that is still in the cloud is refused and says so**,
  showing the alt text its author wrote — drawing it would materialise it, pulling a file onto your
  disk and through your connection because you opened a note.
- **Autosave can be switched off for one file**, on the line under its name — then nothing is written
  until ⌘S, and the questions you expect on the way out come back for that file. It is session-only
  by choice: quitting restores autosave everywhere, because a remembered list of files that silently
  do not save would stay invisible until it cost something.
- **Undo survives a file switch.** Each document keeps its own history, so coming back to a file you
  edited earlier can still take back what you did there. A history is thrown away rather than
  replayed when the file comes back different — reloaded from disk, filed elsewhere by an Organize
  run, or left with autosave off and abandoned with "Don't Save".
- **The document header answers two questions and stops.** Which file, and how you are looking at it.
  The size moved down to the status line beside the other measurements, so the header no longer grows
  as the file does, and the status word now appears only where it changes what you have to do:
  `unsaved — ⌘S` when autosave is off for this file, a stop when it has stopped, `read only` when
  saving is not on offer. The rest of the time the dot beside the filename is the whole answer.

### Comparing two files is findable now

- **Select a file and the action bar offers "Compare with…"** — press it, then click the file to
  compare against, in either pane and in any folder. One selected file is what every click already
  gives you, and it is the only route that reaches a counterpart in the OTHER pane: selecting there
  would clear the selection here, so "one on each side" is not a state that exists.
- **⇧⌘C does the same from the keyboard**, and the verb is on the Compare menu and in the ⌘/
  reference too. Every way into the file-pair viewer used to be a right-click, which meant that if
  you did not already know it existed you would not find it.
- **Two files selected together still compare in one press**, where you can select two — the button
  reads plain "Compare" then, because that click finishes the job.
- **"Compare with…" is on every file's right-click menu, always.** Pick it, then click the other
  file — in either pane, in any folder, after navigating as far as you like. The mode stands until
  you complete it, press esc, or click the armed file again; a bar across the foot of the window — a
  few points from the action bar you pressed — says which file is waiting, and the armed row wears a
  mark.
- **The cross-pane comparison works with a left-click now.** It always worked with a right-click and
  only a right-click — a left-click in the other pane silently discarded the file you had lined up,
  because selecting in one pane clears the other. The armed file no longer lives in a selection, so
  the click that used to lose it is the one that completes it.

### Two scans of one page, lined up

- **The pixel difference aligns the two pages before comparing them, best effort.** Two scans of the
  same sheet, fed in a degree apart, used to glow all over and the view said so. It now estimates
  the skew and offset between them, corrects it, and captions what it corrected — "aligned before
  comparing — a 1.00° skew and an offset corrected, best effort".
- **It refuses more readily than it aligns.** The estimate is judged on the sharpness of its match,
  not on how much error it removed: two genuinely different pages always have a *best* candidate,
  and scoring by improvement alone accepted them. Where the match is not sharp the pages are
  compared as they are and the original caveat stands, so the view never claims an alignment it did
  not achieve.
- Only the page you are looking at is aligned. The strip's dots answer "did anything change", which
  a skew does not change the answer to.

### Less waiting

- **Switching into Organize was costing a couple of seconds, and now does not.** The structure
  detectors' vocabulary pass walked every folder in the profile once per child of every family with
  four or more members — squared in the number of folders — on the main thread, inside a redraw. On a
  real 5,020-folder profile `synccloud restructure --json` returns byte-identical output before and
  after and drops from **1.78 s to 0.15 s**. It was never confined to Organize, either: the same
  answer was read on every window redraw whenever a single folder was selected, so the sweep could
  stall the app from anywhere in it.
- **The text diff's cost cap is measured now, not estimated.** The old estimate read *zero* for two
  files holding the same lines in a different order — a re-sorted CSV, two exports sorted
  differently, a log interleaved by two writers — so those sailed past the cap into a comparison
  that could not be stopped: 5,000 lines a side took 0.96 s, 10,000 took 3.86 s, 20,000 took 16.5 s,
  and a 100,000-line log ran to minutes of a pinned core with no way out. The walk now counts its own
  steps against a real ceiling and can be cancelled. **Shuffled 15,000 lines a side: 13.89 s becomes
  1.83 s.** The change loosens as well as tightens — two all-different 20,000-line files are now
  diffed in 1.75 s where they used to be refused outright — and a pair that is still refused is
  refused after about 1.9 s, because reaching a ceiling means spending it first.
- **The compare surface stops redoing work you already waited for.** The text diff was keyed on the
  display mode, so every toggle between modes re-read both files and diffed them again; entering a
  pixel mode re-decoded both images before comparing. Neither the diff nor the page walk could be
  stopped when the surface closed, and a page walk could leave fifty PDF opens queued on the same
  lane a running scan uses. All of that is keyed, cancelled and cached now.
- **Changing workspace no longer walks the filesystem several times over.** The folder sidebar
  refreshed two to four times per switch, each refresh doing its whole disk half synchronously on the
  main thread — a stat per source root, per pin and per recent, a volume enumeration with a read per
  volume, a stat per standard place and device. With eleven sources that is a hundred-odd stat chains
  and a volume walk, repeatedly, for one click. On a local disk it was milliseconds; on a sleeping
  external drive or a stalled network mount any one of them blocks for seconds — and this app is
  pointed at Google Drive and Dropbox. The walk is coalesced to one per switch, moved off the main
  thread, and the volume list is cached between mount, unmount and rename.
- **Smaller repeats, all on paths you were already using**: the Storage report was re-read and
  re-decoded on each of six triggers and, where the current folder had no saved report, on every pane
  move; the pane-override map was parsed from JSON on every one of three dozen reads, several per
  redraw; and Organize's rail measured every label afresh on each pass instead of asking the cache
  the rest of the app measures through.

---

## v5.1

### Duplicates

- **"Compare copies" works on files, not just folders.** A file group's copies each carried a 40pt
  thumbnail and that was the whole comparison; folder groups got a side-by-side review. Any two
  copies now open in one surface: a strip across the top giving name, location, size, date and — for
  two PDFs — page count for both, with whatever differs picked out, and two live previews under
  it. Choose which copy to
  keep with ←/→ or the button over either pane; the card underneath follows.
- **The verdict is one copy, not the whole group.** Trashing from here removes the copy you were
  looking at and leaves a third copy of the same file alone. It goes through the same last-moment
  re-check every other removal does: if either copy changed since the scan — or a rescan landed
  while the surface was open — it refuses and says which one and why, rather than trashing on a
  verdict that has expired.
- **Two copies the group is not keeping get no verdict at all.** Open the second and third copies
  of a three-copy group against each other and neither of them is the keeper — so neither is
  marked as one, the trash button is withheld, and a line names the copy that IS being kept. The
  facts on screen are current, so it does not send you off to rescan.
- **⏎ and esc both mean Done.** Trashing a copy is always a deliberate click.
- **A byte-identical pair can be re-checked on the spot.** "Verify now" hashes both files as they
  are on disk right now, and reports three outcomes rather than two: they match, they no longer
  match (so the scan is stale — rescan before removing either), or one of them could not be read,
  naming which side and why.
- **A copy that has not been downloaded says so** and offers to fetch it, instead of showing an
  empty pane. Previewing it would pull the whole file down, which on a cloud folder is the normal
  case rather than the exception.
- **The surface resizes and remembers it.** Drag any edge or corner; it opens at that size next
  time, held to what the window can actually show — so moving to a smaller display cannot leave
  its verdict bar off screen.

### Two PDFs, or two images, move together

- **Synchronised panes for PDFs and images.** Scroll or zoom one side and the other follows, and
  ⌥ held breaks the sync while you move one alone. Zoom survives a trip out to an overlay mode and
  back, so reading a table closely, checking the pixel difference and returning does not drop you
  at fit-to-page. Quick Look has no scroll or zoom to synchronise at all, which is why this arrives
  with per-type viewers rather than earlier.
- **Paging is the PDF half — two images have no pages to turn.** ⇞/⇟ move both sides at once, and
  scrolling onto another page walks the page strip along with you, so `1`–`4` open on the page you
  were actually reading rather than on the one you started at; ⌥ breaks that too. A
  strip under the panes marks each page once it has been compared — green where nothing changed,
  amber where something did, with the figure in the tooltip; blue where only one document has that
  page, red where a side could not be rendered. A page carries no mark until its comparison has
  actually run, so nothing on the strip stands for a page that has not been looked at. Where one
  document is longer, the strip runs to the longer one and the shorter side stops at its last page
  rather than hiding the pages only one file has.
- **Three ways to overlay the two sides,** picked with `2`–`4` or the segments — `1` is the plain
  side-by-side you start on: swipe a divider
  across them, blend one into the other, or see the pixel difference on black — where identical is
  black and anything that changed glows. The difference view says outright that it compares pixels
  with no alignment, so two scans of one sheet of paper glowing all over reads as scanner noise
  rather than as content.

### Two text files, line by line

- **A read-only side-by-side diff** for text, source, CSV, JSON and the like. An edited line shows
  as one row with both versions on it and the changed WORDS picked out, rather than as a deleted
  line above an added one. ↑/↓ step between changes, not between lines.
- **Files that are not quite text still open.** A log truncated mid-character decodes with the
  unreadable bytes marked and says so, and a file that announces its encoding with a byte-order
  mark is read in that encoding rather than sniffed as binary. Files over 4 MB, files that are not
  downloaded, and files that turn out to be binary each say which of those they are.
- **A diff it cannot afford is declined, not started.** Two large files with almost nothing in
  common would take minutes to line up, and a single line long enough to be a whole minified file
  would take as long again to compare word by word. Both are now refused up front and said out
  loud — the other modes still work, and a line marked whole says it was marked whole — rather
  than spinning over a pane that is never going to answer.
- **CRLF against LF is reported as a line-ending difference, not as a thousand changed lines,** and
  two files holding the same words in different encodings show no changed rows at all — the
  comparison is over decoded text, not raw bytes, and a note above the diff is what tells you the
  bytes differ.

### The same surface in Compare

- **"Compare…" on a changed row in the Differences list** opens the identical viewer — facts,
  previews, modes, the text diff — with a Done-only bar. Differences already owns copying, moving
  and ignoring a row, so the viewer adds no second way to do them.

### Deleting

- **A move between volumes spends a retry before it destroys anything.** Such a move copies to the
  destination and then clears the source to the Trash — and if that step failed, the cleanup fell
  straight through to a permanent delete. The refusal macOS raises on files you own, in folders you
  own, is exactly such a failure, so under it a move could quietly become a deletion of the
  original. That refusal is now retried first, which is what rescues it. The unrecoverable fallback
  is still there for a volume with no Trash at all, and the log names it when it is taken.
- **A Trash refusal is retried before it is reported.** The app asks the system's own Trash
  service, and failing that re-registers the item with a move in place and tries again. Whether
  that clears any particular refusal is not promised — the failure comes and goes on its own — but
  one that survives both attempts now says what was tried and what was observed, rather than
  naming a cause it cannot know.

### Elsewhere

- **The Activity Log survives a log file it cannot fully decode.** One byte of invalid UTF-8 — an
  append cut short by a crash, or a path written by another process — took the entire
  previous-session history with it and put an error note where the history should have been. The
  unreadable bytes are now marked and everything around them loads.

### Known limitations

- Folder groups keep the existing Compare-workspace review; this surface is for pairs of files.
- The pixel modes align pages by their frames only. Two scans of the same page will not line up,
  and there is no de-skew or registration pass.
- Formats with no typed viewer — Word documents, presentations, video — get two independent Quick
  Look panes and a caption saying they do not scroll together.

---

## v5.0

**Restructure stops being a report.** It could recognise one thing — a family of folders organised
more than one way — and all it could do was say so. It now recognises eight kinds of structural
drift, turns most of them into a plan you review name by name, applies that plan, and writes the way
back to disk before it starts.

Requires **macOS 26**, unchanged from the 4.x line. Coming from 3.x or 2.x, read the v4.0 section first.

### What Restructure finds

- **Eight kinds of finding where there was one:** siblings shaped differently; a year with files and
  no folders yet; a year hiding inside a name (`IRS Docs - 2023`); two names for one thing
  (`Form W-2` beside `Form W2`); a folder in an inbox mirroring a real destination; files parked
  above a run of year folders; a leaf sitting beside the folder that owns its concept; and two
  branches holding the same documents under parallel names. Each card names what it saw and the
  class of change that would fix it, so a rename reads differently from a merge before any sheet opens.
- **Crowding is counted, not accused.** Pass-through folders, single-file folders and empty ones get
  three counts above the findings — no badges, no cards, because every real tree has them. Only the
  empty count offers to act.
- **The badge counts what you can drive to zero.** Findings that hand off to another surface, and the
  crowding counts, stay out of it.
- **"Nothing is wrong" and "I could not check" never share words.** A clean result says how many
  folders it checked; a missing survey says it has nothing to read.
- **The lens says when the tree was last looked at,** and offers a Rescan once that stamp is old
  enough to matter. It used to report only how many folders it covered.

### Planning a new shape

- **One mapping, applied to every member.** The sheet lists every distinct folder name the family
  uses, once, each defaulting to keep — so you answer "what should this be called" a couple of dozen
  times instead of dragging hundreds of files.
- **Nothing is pre-selected.** The shapes on offer are the ones actually in use, each naming the
  siblings that vouch for it. Where the newest members all disagree, the sheet says outright that
  there is no current shape to continue.
- **The cost of a choice is shown where the choice is made.** Point two names at one target and the
  row says it is a merge, and in how many members.
- **Every operation is derived, never typed.** The review lists them in run order, each naming its
  member and the files it carries, beside a before-and-after of one member's folders.
- **Nothing is dropped to make the shape fit, and collisions keep both.** A folder the target has no
  slot for stays where it is and is listed as kept; a file whose name is already taken arrives under
  a new one. Never an overwrite.
- **Optional refinement with Claude, on the names only.** It answers row by row against your mapping
  and declines where a folder says nothing about itself. Accepting a row edits your mapping and the
  plan is re-derived — there is no path from a suggestion to the disk that skips the review.
- **"Export plan…" is the safe way to stop.** It writes the plan as a dated JSON file beside your
  survey and keeps it, so the card offers "Review N operations" afterwards, even after you quit.

### Applying, and taking it back

- **Apply is the only thing here that writes,** and you can watch it run. It refuses to start while a
  scan or another file operation is running — with a sentence, not a queue. **The reversal is written
  to disk before the first folder moves.**
- **Every claim is re-probed at the moment of the action.** A folder holding a file the plan never
  listed is skipped and named while the rest of the plan runs; a destination taken since gets a new
  name rather than an overwrite.
- **The result is checked by a second code path,** independent of the code that did the work, with
  the verdict on the card. A mismatch is reported and never rolled back automatically.
- **A finding disappears because the tree was re-read,** not because it was marked done. The landing
  ends by re-deriving the survey from a fresh walk. If that step fails, the card says so in its own
  words rather than borrowing the success sentence.
- **Removing folders is separate, opt-in, and folders only.** No file is deleted by Restructure at
  any stage. The sheet prints every path in full and moves what you tick to the Trash.
- **Two undos, and the card says which is which.** ⌘Z takes the whole landing back as one step and
  is gone once you quit. **"Undo this reorganisation" replays a reversal kept on disk** through the
  same guards and re-probing, and survives quitting — it can partly fail, and it names what it could
  not put back.

### Setting up a new year

- **"Set up like its siblings" creates the folders and moves nothing** — the folders the rest of the
  series has, each justified by how many siblings already have it. ⌘Z removes them again. The loose
  files go to To File, scoped to that folder alone.
- **The Organize overview raises it the month it happens** rather than waiting for you to go looking,
  and remembers being dismissed.

### Getting to Organize

- **The Organize menu learns the new verbs.** "Plan This Folder's Shape…" and "Set Up Like Its
  Siblings" join it, aimed at whatever the focused pane has selected.
- **"Undo This Reorganisation" is deliberately not in Edit.** It is not ⌘Z — it replays an inverse
  from disk and can partly fail — so putting it beside Undo would have been the most misleading
  place available. It is the one item there that needs no selection.
- **"Check This Folder's Shape"** is in a folder's row menu and in ⌘K, aimed at the folder you are
  already standing on.

### Duplicates

- **Name-only matches are gone.** A group of same-named, different-content folders was a warning
  with no resolution attached, and it crowded out the findings that had one. Folders now join an
  overlapping group **on their own merits** rather than on an average across everything sharing their
  name — so a genuine twin is no longer lost to three unrelated folders that happen to share its name.
- **The pills that name a subset are the filter now.** They looked interactive and were inert. The
  figures that are not subsets stopped dressing like filters: the reclaimable total is plain text.
- **The badge says what you need to do, not what the match was.** Byte-identical groups carry no
  badge at all — their certainty reads in the green reclaim figure, and the space goes to the file's
  icon and name. The rest say "needs review".
- **Picking a different copy to keep no longer reorders the list,** so there is still a before and
  after to compare, and the row under the pointer is the row you clicked.

### On the command line

- **`synccloud restructure` reports the whole detector set** over a surveyed tree, with `--json` for
  the full report and `--profiles-dir` to read a survey from elsewhere. It never touches the disk it
  describes.

### Known limitations

- **The document survey is not in this release.** The folder half — the tree walk Restructure reads —
  ships in setup's Folders step. Reading page one of every document is an hours-long background pass
  and is deliberately not here.
- **The command line stops at report.** There is no `--apply` and no `--plan`: Apply's guarantees are
  about a person reading a plan before anything moves, and a flag that skips the reading skips the
  guarantees.
- **Two branches under parallel names are reported, not planned.** That finding names the pair and
  the documents they share; converging them is not something v5.0 offers to do for you.
- **The structure trend starts empty.** It draws the finding counts the survey has recorded, so it
  has nothing to show until this release has been running for a while.

---

## v4.6

**A source is the whole account now, not its Documents folder.** Every cloud source was discovered
one level below where its content actually begins, so anything sitting beside Documents — Teams
Recordings, a shared team folder, whatever you keep at the top of the account — was not reachable in
the app at all, and every source's breadcrumb started on the same word. The account folder is the
root, where a pane *opens* is a separate setting you can change, and the pane header was rebuilt
around the crumb that now names the source.

On the v4 line, so it **requires macOS 26** — coming from 3.x or 2.x, read the v4.0 section first.

### Sources

- **A source now starts at the account folder.** Folders beside Documents are reachable, and the
  breadcrumb names the source rather than opening on "Documents" for every account.
- **Where a pane opens is yours to choose.** Each account source has an **Open at** row in Settings,
  with **Choose…** and **Reset**; it is measured from the root, so it survives the account folder
  moving. If the folder you picked is renamed away, panes open at the root and the row says so.
- **The root itself is no longer a field, because it is not a preference.** An account has one true
  root and the app discovers it; the row shows it with **Show in Finder**. If you had set a custom
  Location in an earlier version, that is carried forward and the row offers **Reset** to go back to
  the folder the account is signed in at. A folder source is its own root and keeps the single
  editable **Location** field it has always had.
- **iCloud deliberately stays rooted at your Documents folder.** Its real container is a dead end on
  a Mac with Desktop & Documents syncing on — Desktop and Documents appear there as hidden symlinks
  that report themselves as non-directories, so every listing that skips hidden files drops them.
  Rooting iCloud there would have shown two folders out of four while claiming to cover the cloud.
- **Everything you had stored moves with the root.** Both tab strips, each pane's last folder,
  pinned and recent folders, the Favorites order, filing destinations and the per-pair ignore sets
  are all measured from a source root, and are rebased on first launch so they name the same folders
  as before.
- **What you authored is left exactly where you put it.** An automation's destination, the
  loose-files inbox and the taxonomy a filing scan files against stay anchored to the folder a pane
  lands in rather than being re-pointed at the account root — `TODO` names a real folder at the top
  of a OneDrive account as well as one inside its Documents, and moving them silently would have
  changed which one they meant.

### The pane header

- **The provider capsule is gone; the first breadcrumb crumb is the source picker.** The two were
  the same fact in the same corner, tinted the same hue, and the capsule was the larger of them —
  it restated its own second row, and it was what pushed the toolbar off the left edge of the
  header. Clicking the crumb opens the source list, with **Go to &lt;source&gt;** as its first item.
- **The toolbar starts in the same place on every pane.** Measured across the header's sixteen
  layout cases: the bar's leading edge is now at 17pt in all sixteen, where it used to land anywhere
  between 77pt and 372pt depending on how long the source's name was. At 570pt wide, the same pane
  started its toolbar at 223pt for a source called "iCloud Drive" and 372pt for a long custom name — a
  149pt swing from the name alone.
- **Narrow panes keep more of the toolbar.** A 250pt pane draws seven controls where it drew five.
  All nine are now drawn from 330pt, where it used to take 490pt; and a pane with a long custom
  source name at 490pt had room for five and now has room for all nine.
- **The source crumb is drawn as the control it is** — a capsule sized to match the toolbar's own
  controls, carrying the source's mark, its name, and its own disclosure arrow.
- **The trail is bigger.** Crumbs were the smallest text in the header; they are a size up now, with
  more room between them and more space between the toolbar and the trail beneath it.

### The sidebar

- **Your home folder and the startup disk are in Favorites on a first run.** Five standard places
  now, not three. They used to sit in Locations, on the reasoning that home contains the other three
  and a disk is hardware — but they are the two places you navigate to from a standing start, and
  Locations on a machine with several cloud accounts is where you go to find an *account*. Removing
  either from Favorites returns it to Locations.
- **"Restore Standard Folders" is now "Restore Standard Places",** because it restores a disk.
- **A recent no longer carries a second line.** A recent's qualifier is its parent folder, and that
  parent is a top-level folder often enough that the line came out repeating the source badge on the
  row's other end. A recent is somewhere you were minutes ago and recognise; a favorite is one you
  chose once and may not, so only favorites carry the second line. Recents still count toward the
  collision that makes a favorite need one, and the source and folder are still in the tooltip on
  both.

### Tabs

- **Two tabs that would otherwise read the same are told apart.** A tab is titled after its folder's
  leaf name, and its brand mark separates a Dropbox tab from a OneDrive one — but not two accounts
  of the same brand, which is the collision you are most likely to have. A colliding title now takes
  the source's own name, or, for two folders under one source, the parent folder — and only where
  that actually separates them. Tabs that already read differently are untouched, and a duplicated
  tab is left alone rather than growing two identical suffixes.
- **The strip reads like the list under it.** Every tab sits on a surface of its own now, and the
  one you are on takes the same accent tint a selected folder takes in the pane below it — so the
  strip and the list answer "which one am I on" in the same colour. Only the active tab had a
  surface before, which left the others as bare labels and made a strip of five read as one tab with
  some words after it. The live tab quietens in the pane you are not working in, exactly as that
  pane's selected rows do; the rule under it does not, so the strip still names the live tab in the
  pane you are not in.
- **The strip follows the app's accent.** The rule under the live tab was drawn in the macOS system
  accent rather than the one you picked, so it stayed system blue in a Green or Amber window. The
  "None" accent is unaffected, because there it *is* the system accent.
- **A tab switch could leave the other pane on your previous sort order.** Changing the sort
  re-orders both panes' trees off the main thread — brief, but not instant on a large one — and a
  tab switch landing inside that window threw the result away, on the reasoning that whatever
  interrupted it would hand both panes freshly-ordered trees. A tab switch does not: it reloads only
  the pane that moved, so the pane you did not move kept the order you had just changed away from,
  with nothing on screen saying so, until something else reloaded it. You had to be quick to catch
  it, which is most of why it went unnoticed. The re-order now tries again instead of giving up, and
  changing a pane's source reaches the same window in this release, so the fix covers that door too.

### Moving and copying

- **A chosen folder in the Move to… sheet was drawn as two shapes at once.** The sheet's shortcut
  rail, its folder columns and its search results all draw a rounded-rect row, but handed their
  selection and hover styling no shape to match it — and both of those default to a capsule. A
  chosen row therefore wore a rounded-rect accent fill under a pill, and at rest the hairline ring
  traced that pill around the rectangle. Each row now names its outline once and fills, hit-tests
  and rings the same shape.

### Speed

- **Navigating one pane no longer reloads the other.** Switching tabs already reloaded just the pane
  that moved, but *navigating* — the commonest gesture in the app — went through a channel that
  carried no pane with it, so it was honoured as "reload both" and the other pane's tree was
  re-walked on a source and a folder that had not changed. With the prefetch cache warm that is
  wasted work you still see as a flicker; cold, after any file operation, sort change or force
  refresh, it is a full second walk of tens of thousands of files for a tree that was already
  correct. A refresh now names the pane that moved. Anything that genuinely changes both — a
  finished file operation, a date-tolerance change, a sort that needs fresh tags — still reloads
  both.
- **Changing one pane's source leaves the other pane alone.** Picking a different account on the
  right used to reset the left pane as well — the pane you had not been near dropped its tree and
  re-walked behind a spinner, flattened an open Columns stack, cleared its selection, emptied its
  Back history, and went back to its own root. Editing a source's Location in Settings dropped and
  re-walked both trees for the same reason, though it left the selection and history alone. Only
  the pane you retargeted is touched now, on both paths. The comparison itself still refreshes
  whole, because a comparison belongs to the pair — but a tree, a column stack, a selection and a
  history belong to one pane, and the other pane's are all still correct.

### If you go back to v4.5 afterwards

Your **Location settings are safe**: the old key is read and never rewritten, so an earlier release
finds them exactly as it left them. Your **stored positions are not** — tabs, pins, recents and
saved folders are rebased onto the new roots, and an older build reading them back will not find
those folders and will re-root them. Tabs and pins degrade the way they already do for a folder that
has gone; a durable ignore entry stops matching, which un-ignores rows rather than hiding extra
ones. There is no reverse migration.

---

## v4.5

**Refinement, mostly — plus one freeze and one thing quietly wrong.** A bulk sync on a large
comparison locked the window for about eleven seconds at each end, doing nothing in that time but
setting a flag. And a file rewritten *while it was being hashed* could be remembered under a
digest belonging to no version of it. Alongside those, “Text contains” means one thing on every
surface rather than two, the “None” accent finally reads as no accent, and the markers saying
which workspace and which tab you are in travel instead of blinking.

On the v4 line, so it **requires macOS 26** — coming from 3.x or 2.x, read the v4.0 section first.

### Organize

- **“Text contains” now means the exact phrase, everywhere.** It had two readings: the loose
  word-by-word one on the Organize scan, which is the path that moves files, and the strict one
  in the Automations preview. So “tax return” could move a document that said “tax” and “return”
  pages apart, after a preview that said it would not. Separate words are still matchable, as
  “Mentions the words”.

### Duplicates and comparison

- **A file rewritten while it was being hashed could be remembered under the wrong digest.**
  Everything the scan knew about a file came from its path, read before the file was opened, so
  none of it was provably about the bytes that followed — and a rewrite of the same byte count
  produced a digest of two files spliced together. The file is now stat'd through its own
  descriptor before the read and after, where the timestamp catches what a byte count cannot.
- **Files a duplicate scan could not read are counted now, instead of vanishing from it.** A
  candidate that was gone, unreadable, or changed while it was being hashed was dropped with
  nothing recording it — no pill, no note, no log — while every other skip reason was tallied
  and named. They join the “skipped” note now, as “unreadable or changed while being read”.
- **A duplicate scan does less work to reach the same answer.** It read a file's path three
  times before opening it; now once, plus one more for a symlink and one for a file it is about
  to open. On a repeat scan every digest is cached, so that first read is all the hashing does.
  Digest text is now a table lookup, and a long scan publishes progress about a hundred times
  instead of several hundred.
- **Duplicate thumbnails no longer decompress while you scroll.** Each was compressed to PNG
  purely to satisfy a rule about what may cross between threads, then decompressed again —
  lazily, which means at draw time, on the main thread, during the scroll that asked for it.
- **A comparison with ignore patterns set folds them once per scan** rather than once per item
  compared, and folds each name once rather than once per pattern it is tested against.
- **Starting or finishing a bulk sync no longer locks the window while it marks the rows.**
  Flagging each row as in-flight rewrote the whole difference list and asked for a redraw, once
  per row. On a comparison with tens of thousands of differences that cost about eleven seconds
  at each end, doing nothing but setting a flag. The rows are marked in one pass now, and drawn
  once.
- **Rebuilding the difference list stops taking every path apart to ask one question of it.**
  Deciding whether a path is hidden split it into components and built a string for each, once
  per difference, on every rebuild — and hiding hidden files is the one filter of five that runs
  unless you turn it off. On 29,000 differences that was about 37 ms a pass, now about 2 ms,
  with exactly the same files hidden.
- **Scanning a large tree resolves far fewer paths.** Every directory the walk entered had its
  whole path resolved so the scan could tell whether it had been there before — a symlink-loop
  guard that fires essentially never, and about half the cost of entering a directory. Only a
  directory whose last component is a symlink needs it now, and every cycle is still caught.

### Appearance

- **The “None” accent now reads white in light, not the faintest gray.** At low Tint, bare
  material and Graphite's neutral wash landed within a couple of points of the same gray, so the
  two were told apart by their swatches and nothing else. “None” now lays a white film over the
  background in light, titlebar included. Dark is untouched.
- **The Info inspector's toolbar button moved to the far right.** The trailing pill read Go to,
  Info, Logs, Settings, which put the control that opens the right-hand rail three glyphs from the
  edge it opens against. It now reads Go to, Settings, Logs, Info, mirroring the folder-sidebar
  toggle at the far left. Same buttons, same ⌘I.
- **The selected workspace and the active pane tab now slide between positions.** Both markers
  were drawn per item, so switching cut one out where it was and cut a new one in where it was
  going — two bars, one above the other, both blinking. Reduce Motion takes the destination and
  skips the journey.
- **A count that changes rolls its digits instead of cutting to a new number.** Diff totals,
  duplicate-group counts and the filing backlog hard-swapped: the old number vanished, a new one
  appeared, and nothing said they were the same quantity. Words are left alone — rolling a
  word's glyphs reads as a glitch.
- **The first-run sheet answers the pointer.** Seven of its controls drew their own chrome,
  which means macOS contributes no hover state at all — so the app's first impression was its
  least responsive surface. Each has an affordance now, chosen for what the control does.
- **One vocabulary for corner radii.** Eleven distinct radii were hand-written across the app,
  so three chips inside one card could round by different amounts. Four named stops now, each a
  value the app already used most, with the strays moved to their nearest by a point.
- **Twenty-two of the app's animations honour Reduce Motion that did not before.** Opting in used
  to mean wiring an environment read into whatever view owned the animation, so most motion was
  unconditional — friction rather than a decision. What is gated now is anything that travels:
  panes collapsing, a workspace switch, the inspector, tabs sliding under a drag, the focus ring
  moving between panes, the search field growing out of its magnifier, Browse's folder sidebar.
  Motion that reports rather than travels — a hover wash, a rolling count — is left alone.
- **The small inline spinners are drawn at their size instead of shrunk to it.** Three status
  rows scaled an already-drawn spinner down to seven-tenths, and scaling resamples, so those
  three read softer than identical spinners a few files away. They are framed to occupy exactly
  what the old recipe reserved, so no row moves.
- **Twenty-seven controls that are nothing but an icon now have names.** A tooltip is not a name
  on macOS, so VoiceOver read them as “button” and Voice Control could not be told to click them
  at all. Toolbars, row actions, dismiss glyphs and the new-tab plus now say what they do.
  Nothing about this is visible on screen.

---

## v4.4

**Every workspace gets a folder sidebar.** SyncCloud has always known which folders you keep and
which you were last in — it just had nowhere to put them, so the only routes were the pane header's
dropdown and the ⌘K field. There is now a column down the left of Browse, Compare, Organize and
Storage holding all three answers at once: **Favorites**, the folders and places you keep;
**Locations**, every account you have signed into plus your home folder, your disks and the Trash;
and **Recents**, the folders you were last in. Favorites and Recents span every source.

On the v4 line, so it **requires macOS 26** — coming from 3.x or 2.x, read the v4.0 section first.

### The sidebar

- **Three sections, and View ▸ Sidebar (⌃⌘S) shows or hides the column.** Each heading folds,
  and a folded one says how many rows are behind it so it does not read as empty. Drag the
  column's edge to set its width, between 150 and 280 points.
- **Favorites is yours.** It starts as Desktop, Documents and Downloads — Finder's own three —
  and every row can be taken out. A place moves between Favorites and Locations rather than
  appearing in both, and Restore Standard Folders is offered only when one is actually missing.
- **Add a folder to Favorites from the pane you are looking at.** Right-click any folder in a
  pane. The sidebar's rows can only manage folders already listed, and the pane header's jump
  menu acts on the folder the pane is showing rather than the one under the pointer.
- **Each account draws its own mark.** Dropbox's folds, Drive's triangle, OneDrive's lobe — in
  one ink rather than five brand colours down a quiet column. Where two rows would read the
  same word, the account name is added beside it.
- **Drag a row to reorder it — and drag a recent up into Favorites to keep it.** Favorites and
  Locations both hold your own order, and the Locations order is the one Settings stores — so
  the sidebar and the pane header's dropdown cannot disagree.
- **Right-click a row** for Open in New Tab, Add to or Remove from Favorites, and — in Compare
  —
  Open in Left Pane / Open in Right Pane, which sends one folder to one side without changing
  where the next click will land.
- **Show in Enclosing Folder** opens the folder a favorite or a recent lives in, rather than
  the
  folder itself. The question you ask when a name has stopped being enough: two `Legal` folders
  in one account, or a recent you no longer recognise.
- **A local folder that is not a source yet says so before it becomes one**, and can be taken
  back from the row itself. The Trash opens in Finder and is never scanned, hashed, or filed
  into.

### In Compare, the sidebar says which pane it opens into

- **One rule decides which pane, and it is the pane you last clicked in.** Anywhere in it — a
  row, the tab strip, the source chip, empty chrome. The header above the column reads "Opens on
  Left" or "Opens on Right" and describes every row below it.
- **The focused pane is drawn with a faint accent border** along its own card edges, so the
  answer is on screen rather than something to remember. It is the same pane the file action
  bar, ⌘F and the folder-scoped verbs act on.

### Very large folders

- **A pane pointed at a folder with hundreds of thousands of directories in it no longer
  hangs.** The deep walk was bounded for depth and not for width, so a home folder or a whole
  startup disk was walked to the end however long it took. It stops at a budget now, and a
  folder it skipped is read when you open a column into it.
- **A folder the pane has not read yet no longer claims to be empty.** The first paint is
  deliberately shallow so a pane appears at once, which means every child folder arrives unread
  — and the display drew “empty” over the difference. A folder that genuinely cannot be listed
  says “Can't be read”.
- **Every whole-tree pass a workspace can start asks before walking a folder that large** —
  Storage, Find Duplicates, Renames, Filing, and updating folder memory. The prompt says “more
  than”, never a total: the probe that found the folder too big stopped early, so it does not
  know how much it did not see.
- **A comparison that could not read one side in full now says so** , above the differences. A
  folder that cannot be listed has always made SyncCloud report nothing on that side as
  missing, because it cannot tell an absence from something it never read; what is new is that
  the table admits it. The comparison's own scan now stops at the same budget the pane does, so
  either way the count is a floor rather than a total.
- **A source covering the whole startup disk is named after the disk**, not `/`.

### Appearance

- **The Tint slider now sets how coloured the whole window is, and Subtle finally means
  subtle.** It moved only the panes and the Differences area before, and its own bottom end
  painted nothing at all — while the window behind those panes carried the accent at full
  strength whatever the slider said, which is why the two ends looked so alike. At Subtle the
  panes' wash now fades out entirely while the window keeps a quarter of its strength. Vivid is
  unchanged.
- **The pane's tab strip takes the tint with the rest of the pane.** It was the one part of a
  pane
  that never did, so at a strong tint it read as a pale stripe across the top of the pane it
  belongs to.

---

## v4.3

**Mostly repair, and one new thing.** v4.3 is what three reviews of the shipped code found
underneath v4.2, and most of it is one mistake wearing different clothes: **a file that existed but
could not be opened was read as a file that was not there.** Nothing was lost on that read — the
loss came on the next write, because saving needs permission on the *folder* rather than the file,
so the save succeeded exactly where the read had failed. Six stores sat behind that mistake, and
the rest is the same theme elsewhere: undo trusting a folder it had only glanced at, gates trusting
verdicts that had gone stale while a dialog was open, and cloud placeholders read as though their
contents were on disk.

On the v4 line, so it **requires macOS 26** — coming from 3.x or 2.x, read the v4.0 section first.

### Go to

- **Every Settings tab is a ⌘K destination, matched on the words of the controls inside it.**
  Typing “appearance” used to match nothing — the word lived only in Settings' own search
  field, which you cannot reach without Settings already open. Ten rows now, one per tab, in
  the rail's order.

### Files the app could have destroyed

- **A file that exists but cannot be read is no longer mistaken for one that isn't there.** Six
  stores consulted the decode result and never the failure to open, and every consequence was
  silent: the first edit to a person replaced the whole household, one refusal wiped the record
  of everyone you had ever declined. Each store now tells the two apart, moves the unreadable
  bytes aside, and refuses the write until that has landed.
- **A setting only a newer build understands survives your next edit of it.** Five settings
  read tolerantly and then wrote the live value back, so a value this build could not interpret
  read as the default and was overwritten the first time you touched it. The original is kept
  beside the setting now.
- **A key written on a person survives an edit.** The model reads five fields, drops the rest,
  and rewrites the whole file — so a nickname, or a `_why` typed next to the person it
  explains, was gone the first time anybody edited anybody.
- **An unreadable filing artifact suspends the classification cache instead of quietly changing
  its key.** Leaving it out of the fingerprint minted a key that can never occur again once the
  file is fixed, so every classification already paid for became unreachable and the same
  documents would be paid for twice.

### Cloud files that are not on disk

- **Offloaded Dropbox, OneDrive, Google Drive and Box files are recognised as placeholders.**
  The check asked iCloud's question, which is false for every other provider. Online, a filing
  survey opened them and made the provider download your entire offloaded library; offline,
  they were written off as blank and never revisited.

### Undo and redo

- **⌘Z after copying a folder no longer destroys the work you did inside the copy.** It
  compared the folder's own date and child count, which an edit two levels down leaves
  untouched — so ⌘Z read the copy as pristine and trashed it, permanently on a volume with no
  Trash. It records a digest of the whole tree now.
- **Redoing a delete no longer trashes whatever has taken the path since.** The redo re-trashed
  by bare path. Delete a file, ⌘Z, let a different file land on that path, ⌘⇧Z — and the
  replacement went to the Trash with no banner and no log line.
- **A “press ⌘Z to undo” stops standing after the step it points at.** The rename pass and the
  name normalizer wrote the sentence without setting the flag that retires it, so it survived
  onto the next operation and pointed at that one instead. The merge banner had the opposite
  half missing.
- **File operations run strictly in the order you asked for them.** The serial queue's prologue
  hopped off the main actor and back before claiming its slot, so two operations starting
  together could run concurrently. The worst reachable form was a merge's own undo pair
  inverting.

### Duplicates, merging and deleting

- **Folder duplicate groups are judged file by file.** The freshness check counted a folder's
  contents by different rules than the scan used, so any group holding a `.DS_Store` or a
  symlink was refused permanently — and the same offset could equally mask a real loss.
- **The Compare review checks what it is about to trash, and stops promising an undo it cannot
  honour.** The gate passed on existence alone, so a file that landed in the right-hand folder
  while the review sat open was trashed along with it — and the confirmation read “Reversible
  with ⌘Z” even on volumes where nothing reaches the undo manager.
- **Merging duplicates is safer to undo and safer to trash after.** Undo grouping is global to
  the window and the merge held its group open across every suspension, so an unrelated
  operation finishing in that window came back with one ⌘Z. A keeper emptied mid-merge still
  had its copy trashed, and Edit ▸ Undo offered to reverse merges whose copies had been
  destroyed permanently.
- **The permanent-delete confirmation names what it is about to destroy.** The app's one
  unrecoverable dialog discarded the list, and for a single item showed only the basename — no
  help at all when the two candidates are duplicate copies with the same name.
- **A dangling symlink is deleted instead of reported as already gone.** The trash was gated on
  an existence check that follows the link, and that branch had no else: no error, no banner,
  no place in the removed count. You were told it succeeded and the link stayed where it was.

### Verdicts that had gone stale

- **The verified-copy offer re-checks both ends before it writes.** Its guards count this app's
  own writes and nothing else, and the dialog never expires — so a cloud daemon syncing down a
  new version while the offer sat open was invisible.
- **`sync` re-checks its plan against disk before each write.** The plan was drawn once at scan
  time and then executed however long the `[y/N]` prompt sat there, `--verify` included.
- **An automation checks a row is still its file before moving it.** The apply gated on nothing
  more than a non-empty destination, and a dry-run report can sit on screen for minutes.

### Filing

- **A cloud filing pass stands down when it cannot price the model.** The spend check read a
  missing price as zero — the one substitute that fails every consumer in the same direction:
  the estimate reads as free and the cap cannot bind.
- **“Try another folder” says no before it spends, not after.** It routes to the paid tier and
  ran no pre-flight at all — no estimate, no cap warning, no refusal for a model this build has
  no rate for. The check happens on the click now, keeps the free on-device suggestion, and
  says which limit stopped it.
- **“Try another folder” sends the page it already read.** The re-ask went out with the file's
  name and nothing else, though the scan had already extracted its first page and was holding
  it — a paid round trip that could not change anything.
- **A file whose date cannot be read is asked again rather than answered from a stale
  verdict.** The cache keyed an unreadable date as 1970-01-01 and an unreadable size as 0 bytes
  — two values a real file can genuinely have. Such a file is simply left out of the cache now,
  in both directions.
- **A file whose scan never came back is no longer stuck.** The extractor has no timeout, so a
  render that never returned left the file latched, every later attempt a silent no-op,
  surviving any number of rescans. Switching provider clears it, and “File recommended” can no
  longer be started twice.

### The keyboard

- **The Organize review card's ⏎ and ⌫ decide once, unmodified, and only when the card has
  focus.** This is the surface where ⏎ moves real bytes. Every modifier combination ran the
  primary action, a held ⏎ launched four copies of one row, and with Full Keyboard Access on, ⏎
  aimed at the focused Skip button ran the copy.
- **The filing walkthrough's ⏎, → and esc stay inside the card.** They were window-level key
  equivalents, which macOS consults before the first responder — so ⏎ typed into the lens
  header's search field filed the document on screen, and an esc meant for that field discarded
  every approval.

### Renaming

- **A case-only tidy lands on the cased name, and case-only renames work at all.** Renaming
  `07. jul 2016.pdf` to `07. Jul 2016.pdf` produced `07. Jul 2016 2.pdf` — the file collided
  with itself. One layer down every case-only rename failed outright: you could not rename foo
  to Foo.

### Also

- The ⌘K results panel no longer paints dark notches at its corners, and the bulk difference
  menu acts on rows as they are when you pick an item rather than when you right-clicked.
- A symbolic link can be moved into the folder it points at. The check that stops a folder
  being moved inside itself followed the link first, so an alias and its target read as one
  container and an ordinary move was refused.
- A folder name typed into "Create as" no longer follows you to a different destination.
  Pressing “Try another folder” replaced the suggestion under the same card while the field
  kept what you had typed.
  "Try another folder" replaced the suggestion under the same card while the field kept what you
  had typed, so "File here" could apply a name meant for one folder to another one entirely.
- `synccloud` refuses an argument that names both a configured provider and a different folder
  on
  disk, instead of silently picking one.
- The Help book now covers what v4.2 added — the file clipboard, the Storage bars and the ⌘K
  redesign shipped without ever being described in the book that describes the app.

### Known limitations

- **Browse's folder sidebar** is built and reachable from nothing. It is not listed above
  because nothing you can press opens it. It ships when something does.

---

## v4.2

**SyncCloud can set itself up.** The filing engine needed a folder profile that nothing in the app
could produce, so a machine that had never run an out-of-repo script got no routing, no rename
proposals and no Restructure findings, with nothing on screen saying why. In place of the six-page
welcome tour there is now a form that asks four questions and walks your tree.

The other half is reach: the menu bar gains Organize's sections, the row menu's verbs and the
clipboard chords, all of which had working handlers and no menu route; ⌘K becomes a field in the
toolbar you can type a path into; and ⌘C and ⌘V exchange files with Finder.

On the v4 line, so it **requires macOS 26** — coming from 3.x or 2.x, read the v4.0 section first.

### Setting up

- **A fresh install is asked four questions rather than shown six pages of prose.** Your name,
  which discovered sources you use and which is primary, who else is in the household, and
  which folder to learn from.
- **The Folders step walks your tree and writes the profile.** Names and counts only — seconds
  rather than the hours a document survey needs, and it takes effect without a relaunch.
- **It proposes the place names it found, and nothing starts ticked.** Mined from folder names,
  so every mistake it makes is an invention: HPE is an employer, PRD a product stage. Each chip
  says how many folders it would affect.
- **It proposes the household too, from the one folder that says what its children are.**
  Family/Aditi is a person because Family said so. It over-proposes deliberately — a name you
  must think of unprompted costs more than one you refuse with a click.
- **Answers are kept when there is nowhere yet to put them.** You and People have nowhere to
  write until the walk mints a profile. Both rows say so, and are applied to the roster when it
  arrives — adding, never removing.
- **The form will not offer edits `PeopleStore` refuses to write.** Where the roster is one it
  will not write over, the step names the refusal in force and disables Add and Remove rather
  than offering edits that do nothing.
- **It opens by itself only on a machine that has never been set up.** Help ▸ Set Up SyncCloud…
  opens it any time, and persists nothing unless you finish.

### Safety

- **An unreadable pin list was destroyed by the next pin you made.** The folder-jump store
  decoded with `try?`, so a blob it could not read left the store looking like a fresh install
  — and nothing was lost on that read. The loss came on the next write, which encoded that
  emptiness over your curated pins. The bytes are kept aside now and pinning carries on.

### The menu bar

- **Cut, Copy, Paste and Select All reach your files.** All four are text-editing keys, so the
  keystroke is handed back whenever the caret owns it: ⌘C still copies text in a search or a
  rename field. ⌘X then ⌘V is a move.
- **And the clipboard reaches Finder.** A copy writes file URLs to the system pasteboard and a
  paste reads them, both directions. It stays one clipboard — SyncCloud's own list answers
  until anything else writes.
- **Organize has a menu.** Its five sections, ticked, then its four row verbs. Every verb
  refuses a multiple selection, because organizing two folders is two questions.
- **The row menu's verbs are in File** — Open in New Tab, Quick Look, Reveal in Finder, Rename,
  Copy to…, Move to… and Ignore in Comparison, each of which previously needed a right-click on
  exactly the right row.
- **↩ renames the selected row.** A pane key handler rather than a menu equivalent: a
  registered bare ↩ would outrank every default button in the app, and Finder does not register
  it either.
- **Space no longer opens Quick Look on top of the destination picker.** A pick owns the
  keyboard until you answer it, and Space was a list key handler rather than a menu item — so
  it never went through the publication that silences the rest.
- **⌘← and ⌘→ are in the Compare menu.** The four directional transfers worked but had no menu
  route, and a menu item is what lets a chord be read as well as pressed. Their titles name the
  providers.
- **Each auxiliary window is listed once.** Keyboard Shortcuts, Activity Log, Sync History and
  About each appeared twice. One of each pair is generated by SwiftUI and written down nowhere,
  so no source scan could see it.
- **The Window menu says which folders the window is on** — it had read “SyncCloud” for a
  window that could be on any pair of folders in any cloud. Mission Control reads that name
  whether or not a title bar is drawn.

### Go to (⌘K)

- **⌘K grows the toolbar's Go to pill into a field, and the results hang under it.** It was a
  620pt card floating over a dimmed window; the tree you are navigating now stays visible while
  you type.
- **Type a path and it goes there.** Finder's ⇧⌘G as a behaviour rather than a surface. A bare
  name is still a search, or typing Documents would shadow every folder you have.
- **A path it cannot deliver says why instead of doing nothing.** “Not in any source”, “In
  Dropbox — switch source first”, “Backup SSD is not mounted”, “No folder at that path”.
- **Recents survive quitting.** Session-scoped is right for a pane's jump menu and wrong for a
  field whose entire empty state is that list.
- **A sleeping drive says so rather than opening blank.** An external disk that was not awake
  opened ⌘K completely empty, with “no recents” indistinguishable from “not mounted”. Those
  folders are listed and marked Not available now.

### Storage

- **Storage's ranked lists draw a magnitude bar and a share.** Every size was set in the same
  weight at the same position, so a four-fold difference read as nothing until you compared the
  digits. Each bar is scaled to its section's own largest file.
- **The treemap is one ramp instead of ten hues.** Colour was assigned by index, so the eye
  kept looking for a legend that could not exist. It runs deep to pale in your own accent,
  ordered by size, so the colour is the ranking.

### Text size and spacing

- **Text size is a percentage, 90% to 135%, in 5% steps.** It had four stops with a 25-point
  hole between Default and Large. The four keep their names as detents under the slider's
  ticks.
- **They live in a Readability tab of their own.** Text size and row spacing answer the same
  question and sat as two unrelated pickers in Appearance. “List density” is now “Row spacing”.
- **Five presets over the two controls** — each step showing less and reading bigger — with a
  live preview of three real file rows. The preview is the only thing that shows what Compact
  costs: it drops each file's size and date.
- **Your stored size migrates at launch.** Every release before this stored a word rather than
  a number, and a build reading an integer cannot see it — so without the migration every
  chosen size would have opened at 100%.
- **The setup form's first step carries the same preset row**, because somebody who
  needs larger text needs it for the four questions that follow, not after them.

### Help

- **The Help card can be resized, and remembers the size.** Fixed at 760×520 on the argument
  that its content is bounded — true of the sidebar, false of the articles. Eight grips and a
  560×400 floor.
- **The rail stops truncating its titles.** Every row set a one-line limit on a rail fixed at
  220pt, so no window size got the word back: the surface you enlarge the type to read answered
  by removing letters.
- **The book describes the app again.** Nineteen articles became twenty-eight, fixing four
  drifts at once — a Help item that no longer exists, a tab renamed out from under two
  articles, three Organize sections with no article at all, and “Requires macOS 15”, two majors
  out of date.
- New articles cover the setup form, the Organize workspace itself, each of its five
  sections, Readability, Intelligence, ⌘K and the household.
- **The source switch stops naming a column the app does not have.** It described the
  enable/disable switch as “Show <name> in the pane sidebar”, and there has been no pane
  sidebar since 2026-07-14. It names the source-picker list now, which is what it actually
  controls.

### People

- **The person panel stops calling everyone “her”.** Four strings were written to a fixture —
  the header capsule, both group titles and the misfiling subtitle. The panel names the person
  where the group starts and says they/them after.

  Deliberately not a `pronouns` field: that is a new persisted key, an editor, a
  decoder state and a small grammar layer, bought for four strings and wrong for
  every person until somebody fills it in. `relationship` ("wife", "daughter") is
  sitting right there as a shortcut and is not one — inferring pronouns from a
  free-text relationship word is how you misgender somebody.

### Known limitations

- **⌘A in a Tree pane selects the top-level rows only** , not the children of expanded folders.
  Which rows are expanded is private to the view, so “everything visible” would be a guess.
  Columns resolves through the deepest open column.
- **Edit's four items are never greyed out.** A menu item cannot know where the caret is when
  it renders, so disabling Copy with no files selected would grey it out while somebody is
  typing in the ⌘K field.
- **⌘K cannot switch to the source a typed path is in.** It is listed and marked “In <source> —
  switch source first” rather than delivered.

---

## v4.1

Tabs. One pane, many parked locations — the thing that turns a two-pane
comparison into a place where several jobs stay open at once. Behind them the
release is mostly repair: eleven things a v4.0 install really did, most of them
the app destroying or misdescribing a file and saying nothing about it.

On the v4 line, so it **requires macOS 26** — coming from 3.x or 2.x, read the
v4.0 section first.

### Tabs

- **Every pane gets a tab strip.** A tab is a location a pane holds, parked: its folder, its
  column stack, its history and its selection. The strip draws nothing at one tab, and sheds
  down three rungs as space runs out.
- **The strip draws nothing at one tab**, and sheds down three rungs as space runs
  out: every tab at full width, then a floor width with the surplus behind a count,
  then — at the ~220pt Organize and Storage rail — the active tab alone as a chevron
  menu, with a plain count for the rest and a ＋.
- **Finder's chords.** ⌘T opens a new tab *here*; ⌘W closes the tab rather than the
  window once there is more than one; ⇧⌘[ and ⇧⌘] walk the strip in both directions;
  ⇧⌘T shows the bar at a single tab from the View menu, and once a second tab is
  open on either pane it is ticked and locked on, so a strip's tabs can never be
  hidden out of reach.
- **⌃⇥ cycles tabs in Browse**, where it had always been dead — there is one pane
  there, so a chord that moves between panes had nothing to move between. Compare
  keeps it as the pane switch, and the menu item's title says which you are getting.
- **In Columns, ⌘-double-click a folder to open it in a new tab**, and double-click
  the empty stretch of the strip for a new one. The double is deliberate: a plain
  ⌘-click is multi-select and has to stay that way.
- **New Tab is on the header card's right-click menu** — the one route that needs
  neither a folder under the pointer, nor a strip, nor empty space below the rows —
  and on the pane's empty-area menu beside New Folder. With no ＋ on screen until a
  second tab exists, those menus are the whole discovery story. Close Tab withholds
  itself at one tab rather than offering to close the window.
- **Tabs pin.** A pinned tab keeps its place, and *Close Other Tabs* stops being
  offered when every other tab is pinned and the verb would do nothing.
- **In Compare, both panes wear the strip together.** A strip on one side only pushes that pane
  down 34pt, from which every row names a different folder on the left than on the right.
  Opening a folder in a new tab follows the link, too.
- **Opening a folder in a new tab follows the link.** With the seam's 🔗 on, or ⌥
  held, it opens one on the other pane too — pruned to the deepest folder that pane
  actually has, the same treatment a mirrored drill gets.
- **The strip survives a quit** — each tab's source, its folder, the depth of its column stack,
  and whether it was pinned. Selection, history and a typed search stay with the session.

### Safety

Eleven fixes for things a v4.0 install really did. Most of them are the app no longer
destroying or misdescribing your files.

- **A folder the app cannot read no longer counts as an empty one.** Listing a folder you have
  no permission to read hands back a good listing that yields nothing, so at four places the
  “if this failed” branch was never taken. The folder-replace warning said “0 items will be
  removed” — the last sentence you read before replacing a folder.
- **Undo could destroy the very thing it existed to protect.** The check that stops ⌘Z
  discarding a file you have changed compared a stored byte size, and both cases with no size
  to compare fell through to the delete. A copied folder had no check at all: copy to a NAS,
  let files land inside, press ⌘Z, and on a volume with no Trash they are gone.
- **⌘Z is no longer offered for a removal it cannot take back.** On a volume with no Trash a
  removal escalates to a permanent delete, and nothing had gone onto the undo stack — so ⌘Z
  reversed whatever was still on it, which after a filing run is that whole run moving back.
  The merge's version was worse: undoing a merge deletes the copies it folded in, so with the
  originals already gone ⌘Z took the only ones left. The duplicate resolve also compared two
  copies by size alone, and now reads the modification date.
- **Apply recommended told you it had freed space it had not.** A group whose copies something
  else had already removed still counts as resolved, but reclaimed nothing — while its recorded
  size went into the total anyway. Two pairs with one copy gone reported “Reclaimed 5 KB from 2
  groups” for a run that trashed one 1 KB file. It also gave the wrong advice when it removed
  nothing: “these groups changed since they were scanned” was shown for every empty batch,
  where the usual reason is the opposite one — every copy is protected, so nothing has changed.
- **The log says when a document could not be read** , rather than reading like a document with
  nothing in it. A file the filing scan cannot open contributed no text, so the suggestion was
  made from the filename alone with nothing saying why. Three readers were silent about it; now
  all four speak.
- **Redo re-applies a nested rename in the order that makes it possible.** It
  replayed the undo's order, so a parent was renamed back first and each deeper
  item's recorded destination named a parent that had stopped existing — which
  `createDirectory` obligingly manufactured. Measured: ⌘⇧Z produced a new empty
  folder carrying exactly the risky name the feature had just removed.
- **An automation will not rebuild a provider that has gone away.** Applying a batch
  created the destination with nothing checked, so a provider unmounted between the
  preview and the apply was recreated as an ordinary local folder — and this is a
  *move*, so the files left a live tree for a dead one nothing syncs. The single-file
  filing path had refused this all along; only the automations lacked the guard.
- **One unreadable value no longer wipes every automation rule.** v4.0 made an
  unrecognised *condition* survivable and stopped one level short: a condition this
  build does recognise, holding a value it cannot read, still threw out of the whole
  array — so every rule vanished from the lens and the next rule you created wrote
  the empty set back over them. A rule now carries the parts it cannot read
  verbatim, never runs while it holds one, and reads *from a newer version* in the
  editor. As with v4.0's entry, **this protects the next upgrade rather than this
  one**.
- **An unreadable `~/Library/CloudStorage` made your cloud accounts disappear.** The same empty
  listing, behind the one site that reads and writes back — so every mounted Dropbox, Google
  Drive and OneDrive vanished at once, with the synthesized iCloud entry left behind to make
  the truncated list look plausible.
- **The cross-person veto never fired for a folder that did not exist yet.** The rule opened
  with an exact lookup, and a profile describes the folders that do exist — so every
  proposed-new-folder destination skipped the veto, with no refusal and no log line.
- **Tree and Columns agree on where the pane is.** Browse three columns deep, flip to Tree, and
  the breadcrumb still named the folder the columns had stopped in — with ‹ lit but dead, crumb
  clicks landing on nothing, and Scan offering to walk the wrong folder.

### Organize's scope, and the palette's pins

- **A row menu in the pane that did not have focus wiped Organize's scope.** A context menu
  does not move focus, and the scope setter read the focused pane's root — so right-clicking a
  folder in the other pane normalised it against the wrong root, which answers “nothing”. It
  survived a relaunch.
- **Right-click ▸ Open in Browse or Storage re-aimed every Organize lens.** The write was gated
  on a layout flag that predates Browse existing. Paths resolved correctly, so nothing looked
  wrong; the lenses were simply answering about another folder, and that survived a relaunch
  too.
- **A folder pinned in the breadcrumb now reads as pinned in the pane.** The app carries two
  spellings of the same root — a folder source keeps its `~`, while every surface that touches
  the disk expands it first — so a pin written under one spelling was invisible to readers
  holding the other.

### Panes and the pane bar

- **Browse keeps its preview column when Compare turns one off.** One stored preference served
  four surfaces that want two different answers: Compare's panes are read against something,
  where a preview costs half the room, while Browse is the pane where reading a file is the
  task.
- **A column row spends its width on the name.** Folder rows carried the folder's own mtime,
  which reports the last tidy rather than anything about the contents — and it cost the name
  about 76pt of a 210pt column, enough to truncate “Birth Certificate”.
- **The pane bar's controls now show their names** — a short word under each pill, as Finder's
  toolbar does, turned off from the bar's right-click menu and the first thing the bar sheds on
  a narrow pane.
- **A fixed space on the customize track can be aimed at.** Its pill is a dashed outline with
  no fill, and a shape is hit-testable only where it is painted — so the drag that removes it
  and its menu were attached to a 1pt ring. A space once added could never be taken off.
- **Dragging a control off the pane bar stops showing the copy badge.** macOS put a
  green ＋ on the cursor — the sign for "the item will still be there" — over a
  target whose only job is to delete it.
- **The pane bar's ⋯ is now only about width.** It held two unrelated things under one glyph:
  controls too narrow to draw, and controls you had deliberately removed in Customize — so the
  sheet could not actually remove anything. Removing is removing now, and Customize Pane Bar…
  has moved to the bar's right-click menu.
- **Customize Pane Bar… has left the ⋯ menu.** It is a command about the bar's
  appearance, and it was riding under controls that were there because of the
  window's width. Right-click the bar, which is where anyone who has arranged
  Finder's toolbar tries first.

### People

- **A repeated id in `people.json` now names one person.** The roster is a file you can edit by
  hand, and every reader answered a duplicate differently — so one row showed the first
  record's name above the last record's facts, and the second person never reached the screen.
- **A person listed twice was switched off by the duplicate.** A given name is published only
  when exactly one id claims it, so somebody listed twice claimed their own name twice and the
  claim was dropped — their matching silently disabled by the entry that looks like it
  reinforces them.
- **And opening Settings ▸ People no longer crashes on such a file.** That pane built its facts
  with a dictionary initialiser that traps on a duplicate key, so a copy-pasted person block
  whose id was not changed took the whole app down.

### Known limitations

Three things tabs do not do in v4.1. All three are deliberate, and none puts
anything out of reach.

- **⌃⇧⇥ does not cycle tabs backwards.** The pair has to split the way ⌃⇥ does, and there is no
  reverse pane switch to mirror. ⇧⌘[ and ⇧⌘] cycle both directions everywhere, so this is a
  missing second route rather than a missing capability.
- **⌘-double-click opens a new tab in Columns only.** The tree view drives navigation from
  single taps and disclosure, and a second recognizer there has to be proved not to cost
  either. Right-click ▸ Open in New Tab works in both views.
- **⌘W closes the window when the focused pane holds one tab** , whatever the other pane holds
  — so in Compare, a focused pane with one tab and a sibling with five takes the window and all
  six. That is Finder's rule; the header card's Close Tab withholds itself at one tab, so this
  is the chord only.

---

## v4.0

**The largest release SyncCloud has had, and a major for the reason v2.0 was one: the shape of the
app changed.** The workspace bar goes from five segments to four — Browse, Compare | Organize,
Storage — the first two looking at trees, the last two acting on or accounting for one. The
duplicate finder and the rules engine stop being places: they are things you do to a single tree,
and Organize is now the one place the app proposes a change to one. Browse arrives as the plain
file browser the app has always contained and never let you look at directly. Underneath all of
it, SyncCloud learns who the people in your documents are, and files by that.

On the v3 line, so it **requires macOS 26** — coming from 2.x, read the v3.0 section first.

### At a glance

| | |
|---|---|
| **Browse** | A fourth workspace: one tree, the whole window, no lens |
| **People** | A household SyncCloud knows by name, and files by |
| **Organize** | Five lenses, one scope you set, one overview you land on |
| **Restructure** | A new lens that reports where your tree's shape disagrees with itself |
| **Same-text duplicates** | Finds the re-downloaded copies a byte hash cannot see |
| **To File** | Routes by what a folder already contains — on a surveyed tree, 61.9% first-try |
| **Renames** | Names the file for the folder it lands in, with a backlog pass |
| **Compare** | A scan you can stop, what the last one found, and which rows failed |
| **⌘K** | One field that reaches folders, people, sources, places and actions |
| **Shortcuts** | A menu bar full of chords, plus ⌃⇥ between panes |
| **Look** | One file-type vocabulary, one setup card, one pill family |
| **Free** | The Organize scan no longer spends money — Refine does |

### Browse — one tree, the whole window

- **A fourth workspace with no lens and no opinion.** One tree at full width,
  nothing proposing anything: where you go when you do not want a lens's view of
  your files.
- **A new install now opens here**, rather than on a comparison of two clouds it
  has not scanned yet. **Upgrades are unaffected** — you carry a stored workspace
  and the app still resumes wherever you left it; only a machine with nothing
  stored is answered by this.

### Before you upgrade: this is a one-way door for automation rules

- **Rules you create in v4.0 cannot be read by v3.x, and opening them there hides the rest.**
  Rules persist as one JSON blob, and older builds throw on a condition they do not recognise —
  which takes the whole array with it, and the next edit writes the empty set back. The raw
  bytes survive under `automationRules.unreadable`, but there is no in-app way back.
- v4.0 fixes this going forward: an unrecognised condition is now preserved
  verbatim, shown in the editor as *written by a newer version*, and never allowed
  to file anything. **That protects the next upgrade, not this one.** Export your
  automations before installing if you may go back.

### Organize is the one place the app proposes a change to a tree

- **Organize changes one tree on the app's suggestion, and it is the only place that does.**
  Compare holds two side by side, Storage reports on one, Browse looks at one. Duplicates and
  Rules are lenses inside Organize now, and your stored workspace migrates forward.
- **A five-item rail inside Organize** — To File, Duplicates, Renames, Restructure, Rules.
  Permanent items, not the chips that came before: a chip only exists once a scan has found
  something, so “organize this folder” had nowhere to land before running anything.
- **Risky names are part of Renames now**, as a *to fix* section at the top of the
  backlog: a name your provider will not accept is one more kind of rename, and
  both answers already came off the same walk. It appears only when it has
  something to report, with per-row Fix and a Fix-all. A stored Names selection
  resolves to Renames.
- **The rename backlog is organised category-first**, grouped by parent folder,
  with one Rename column and a tree to review by — on a real tree the pass has four
  figures in it, which is not a flat list anyone can read.
- **The rail's unselected state is an overview, over one scope that you set.** One page
  carrying each lens's answer, in three states that never borrow one another's words: never
  ran, ran and clean, or findings. The scope survives a relaunch, and browsing never moves it.
- **One scope, which you set.** Every lens answers about the same territory: a folder you point
  Organize at, or the whole tree. It survives a relaunch, and **browsing never moves it** — a
  row of peers each quietly answering about a different folder is how a badge reports a count
  with none of what it counted on screen.
- **Scope filters, it does not rescan.** Filing suggestions, names and renames come
  off one walk and Restructure reads the folder profile, so narrowing is instant. A
  duplicate group is in scope if *any* copy is, and the out-of-scope copies stay
  visible — hiding half a group turns a two-copy decision into a one-copy one,
  which is how the wrong copy gets trashed.
- **Right-click any folder and choose "Organize This Folder…"** — in Browse, in
  either Compare pane, or in Organize's own rail, list or columns. It opens on that
  folder's filing queue and scans it.
- **Restructure arrives, report-only.** It reports families of sibling folders shaped
  differently in different years, under two rules validated against a real tree: axis values
  are not structure, and difference is not divergence. It does not yet propose a plan.

### A household, not a bag of names

- **SyncCloud now knows who the people in your documents are.** New, not improved: v3.1 filed
  by what a document was about and could not ask whose it was. A household keeps each person's
  name forms, their aliases, and how they are related.
- **Names are matched phrase-first, longest wins, and a match is consumed.** In a real family
  one word is several people. In “Aditi Abhishek” the surname is spent on Aditi and never
  doubles as evidence for her father — without which every shared surname is evidence for
  everyone carrying it.
- **People is its own place in Settings, and a row with folders behind it says what it buys** —
  the name forms tried against a document, how many folders are theirs, how many documents are
  filed in them. You can add, edit and remove people; edits take effect without a relaunch.
- **The editor teaches while you type**, showing live what the draft would match
  and which words are that person's alone — judged against the rest of the roster,
  because whether "girish" is distinctive is a fact about the household rather than
  about one person.
- **A rule can say whose document it is.** *is Aditi's document* rather than
  *mentions "aditi"* — not the same claim, and for a real family usually the wrong
  one. It keys on the person, so it survives a rename and starts matching a new
  name variant the moment you add one.
- **`{person}` as a destination.** `Immigration/OCI/{person}` files each person's card into
  their own folder, so what needed one rule per family member needs one. After a filing, the
  generalised offer appears when the folder is named for the person and the documents share a
  topic word.
- **The roster grows from what you have already filed.** *Look for names* reads the filenames
  inside each person's folders and offers forms their record lacks, with how many documents use
  it and one of them named — because “add this?” with no evidence is a request to trust the app
  about somebody's name. *Not a name* is remembered.
- **A document that names nobody can still be attributed** — by identifiers that
  only one person's folders have ever received. A number two people share is a
  household account, and is never used. This answers last, below both the filename
  and the page, because an account number is the strongest evidence in an
  unlabelled document and the most surprising thing to be filed by.
- **Search resolves a person.** Type a name into ⌘F and a row appears beneath the field —
  “Aditi — everything that is theirs”, ⌘↩ to take it. The find itself is untouched.

### Filing that reads your tree

The router reads a *folder profile* — the record of what your tree already holds.
It comes from a survey of the tree, which is something you run rather than
something the app writes as it goes: on a machine that has never been surveyed
there is nothing for the router to read, and Organize files as it did in v3.1.

- **On a surveyed tree, loose files are routed by what a folder already contains** , before any
  model is asked: what the folder *is*, and the distinguishing words of what is already filed
  there. A bare folder list gets 12.6% right first try, adding what the folder is takes it to
  28.9%, and adding what it has received to 58.2%. The shipped router reaches **61.9% first
  try, 81.8% in the top three**, on a held-out split of 7,370 documents.
- **The model re-ranks that shortlist instead of answering past it** , and is shown only
  folders the file could actually go in — listing an inbox teaches a classifier to file into
  the place things go when they have nowhere to go.
- **Rules are learned from what a folder has received** — the same surveyed record — rather
  than from one word in the folder's name, and a learned year becomes {year} rather than the
  year the example happened to have.
- **A scanned PDF can be read on request.** A PDF with no text layer reaches the classifier as
  a bare filename, so its suggestion is a guess about a document nobody read. The scan records
  which files would benefit and spends nothing; a Read scan button appears on exactly those.
- **A suggestion that would file one person's document into another's folder is refused** ,
  consulting the page the scan already read when the filename names nobody. The filename
  outranks the page: a page-1 mention is testimony — an application prints its sponsor — while
  a filename is your own label.
- **A proposed new folder can be renamed before it is made.** A backend could
  already answer with a sub-path that does not exist yet; what is new is that the
  name it picked is yours to edit before anything is created. The destinations
  themselves come off the scan's own walk of your tree, so a folder you made this
  week is a folder the router can offer.

### Naming files for the folder they land in

- **Organize could say where a loose file belongs but not what to call it once it
  got there**, so the house convention was applied by hand and decayed exactly
  where the volume is. A rename is now proposed alongside the move, and a backlog
  pass covers folders already filed under raw names.
- **The rules came from the tree, not from a description of it, and two changed as a result.**
  The ordinal is a position, not a month — of 327 such folders, 118 of the 132 that can tell
  the readings apart number by position. And 567 files carry a one-digit ordinal, which
  misorders past September.

### Duplicates finds the copies a hash cannot see

- **The same document downloaded twice is now found.** Providers re-generate a PDF on every
  download, so the same bill fetched twice is byte-different with identical content — and the
  scan reported a clean result that was silently wrong. SyncCloud now fingerprints what a
  document says, not just its bytes.
- **It is a weaker claim, and it says so.** Matches group as same text rather than identical,
  with their own badge and a standing exclusion from Apply recommended. Over a real tree of
  10,569 PDFs it finds about 250 groups the content hash cannot see — and it never split a
  byte-identical pair: 485 tested, 0 disagreed.
- **Replayed over a real tree of 10,569 PDFs** it finds about 250 groups the content hash
  cannot see — **248 on each of two replays**. The direction is one-way and that is what
  matters: the residue costs an unreported duplicate, never a false claim about one. It never
  split a byte-identical pair: 485 tested, 0 disagreed.
- **The copies about to be trashed are re-verified, not just the keeper.** A duplicate group is
  a point-in-time snapshot whose results outlive the scan. Rewrite one of the copies in that
  window and its path still exists — so it was trashed under a banner calling it redundant when
  it was the only instance of its new content.
- **Duplicate group headers align on invisible columns**, so a page of groups reads
  down the page instead of each header setting its own margins.

### Compare

- **You can stop a scan.** The Compare scan walks two entire trees and is the longest thing the
  app does, and it had no Cancel — so starting one against the wrong roots meant waiting it out
  or quitting. The pane rung becomes Stop, and says how long it has been running.
- **It says how long it has been running.** Not a percentage: counting the total
  first would mean instrumenting the walk's hottest loop, and a fraction that isn't
  measured is worse than a number that is.
- **Compare opens on what the last scan found** — a count and how long ago, in the past tense —
  instead of “Nothing scanned yet”. Never the rows: a three-day-old “Copy 412 to →” is exactly
  the stale-world apply the caches exist to prevent.
- **A partial transfer shows which rows failed.** The alert named the first failure and pointed
  at the Activity Log, so finding the other eleven of four hundred meant reading a log in
  another window. A Failed to transfer filter now selects them, and the table gains a Path
  column.
- **A Path column, and the selection matches the panes.** A file directly in the
  compared root was unplaceable — the only location signal was a hover tooltip. The
  table is now Name · Change · Path · Size. The **"Copy to" column is gone**; it
  restated what Change already said.

### Organize's cost, and what it does for free

- **The scan no longer spends money.** "Suggest homes" used to do everything in one
  click, including a pass that reached Claude whenever the cloud toggle was on — so
  the only button that produced results was also the button that billed you. The
  scan is now entirely on-device. **Refine**, on the results, is what re-asks the
  model named in Settings.
- **This reverses what v3.1 said about the price.** v3.1 put the estimated cost on
  the setup card because the button beneath it could spend; that button is free now.
  The estimate you approve is the Refine pre-flight, which prices a batch it has in
  hand rather than one it is predicting.
- **Duplicates and Organize re-scan when you open them on a target they have scanned before.**
  Results are never restored from disk — every row carries an action that writes files. Three
  conditions keep it from surprising you: the folder is exactly what the last completed scan
  covered, it is still there, and nothing has already run against it this session.
- **One paid click has no pre-flight — "Try another" on a suggestion card.** Rejecting a
  destination and asking for a different one is the Refine pass for a single card, so it
  reaches the model named in Settings and has never consulted the spend estimate. The hard caps
  still bound it, and with the cloud pass off it cannot spend at all.

### ⌘K goes anywhere

- **One field that reaches your whole tree.** ⌘K offers folders to jump to, people on your
  roster, your sources, the app's own places and its actions. Groups are ordered by their best
  match, and a row reached through a keyword draws no emphasis, because its visible text
  genuinely did not match.
- **Results are grouped, and the groups are ordered by their best match** rather
  than the list being one flat ranking with headings sprinkled through it.
- **It indexes the folders you actually have** — the same tree Organize walks,
  so a folder you made this morning is reachable by name this morning.
- **A row that matched on the text you can see shows the matching run**, so why it
  answered is visible rather than inferred. A row reached through a keyword draws no
  emphasis at all — its visible text genuinely did not match, and bolding something
  there would say otherwise. The palette teaches its own keys rather than expecting
  you to know them.

### Keyboard and focus

- **Menu-bar shortcuts for the things you were already doing** , shown as keycaps during the
  ⌥-hold reveal: ⌘1–⌘4 for workspaces, ⌘[ / ⌘] for the focused pane's history, ⌘R rescan, ⇧⌘N
  new folder, ⇧⌘F fold all, ⌘⌫ delete, ⌘I and ⌘L for the inspector and the log. ⌃⇥ moves focus
  between panes, which had no keyboard path at all.
- **⌃⇥ moves keyboard focus between the panes.** The pane-scoped chords — ⌘F, and
  the four that join it here — resolve through whichever pane holds the selection,
  which on a cold window is nothing, and the rule fell back to the left pane. So
  aiming any of them at the right pane meant clicking a row in it first; there was
  no keyboard path to the right pane at all.
- **The focused pane's provider capsule is ringed**, because the panes' only
  existing "which one is active" cue modulates *selected rows* — saying nothing in
  exactly the case ⌃⇥ exists for.
- **The pane bar's magnifier now really does tint while a query is live.** It has claimed to
  since ⌘F shipped in v3.1 and never did: the tint was set on the button while the glyph sets
  its own colour, and the inner one wins. So a search that was narrowing what you could see sat
  behind a glyph that looked idle.

### Windows, panes and previews

- **The window has a floor: 760 × 560.** It carried a 600pt minimum width and *no minimum
  height at all*, so the window could be dragged down to the toolbar and nothing else — a
  sliver with the pane header, the file list and the action bar all squeezed out.
- **An open Quick Look panel follows the selection.** It was a snapshot, not a view: Space
  opened a preview of whatever was selected at that instant and nothing ever moved it, so the
  panel sat naming a file long gone while looking exactly like a live preview. It closes when
  the selection is cleared, which is Finder's rule.
- **A space typed into the pane search field is a space.** It reached the ancestor
  Space handler and opened Quick Look instead, so ⌘F could not be used for any
  query of more than one word.
- **Clicking through columns moves what a scan started in that pane will walk.** Every Organize
  scan action read only the pane's comparison focus, so browsing the columns never moved the
  target: the offer sat dead at the provider root no matter which folder was selected.
  Organize's own scope is a different thing and is unaffected.
- **An empty tree is captioned once.** The column stack overlaid its own small
  *"Empty"* caption on any column with no rows — including the first column, which
  already draws the pane's full "Folder is empty" placeholder — so the two rendered
  stacked, the caption drawn through the placeholder's folder glyph and clipped.
- **Organize no longer opens on an inbox nobody asked for.** Switching to Organize
  moved the source rail into the loose-files inbox, which defaults to `TODO` on a
  fresh install — so the first switch re-rooted the pane on a folder you had not
  asked for, with nothing on screen saying why. The setting can also now say *off*.
- **The scanning placeholder stops drawing a gray slab.** Its loading card wore a
  material, and a material blurs what is behind it — on an empty pane there is
  nothing behind it, so what it actually painted was a flat gray rectangle in the
  middle of a white surface.

### A look that holds together

- **One file-type vocabulary everywhere.** Storage drew every file as the same gray document
  glyph while Duplicates drew raster icons — two surfaces, one file, two vocabularies, and at
  13–16pt a shrunken thumbnail reads mostly as “rectangle”. There is one map now: an SF symbol
  plus an identity tint per kind.
- **Every lens opens the way To File opens** — the setup card, with the job and the safety
  contract up top, one trigger, and **sample rows in the shape real results take**. All six
  adopt it, at one height so the card stops jumping as you move the rail.
- **The quiet chrome says true, whole sentences.** *"Hashing 0 candidates…"* becomes
  *"Looking for candidates…"* when no two files share a size, and the spend rows no
  longer print *"1 files"*.
- **One counting pill, one progress dialect**, across Storage's counts and the
  Duplicates toolbar.
- **The welcome tour describes the app you actually installed.** It offered
  "iCloud, OneDrive, Google Drive, or Dropbox" as the things a source can be —
  written before v3.0 made *any folder* a source, and never updated.

### Settings, and text that scales properly

- **Organize's Settings tab becomes three** : Organize, **People**, and **Intelligence**. It
  had become several subjects under one rail row, and the tell was its caption — one paragraph
  of eight sentences. Intelligence holds the engine and its cost: the on-device pass, the
  opt-in Claude pass, the spend, and the cache.
- **The text-size setting now has a knee curve.** It was one flat multiplier applied to every
  font alike, so the 10pt captions that most needed help barely moved at Large while 17–27pt
  titles ballooned. The full multiplier now applies through 11pt and the surplus above grows at
  half a point per point.
- **Settings prose moves to 11pt.** Most of the sheet's explanatory text — full
  sentences, not labels — was set as 10pt captions, which put the majority of its
  readable text at the smallest legible size.

### Storage

- **Storage gets the same rail**, and every one of its three sections is counted on
  its rail item — including the untouched-files list, whose count you had to reach
  its own section header to read. All three headers carried a count; the summary
  above them left that one out.
- Its ranked lists join the app's one file-type vocabulary, and its counts wear the
  same pill as everything else that counts.

### Under the hood

- **A document is read once, and says the same thing twice.** PDFKit's text extraction is not
  thread-safe and was being driven from a concurrent queue: over a real 10,286-document tree,
  0.83% came back with different text than a serial pass. Extraction now runs in one lane.

---

## v3.1

Two questions this release answers that the app used to leave to you: *where is
the file I'm thinking of?* and *what is this scan going to cost me?* The panes
get a real find (⌘F), and the lenses stop re-doing — and, with Claude selected,
re-billing — work they have already done. Around those two: hold ⌥ to see every
shortcut on screen, an inspector answer for "where does this file live?", and
"Find duplicates of this" on every file row.

On the v3 line, so it **requires macOS 26** — coming from 2.x, read the v3.0
section first.

### Find in the panes

- **⌘F searches inside a pane's tree — as a find, not a filter.** Every list in the app already
  had search; the two panes, the hardest and most useful half, had none. Matches keep their
  place in the tree: the matched run is bolded, everything off the path dims but stays
  readable, and a collapsed folder with hits says “2 matches” rather than hiding them.
- **↩ and ⇧↩ walk the hits** , opening only the folders on the way to each one, in Tree and
  Columns alike. In Compare, each hit says “both sides” or “left only” — which side a copy is
  missing from is usually the reason for searching at all.
- **A search never touches the disk.** It runs over the tree the pane has
  already loaded, so a query cannot make a cloud provider download anything.
- **The magnifier joins the pane bar**, including — once — on a bar you had
  customized before it existed. Remove it and it stays removed; ⌘F works either
  way.

### Nothing unchanged is paid for twice

The lenses used to start from zero on every scan: every file re-read, every
Claude classification re-sent, every Storage panel empty until a re-analysis.
Each of those now keeps its work, on disk, across launches.

- **Organize reuses suggestions for files that haven't changed.** A file with the same content,
  under the same model and instructions, gets the suggestion it got last time — without asking
  the model, which with Claude selected means without paying for it. A “reused” pill says what
  the scan got for free.
- **The price is on the button that spends it.** Organize's setup card quotes
  your last cloud run — file count, model, cost — before you start, instead of
  after. On a genuine first run it says the run is billed rather than inventing
  a number.
- **Verify and Duplicates stop re-reading gigabytes they have already read.**
  File digests persist across launches, so a rescan of an unchanged tree skips
  the reads entirely — and a cancelled scan keeps what it measured, because the
  reading had already happened. Merges keep their digests too.
- **Storage opens with your last report instead of an empty panel** , marked with how old the
  reading is — “Scanned 2h ago”, amber once stale. Storage is the one lens whose results are
  safe to restore: its only action is Reveal in Finder, so a stale row cannot misdirect a
  destructive apply.
- **Everything kept is visible and clearable.** Saved suggestions live under
  Settings ▸ Organize; the file digests and saved Storage reports under
  Settings ▸ Advanced ▸ Saved scan data, each with its size on disk and a Clear.
  Clearing costs time on the next scan and nothing else.

### Hold ⌥ to see every shortcut

- **Hold ⌥ for a fifth of a second and every control with a keyboard shortcut grows a key
  badge** ; release and they vanish. An opaque keycap takes the control's place, so nothing
  shifts and nothing is half-covered. Starting a chord, clicking or typing cancels the reveal.
- **The shortcuts were already there; now they are discoverable in passing** : every badged
  control's tooltip names the shortcut beside the action. VoiceOver hears each one
  unconditionally, since a held modifier is not a discovery path a screen reader can use.

### Where a file lives

- **The Info inspector answers “where does this file live?”** — This Mac only, This Mac ·
  iCloud, or OneDrive only — as the conclusion of two facts shown above it: the path, and
  whether the content is downloaded. “This Mac only” means the path is inside no cloud-synced
  folder, never “unprotected”.
- **Rows in a folder source carry a small ⌂ when a file is on this Mac only** — the mirror of
  the ☁ cloud-only badge, and free: pure path arithmetic, no syscall per row. Inside a cloud
  source's own pane it never appears, because there it would mark everything and mean nothing.
- **A disabled source still counts as a second copy.** Its folder is on disk
  whether or not the checkbox is on, so disabling a provider cannot make its
  files report riskier than they are.

### Find duplicates of this

- **Every file row's context menu can ask “does this have copies?”** — the question Duplicates
  answers in bulk, scoped to the one file you are looking at. If the current results already
  cover it you land on its group; if not, the right scan starts first.
- **"No duplicates" is only ever said by a scan that actually looked.** A file
  outside what was last scanned gets "*wasn't in the last scan*" and a button
  that scans its own folder — not a confident all-clear borrowed from results
  that never saw it.

### The window, and what the chrome claims

- **The window's smallest size is 760×560.** v3.1 held a 600pt floor on width and
  **none at all on height** — narrow enough that the workspace bar has shed its
  labels, and short enough to lose the content under the toolbar. The new floor
  keeps the labels at Small, Default and Large text.
- **A clean duplicate scan says which folder it checked.** "Nothing repeats across
  iCloud" is a claim about a whole provider, and a scan of one folder cannot make
  it; it now reads *"Nothing repeats in 'TODO'"* when the scan had a root, and
  keeps the provider-wide sentence only when it did not.
- **And a lens that has never run here says so**, rather than borrowing the words
  for "ran and found nothing" — on the overview and on the rail badge alike, since
  a count filtered to zero is not a check that came back clean.
- **One vocabulary across the lens rows** — medium file-type symbols with identity
  tints, counts in one pill, one progress dialect, and headers aligned on shared
  columns, so a row means the same thing whichever lens you are reading.

### Appearance

- **The segmented pickers in Settings follow the app's accent.** Choosing Cyan
  used to recolour the rail and leave Theme, Text size and List density in
  system blue. The "None" accent keeps the stock macOS look untouched — that
  being the point of "None".
- **The seam between the panes wears its swap/link capsule in the app hue again.** v3.0 had
  rested it on a neutral grey wash to sit level with the nav pills; floating over pane content
  on an already-tinted window, grey read as unstyled rather than as quiet.

### Fixed

- **Switching providers no longer leaves the previous provider's Storage report on screen.**
  Every other lens cleared its results on a source switch; Storage kept showing numbers
  measured somewhere else, under a folder chip naming a root the window no longer showed.

The package suites stand at 3,034 checks with this release, and the new features
were re-reviewed in two dedicated adversarial passes after landing — nineteen
defects found, fixed, and pinned by mutation-checked tests before any of them
reached you.

---

## v3.0

The first release on the v3 line, and the first one that **requires macOS 26**.

Three things here are new rather than repaired: any folder on this Mac can be a
source, a name the cloud will reject is now reported and marked where you already
are instead of behind a tab you had to remember to visit, and the scan is roughly
twice as fast on a real provider root. The navigation above all of it went from
two levels to one.

Changes that shipped in v2.9 are not repeated here — if you are coming from v2.8,
read that section too.

### Requires macOS 26

- **The app now declares the floor it is actually built against.** `project.yml` and all seven
  packages said macOS 15 while the code had been written against 26 for some time, so thirteen
  availability guards and their fallback branches were still being compiled for an OS this app
  was never going to run on.

### One row of workspaces

- **Compare, Organize, Duplicates, Automations and Storage are five segments in one bar.** They
  used to be two levels: a Compare | Tidy container picker with the lenses nested underneath,
  which left Duplicates two clicks deep behind a word that named no task. The five were peers
  all along; only the nesting said otherwise.
- **Your selection survives the change.** The stored workspace is migrated once
  at launch and every old value maps forward explicitly, so you open where you
  left off instead of being dropped on Compare mid-task.
- **Settings follows the same names.** The Tidy tab — the last place still using that word — is
  now Organize and Duplicates, each wearing its workspace's glyph. Settings go where the work
  is, so Compare, Automations and Storage get no tab of their own.

### Risky names

- **Names the cloud will reject are reported instead of waiting to be looked for.** Rename was
  a tab you had to remember to visit for a problem you hit a few times a year. Organize's scan
  already walks the whole provider and the name rules are pure, so the names come back on that
  pass — no second walk, no second button.
- **Both panes, Columns and the Differences table now mark the offender on
  sight**, with the reason on the tooltip. Previously a name that would break a
  sync looked exactly like every other name until you ran Organize.
- **“Fix name…” works.** The row context-menu item had never once appeared: declared in a
  protocol extension, where a member has no witness-table entry, so every call through the
  delegate bound statically to the extension's nil default. It was unreachable from the day it
  was written.
- **Settings ▸ Organize lists the names you have kept.** Keeping a name has always been
  reversible, but a kept name draws no badge — so “what have I kept?” could only be answered by
  walking your files and reading a context menu per file.

### Any folder is a source

- **A pane, a scan or a lens can be pointed at any folder on this Mac, not just a cloud
  account.** The source list was built by enumerating `~/Library/CloudStorage` plus a hardcoded
  iCloud entry, so `~` or `~/Projects` could never be a source. Two doors now: Settings ▸
  Sources ▸ Add Folder… for deliberate setup, and Choose Folder… where you are working.
- **A new “Check folder names against” setting decides whose rules a folder is judged by.** A
  folder has no naming rules of its own, so judging names against it would report an empty
  all-clear over a folder full of names OneDrive would reject. The useful question is “would
  this survive being put somewhere?”
- **Reset All Settings says that it removes your folder sources.** It always did;
  the confirmation previously reassured you that files on disk are untouched and
  stopped there.

### Scanning is faster

Measured on two real provider roots of about 40,000 nodes each.

- **94% of path components need no normalizing at all**, and the scan now checks
  that before doing the work rather than normalizing everything: 673,925 of
  719,361 components on those two roots. Name comparison went from about 500 ms
  to about 130 ms, and the whole pass roughly doubled in speed (1.0–1.6 s before,
  0.53–0.82 s after, across four interleaved runs).
- **Flattening a cached tree for the scan costs less than half what it did** —
  809 ms → 377 ms and 1,194 ms → 466 ms on the two roots. In the live app the
  scan's flatten phase went from 1.18 s to 0.51 s.
- **File paths are stored as native Swift strings**, so the scan stops paying to
  bridge them back from Foundation on every comparison: about 135 ms and 181 ms
  off a full load-and-scan on the two roots.
- **A debug log line no longer costs a tree walk when logging is off.** It built
  its message — about 5 ms per 40,000 nodes — before the level gate had a chance
  to drop it.

---

## v2.9

A consolidation release. The surfaces v2.8 introduced settle down, one real
data-loss path closes, and the app finally reports the version it actually is.

It is also **the most heavily tested and reviewed release in the 2.x series** —
about 10,700 lines of new tests, close to double any release before it, taking the
suite from 2,628 checks to 2,867 across four adversarial review passes. That is
where most of the work went, and it is why this list is shorter than the size of
the change suggests.

### Data safety
- **Verify All's “copy the identical files” offer can no longer act on a stale verdict.**
  Undoing a file operation while a verify pass was running left the offer describing files that
  had since moved, and confirming it could overwrite the bytes the undo had just restored. It
  is re-checked when the write is ordered, not at the click.
- **A cancelled Verify All no longer offers a partial batch.** Cancelling at 40% of
  500 files still published the verdicts it had reached, so the confirmation dialog
  opened over the top of the "cancelled" banner, offering a bulk write of whatever
  it had got through.

### Cloud files
- **A pane watches every download it starts**, not just the most recent one, so a
  second download no longer leaves the first one's row badged cloud-only forever.
- **The ☁ badge stops answering from a stale memo** — a file that has landed reads
  as local, and a path the app could not stat is no longer remembered as though it
  had answered.

### Columns
- **Opening the preview no longer hides the column it is describing.** The preview
  takes its width off the stack, which covered the deepest column — the one holding
  the file you selected — so you had to scroll right by hand to read what the
  preview was about.

### Appearance
- **The accent picker shows what it does.** Under the twelve swatches there is now
  a live preview — a filled transfer button beside a differences pill — and a
  caption naming what the colour is actually used for. It was the only section on
  the tab that explained itself neither in words nor by example.

### Settings
- **The app reports its real version.** Every release from v0.10 to v2.8 installed
  an app that called itself 1.0 (build 1) — in Settings, in `~/sync-cloud.log`, and
  in Finder's Version column. This one says 2.9.
- **Tidy's loose-files inbox is searchable.** Searching "inbox", "loose files", or
  "TODO" in Settings found nothing, in every 2.x release the control has shipped in.

### Launch at login
- **A login-item update that fails no longer discards the toggle you set while it
  was in flight.** The failure path re-read the service's real state and overwrote
  your switch with it, silently throwing the change away.

### Automations
- **A rule imported, bulk-toggled, or undone no longer re-writes itself.** An
  external change to a rule's enabled state was echoed back as though you had
  flipped the switch — at worst re-entering the very undo that caused it.

### Performance
- **The comparison bar lays out nearly three times faster** , and you feel it wherever the
  comparison redraws. It worked out which layout fit by building six whole toolbars and
  measuring them; it now computes the width arithmetically. Measured at 900pt: 68.4ms → 23.9ms
  per layout pass.

### Fixes
- The destination picker's search says when it is showing a partial answer instead
  of presenting the first N matches as all of them, and its cards stop
  double-bordering.

**Full changelog:** [`v2.8...v2.9`](https://github.com/agirish/sync-cloud/compare/v2.8...v2.9)

---

## v2.8

A destination picker of our own, a preview beside the columns, and a pane bar you
arrange yourself.

### Removed
- **Cross-pane drag & drop is gone.** In practice it had not worked for a long time — the drag
  would lift, but no target ever accepted the drop — so what was on screen was an affordance
  that did nothing. Use the transfer buttons or the new destination picker.

### Data safety
- **Three ways a mutation path could destroy what it was saving** are closed.

### Sending files somewhere
- **Organize gets a destination picker of its own** instead of the system panel,
  floated over the window and dressed in the app's own surfaces. It names what a
  move is about to collide with *before* you confirm it.
- **The Tidy rail can send a file somewhere**, and a cross-pane transfer now says
  where it actually puts things.

### Preview
- **A selected file previews beside the columns** — in the Tidy rail and in the
  comparison panes, with the toggle in the pane header.
- The Tidy rail draws columns, a lone column fills its area, and columns are lifted
  off their width floor.

### A pane bar you arrange
- **The pane bar is a canvas you arrange yourself** — drag the controls you use
  onto it, drop the ones you don't, from a customize sheet.

### Performance
- **The file panes stop re-rendering on unrelated state**, the inspector's stat
  moves off the main thread, and the panes stop re-arming a timer and re-statting
  every frame.
- **Tidy and the merge planner now use the content-hash cache**, so neither pays
  again for hashing the other already did, and the merge planner stops re-asking
  what the directory walk already told it.
- A row's fonts are resolved once per pane instead of once per row, bulk-operation
  progress is throttled to one update per percent, and the pane bar computes the
  rung it needs instead of building ten to find it.

### Fixes
- The Tidy rail stops striking out and badging rows with comparison state it has no
  business showing.
- **Space previews the file the app says is current.**
- The overlay cards stop throwing away the Clear setting, and a superseded metadata
  load can no longer claim the memo ahead of the current one.

**Full changelog:** [`v2.7...v2.8`](https://github.com/agirish/sync-cloud/compare/v2.7...v2.8)

---

## v2.7

Browse your folders in columns.

### Columns
- **A new pane view mode, and the default** — panes render as columns, the way
  Finder does, so you can see the path you took instead of just where you landed.
- **Drilling into a folder mirrors onto the linked pane**, keeping both sides in
  step.
- The header shows **one location** for the pane, and the pane arrows understand
  columns before they consult the focus history.
- A click on empty space **puts the selection down**, and a linked breadcrumb click
  reaches the folder it names.

### Scrolling that behaves
- The column stack scrolls **the way AppKit scrolls**, bounce included, and is
  pulled home when the platform's bounce strands it.
- A wheel gesture **locks to its dominant axis**, so a vertical scroll does not
  nudge the stack sideways.

### Clicks
- One pane's deferred clear no longer eats the other pane's next click, and the
  action bar's buttons stop moving when the summary changes.

### Data safety
- **External-volume providers claim their own tree again.** A depth rule introduced
  in v2.6 meant a provider mounted under `/Volumes` claimed nothing — so a
  path-addressed CLI root inside it silently lost its destination-name guard and
  date-noise filter. The test is now what the root *contains*, not how deep it sits.
  *(Regression introduced in v2.6.)*
- **`›` can no longer walk into a folder that no longer exists.** Stepping back out
  of a folder that is then deleted left the forward arrow lit and pointing at a dead
  path — where New Folder, paste, and background drops act.

### Tidy accounting
- A group whose copies are all protected no longer **vanishes from the list with its
  bytes credited as reclaimed** while every copy is still on disk.
- Protected copies are no longer counted as reclaimable, so a group stops promising
  bytes its own "Move to Trash" would never deliver — and its Trash button is no
  longer enabled to do nothing.
- A corrupt store stopped rewriting its whole backup on every read — tens of
  thousands of writes per scan, exactly when the disk is least worth hammering.

### Security
- The copied API key is **marked concealed on the pasteboard**, so clipboard
  managers know not to retain it.

**Full changelog:** [`v2.6...v2.7`](https://github.com/agirish/sync-cloud/compare/v2.6...v2.7)

---

## v2.6

Comparisons you can fold up, and Settings you can read.

### Differences
- **Grouped into top-level folder sections**, so a long comparison reads as a
  handful of folders instead of one flat wall of rows.
- **Sections are selectable and collapsible**, with **Collapse All** on the
  differences bar.

### Settings
- **Stood on a left rail**, so a tab is never cut in half again.
- More air between sections, a looser vertical rhythm, and room for a provider path
  to actually be read.

### Appearance
- A **Text size** setting.
- The seam pill is quiet at rest, and the accent is reserved for meaning "linked".
- On Clear glass the provider capsule gets a ground to sit on, and chrome ink is
  brighter on a dark appearance.

### Keychain
- **Opening the Tidy tab no longer demands your Keychain password.**
- The API key gains a **reveal**, and a replace that tells you it replaced.

### Performance
- SwiftUI no longer deep-compares 40,000 file nodes on the main thread — a folder
  row's subtree is kept out of row comparison, `OutlineGroup` is no longer handed
  the raw node graph, and the Details sidebar resolves its selection through an
  index rather than walking the tree.

### Data safety
- **A bulk sync could overwrite one file with another and report success.** When a batch mixed
  a case-sensitive mount with the case-insensitive boot volume, two names differing only by
  case both passed the uniqueness check and the workers wrote to the same file — with a Move,
  both sources consumed. Each destination is now asked about its own volume.

### Fixes
- Clearing the stored API key now reports whether it actually succeeded.
- The transfer buttons spell out **Copy**, and the link-panes toggle folds into the
  swap chip's seam capsule.

> **Known issue, fixed in v2.7:** a depth rule added in this release stopped
> external-volume providers from claiming their own tree, so a path-addressed CLI
> root under `/Volumes` lost its destination-name guard.

**Full changelog:** [`v2.5...v2.6`](https://github.com/agirish/sync-cloud/compare/v2.5...v2.6)

---

## v2.5

A retuned palette and a hardening pass.

### Colour
- **Terracotta** replaces amber as the attention colour.
- **Accent fills deepened** so every filled control can carry a legible white
  label, with on-accent text paired to the fill's own luminance.
- **Freshness badge** redesigned — scan freshness now lives in the status dot, the
  badge carries its own colour, and the scan action follows it.
- **Clear reads as glass**, with its background carrying the accent.

### Chrome
- **Pane nav controls are drawn in-app** rather than fought from outside: levelled
  pill heights, tinted glyphs, and a real hover state on every chrome-less and
  system-chrome button.
- **Differences bar zoned**, with its primary action fixed left-to-right; the
  difference count gained the same capsule a stale badge wears, and the sort menu
  now matches its neighbours.
- **The action bar says which pane** it is about to act on, and places itself from
  rows that are actually on screen.
- The **differences pane stays open** during a guided review.
- The Activity Log's **search reveal is animated**, and its severity chips count the
  history you have actually revealed.

### Filing
- Cloud Filing's Opus option moved to **Opus 5**, with the generation named in the
  model picker.

### Accessibility
- The transfer buttons are **named for VoiceOver**, and the compaction ladder is
  pinned.

### Fixes
- A filing walkthrough no longer resumes over a preview it no longer describes.
- Closed the bulk-sync exclusion in both directions, and let a sweep stand down
  mid-operation.
- Case is folded when deciding a file is already filed; a stranded review pin is
  released.
- A history wipe now asks first, and New Folder's undo no longer swallows its
  outcome.
- A delete that found nothing says so, and a wrapped busy error is no longer
  misread.
- Clearing the log clears the one you can see, not a handle nobody holds; a log the
  app could not read is told apart from one holding nothing.
- A duplicate batch keeps its hands off the folder it just called intact.

**Full changelog:** [`v2.4...v2.5`](https://github.com/agirish/sync-cloud/compare/v2.4...v2.5)

---

## v2.4

Compare actions, and a quieter Activity Log.

- **Redesigned Compare action bar** — it appears the instant a file is clicked,
  positions itself away from the selected row, and the selection can now be cleared.
- **The differences pane can be collapsed** — a show/hide chevron replaces the
  drag-only divider, and the last file stays visible.
- **Activity Log chrome** — the title bar is hidden, search collapses behind a
  magnifier, surfaces are translucent and Settings-styled, and long messages wrap
  instead of being cut off.
- **The app accent carries through** the compare chrome and row selection, replacing
  the OS gray.
- **New Folder is gone from the Compare action bar**, and the pane link toggle is
  hidden in Tidy's single-source rail where it had nothing to link.
- A **new flat two-pane app icon**, a rewritten README, and a visual GitHub Pages
  feature site.

**Full changelog:** [`v2.3...v2.4`](https://github.com/agirish/sync-cloud/compare/v2.3...v2.4)

---

## v2.3

Bold dark mode, and a true-neutral accent.

- **Dark mode reworked** — a deeper base, accent glow, specular-edged cards, and a
  bolder translucent veil on Clear glass.
- **Graphite accent** — a new hue for a genuinely neutral, monochrome look.
- **Accessibility** — a caution tier in the semantic colour table, a shared 3:1
  contrast floor, and VoiceOver-proof compact fallbacks.
- **Duplicates hardened again** — cross-folder version groups stop pooling unmarked
  originals, and merges refuse to aim through keeper hard links.
- The unreadable-folder fix from v2.2 is **widened to case- and near-name variants**.
- **A failed replace can no longer lose your file** — the staged temp is preserved
  when the source can't be restored.
- **Undo Last Run** is paired with its own run, not whatever name sits on the stack.

**Full changelog:** [`v2.2...v2.3`](https://github.com/agirish/sync-cloud/compare/v2.2...v2.3)

---

## v2.2

One design system, and a Theme to switch it with.

### Theming
- **Light / Dark / Follow macOS** — a Theme control sets the app's appearance
  independent of the system, and switching it updates everything live, down to the
  title bar.
- **Clear glass** lets the desktop through, with frosted controls and carded chrome.
- **Compare | Tidy moved into the window's title bar**, and all five Tidy lenses now
  sit under one header card.

### One visual language
- Unified badge pills, one lens-card surface, one semantic severity table, a shared
  close button and search field, real empty states, and a canonical type ramp — so
  the same idea looks the same everywhere.
- Accent, on-accent, and treemap label colours are derived from **actual luminance**,
  so text stays legible on any hue.

### Density
- **Comfortable / compact list density** extended to the file panes, Activity Log,
  Sync History, lens cards, and the Compare differences table.

### Search & automations
- **Clear Filters**, `kind:` made last-wins, and kind classes shared with Compare.
- A chip's ✕ now removes **every** occurrence of its word.
- Automations gained **Preview / Reveal** inspection.

### Scans that tell the truth
- **Unreadable directories no longer mint phantom "Missing" rows** — a
  permission-denied directory is treated as unexplored rather than empty, the scan
  root included.
- Dataless oversize files are classified as **cloud-only**, not "too large".
- A merge is refused when a source file's modification time changed under it.
- The CLI lists each name-skip's reason inline.

**Full changelog:** [`v2.1...v2.2`](https://github.com/agirish/sync-cloud/compare/v2.1...v2.2)

---

## v2.1

Search that understands what you mean, and scans that tell the truth.

### Search
- **Token search everywhere** — Compare, the Activity Log, and Tidy duplicates all
  gained a chip-based search with removable tokens and suggestions, `kind:` filters,
  and size tokens.

### Compare
- **"Scanned N ago" freshness pill** on the pane header.
- **Selection size** on the action bar, and a **folder quick-jump menu** in the header.

### Tidy & duplicates
- **Content thumbnails** in duplicate cards, and **"Compare copies"** hands a group
  straight to the Compare tab.
- **Safer grouping** — files group as "versions" only with a real marker or shared
  folder; symlinks and cloud-only placeholders are no longer mistaken for duplicates,
  and skipped-file counts are surfaced instead of going silently blind.
- A redundant copy is **re-verified right before** a merge trashes it.

### Cloud-only files
- Not-yet-downloaded files are **flagged**, with a best-effort Download; the badge
  clears once the file lands.

### Activity Log
- **Grouped by day**, with per-file operation runs folded together.

### Automations
- **One rule system** — remembered rules and automations unified, with every newly
  learned rule surfaced for review.

### Safety
- **Undo covers everything** — a full move / copy / delete undo-then-redo matrix,
  plus an Undo affordance on completion banners.
- Never auto-replace a folder from a file's "Apply to all"; no permanent delete
  offered after a merely transient trash failure.
- Fixed OneDrive name-rule false positives and an integer-overflow crash in the
  "Larger than N MB" rule.

### CLI
- Destination names are validated as the app does, and sync skips are reported by
  cause rather than assumed to be collisions.

**Full changelog:** [`v2.0...v2.1`](https://github.com/agirish/sync-cloud/compare/v2.0...v2.1)

---

## v2.0

A ground-up restructure of the window — from a provider-sidebar layout to a focused,
tab-driven workspace.

- **Persistent tab strip** with a single-source rail replaces the provider sidebar,
  at a fixed height.
- **Self-contained panes** — scanning and per-pane actions moved onto the pane
  headers, and the title bar was pared down to Logs and Settings.
- **Differences is now Compare**, with the old Details panel folded into a dedicated
  Compare inspector; Get Info routes there and the pane is resizable.
- The **Name Normalizer** returns as its own **Rename** sub-tab, and Organize's
  loose-files scan defaults to a configurable TODO inbox.
- Previewed automations are **filed for real**, one file at a time, anchored at the
  provider root.
- After filing a loose file, SyncCloud **offers to learn an Automation rule** — and
  asks only when the file actually moved.
- The comparison panes no longer re-walk their 40k-node trees on every selection,
  and the dead first click when selecting in a pane is fixed.

**Full changelog:** [`v1.4...v2.0`](https://github.com/agirish/sync-cloud/compare/v1.4...v2.0)

---

## v1.4

Three new Tidy lenses, plus a durable history you can undo from.

- **Storage Lens** — a treemap of what's eating your disk, with reclaim-candidate
  lists.
- **Sync History** — durable and exportable, with **run-level undo**: "Undo Last
  Run" names the run it will reverse and itemizes it before it fires.
- **Name normalizer** as a batch lens, with per-row Quick Look and Show in Finder.
- **Automations** arrive as a preview-only lens — rich rule cards, grouped results,
  per-rule preview, and a Browse button for the destination.
- **Activity Log** gained on-demand "Show older history" paging.
- **Cloud spend guardrails** — a pre-flight estimate before a scan, a monthly cap,
  and a lifetime cap defaulting to $5.
- A **per-tab toggle to hide the top file panes**.
- Re-verification is instant: SHA-256 is cached by path + mtime + size.

**Full changelog:** [`v1.3...v1.4`](https://github.com/agirish/sync-cloud/compare/v1.3...v1.4)

---

## v1.3

Onboarding and visual identity — the release that made SyncCloud explain itself.

- **A first-run feature tour**, with a vector illustration per page, brand glyphs,
  and motion.
- **In-app Help** — a Help overlay and enriched Help menu, plus Help ▸ Welcome to
  re-summon the first-run card.
- **Provider brand hues** tint provider identity throughout, adapting to light and
  dark.
- **Unified empty states**, and comfortable / compact list density.

**Full changelog:** [`v1.2...v1.3`](https://github.com/agirish/sync-cloud/compare/v1.2...v1.3)

---

## v1.2

AI-assisted filing — SyncCloud learns where your loose files belong.

- **The Filing lens** suggests a destination for every loose file, backed by
  on-device content signals.
- **Two engines** — on-device Apple LLM first, with an **opt-in cloud (Claude)
  classifier** for the hard cases.
- **Remembered rules** — corrections stick, with a legible, editable home in plain
  words; "Try another" re-suggests with rejection learning.
- **Cost is visible and cheap** — spend is surfaced as last-scan, total, and
  history, and the classifier defaults to Haiku to keep a scan to cents.
- A **confidence meter and legend**, Quick Look on Filing cards, and a rescan after
  you navigate somewhere else.
- **Settings ▸ Tidy** — a dedicated tab for Duplicates, Filing, and cloud spend, plus
  a header search that filters across all tabs.

**Full changelog:** [`v1.1...v1.2`](https://github.com/agirish/sync-cloud/compare/v1.1...v1.2)

---

## v1.1

The Tidy tab arrives, alongside a broad UX polish wave.

- **Duplicates lens** — find and resolve duplicate folders and files within one
  provider, including **overlapping-folder merges**.
- **Keeper picker** and a persistent **"Keep separate"** decision.
- **Cancellable scans** with determinate progress through the hashing phase.
- **Differences polish** — an actionable "No Scan Performed" state, per-side totals,
  per-filter counts, directional keyboard copy/move, and a visible "navigate both
  panes" toggle.
- **One icon vocabulary** for copy/move, so three features stop sharing the same
  arrows.

**Full changelog:** [`v1.0...v1.1`](https://github.com/agirish/sync-cloud/compare/v1.0...v1.1)

---

## v1.0

The first complete release: comparing and reconciling the folders you keep across
iCloud Drive, OneDrive, Dropbox, and Google Drive — a native macOS app plus a CLI.

- **Inline guided review** for working through differences one at a time.
- The action bar moved into the **native window toolbar**; invisible dividers, a
  per-pane hidden-files toggle, expanded Settings (conflict policy, startup restore,
  notifications, shortcuts).
- A **"None" accent** option, for the stock-macOS neutral look.
- **Reveal in Finder** and Quick Look on tree rows.
- **CLI** — `--strategy` defaults to replace, skips are explained, roots are
  validated, and a failure exits nonzero.
- **Safety, which is what makes this 1.0** — atomic destination replacement,
  replaced files kept recoverable, permanent deletes gated on Trash-less volumes,
  and orphaned `.tmp_` files swept.
- **Scan is ~8× faster** on large directories.

**Full changelog:** [`v0.20...v1.0`](https://github.com/agirish/sync-cloud/compare/v0.20...v1.0)

---

## v0.20

The Differences table and a theming pass — the last stop before 1.0.

- **Differences rebuilt as a dense, searchable, sortable table**, with header stat
  pills, a right-click menu, directional arrows, and an aggregate multi-select
  summary.
- **Settings becomes an in-window overlay** with a General tab; failures surface as
  structured errors carrying their own actions.
- Per-pane back/forward history, real file icons and metadata, and a ⇄ pane swap.
- Appearance gains a content surface-style picker, a tint slider, and accent-aware
  toolbars.

**Full changelog:** [`v0.19...v0.20`](https://github.com/agirish/sync-cloud/compare/v0.19...v0.20)

---

## v0.19

Sync-aware panes, and drag & drop.

- **Per-row sync status badges**, and provider names replacing "Left/Right" in
  action labels.
- **Drag & drop between panes**, double-click drill-down, and breadcrumb navigation.
- Streaming checksums, plus symlink and case-variant fixes — including a false
  all-missing diff.

**Full changelog:** [`v0.18...v0.19`](https://github.com/agirish/sync-cloud/compare/v0.18...v0.19)

---

## v0.18

End of the first development era (March 2026). Folder comparison and the CLI.

- **Compare folders** with ignore rules, diff refresh, and Copy / Move in an action
  bar.
- Progress bar, overwrite confirmation, Copy/Move-All with apply-all.
- Provider-branded panes and the first Liquid Glass design pass.
- A headless **SyncCloudCLI**.

**Full changelog:** [`v0.17...v0.18`](https://github.com/agirish/sync-cloud/compare/v0.17...v0.18)

---

## v0.17

Multi-selection and bulk move.

- Select many files at once and move them as a batch.
- Details tab, Move-to-source / Move-to-destination, and the first app icon.

**Full changelog:** [`v0.16...v0.17`](https://github.com/agirish/sync-cloud/compare/v0.16...v0.17)

---

## v0.1 – v0.16

The original March 2026 prototype, versioned by hand in the commit log itself —
`v0.1` through `v0.16.6`, all inside four days. These tags preserve that
self-versioning, one per minor.

- **v0.1 – v0.5** — the dual-pane file manager core: Finder-style cut / copy /
  paste with native paste-conflict handling, context menus, and right-click.
- **v0.6 – v0.8** — Get Info, and **undo / redo** across all file operations.
- **v0.9 – v0.11** — consistent logging and error handling, security fixes, and a
  pass over comments.
- **v0.12 – v0.16** — hidden-file toggle, Quick Look, the app icon, and the first
  real test suite.

**Full changelog:** [`v0.1...v0.16`](https://github.com/agirish/sync-cloud/compare/v0.1...v0.16)
